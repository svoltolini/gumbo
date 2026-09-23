import SwiftUI

/// Connection flow, browsing state and settings for the whole app.
@Observable
public final class AppModel {
    public enum Stage: Hashable {
        case welcome, discovering, chooseFolder, indexing, ready
    }

    public let library: LibraryStore
    public let discovery = ServerDiscovery()
    public let indexer: LibraryIndexer

    // MARK: Connection

    public var stage: Stage = .welcome {
        // The tabs and their player sheet leave the screen with the library; a request to show it must not
        // wait around to come up over the next library that opens.
        didSet { if stage != .ready { isNowPlayingPresented = false } }
    }
    /// Server chosen from discovery or typed manually; presents the sign-in sheet while set.
    public var pendingServer: DiscoveredServer?
    public private(set) var isSigningIn = false
    public var signInError: String?
    public private(set) var needsOTP = false
    public private(set) var connection: ServerConnection? {
        didSet { updateNetworkObservation() }
    }
    public private(set) var isRestoring = false
    public private(set) var isReconnecting = false
    /// Password stored temporarily when 2FA is required during reconnect/restore, so the user only needs to enter the OTP code.
    public private(set) var pendingReconnectPassword: String?
    private var session: DSMSession?
    private var connectionGeneration = UUID()
    private let defaults: UserDefaults
    private let services: ConnectionServices
    /// Complete NAS listings can reconcile explicit deletions on companion devices. Partial
    /// scans and missing-root errors never invoke this callback.
    public var onVerifiedServerListing: ((String, Set<String>) -> Void)?
    /// Cancels work holding live provider credentials before any connection intent changes.
    public var onConnectionWillChange: (() -> Void)?
    /// The saved connection and its password are gone, or the sample library was left. Access handed
    /// on with them, such as the Watch's own copy of the sign-in, ends too, even for a library this
    /// launch never had ready, and nothing from the old library may stay queued to play again.
    public var onSignedOut: (() -> Void)?
    private var pendingCloudConnection: ServerConnection?
    private var pendingCloudCredentialSync = false
    private var credentialSyncRevision = 0
    public private(set) var credentialSyncError: String?

    public var supportsCredentialSync: Bool { services.supportsCredentialSync() }
    public var syncCredentialsAcrossDevices: Bool {
        _ = credentialSyncRevision
        guard supportsCredentialSync else { return false }
        if pendingCloudConnection != nil { return pendingCloudCredentialSync }
        guard let connection else { return false }
        if let pendingServer, pendingServer.provider != connection.provider || pendingServer.baseURL != connection.baseURL { return false }
        return credentialSyncEnabled(for: connection)
    }

    private func credentialSyncEnabled(for connection: ServerConnection) -> Bool {
        defaults.bool(forKey: "credentialSync." + connection.sourceID)
    }

    private func recordCredentialSync(_ enabled: Bool, for connection: ServerConnection) {
        defaults.set(enabled, forKey: "credentialSync." + connection.sourceID)
        credentialSyncRevision += 1
    }

    /// An explicit choice: existing remembered passwords are never uploaded during migration.
    public func setCredentialSyncEnabled(_ enabled: Bool) {
        credentialSyncError = nil
        guard supportsCredentialSync, let connection, !isDemo else { return }
        if enabled {
            guard isConnected, let password = services.password(connection.keychainAccount) ?? storedPassword(for: connection) else {
                credentialSyncError = "Sign in with Remember me enabled before syncing your sign-in."
                return
            }
            guard services.saveSyncedPassword(password, connection) else {
                credentialSyncError = "Your sign-in is saved on this device, but couldn’t be saved to iCloud Keychain. Unlock your device and try again."
                return
            }
        } else if !services.deleteSyncedPassword(connection) {
            credentialSyncError = "The synced sign-in couldn’t be removed. Unlock your device and try again."
            return
        }
        recordCredentialSync(enabled, for: connection)
    }

    public var isDemo: Bool { library.isDemo }
    public var isConnected: Bool { library.drive != nil && connection != nil }
    /// Voice requests must not outlive a sign-out or another connection attempt.
    public var playbackConnectionToken: UUID { connectionGeneration }
    public var serverTitle: String { connection?.name ?? library.catalogue.serverName }

    public convenience init(library: LibraryStore) {
        self.init(library: library, defaults: .standard, services: ConnectionServices(), restoresSession: true)
    }

    init(library: LibraryStore, defaults: UserDefaults, services: ConnectionServices, restoresSession: Bool) {
        self.library = library
        indexer = LibraryIndexer()
        self.defaults = defaults
        self.services = services
        library.onMetadataWriteWillBegin = { [weak self] in self?.indexer.cancel() }
        library.fileDeletionConnectionTokenProvider = { [weak self] in
            guard let self, self.isConnected, self.pendingServer == nil,
                  !self.isScanning, !self.isRestoring, !self.isReconnecting,
                  !self.isSigningIn, !self.isJoiningFamily else { return nil }
            return self.connectionGeneration
        }
        loadSettings()
        if let data = defaults.data(forKey: "family.access.v2"),
           let records = try? JSONDecoder().decode([String: FamilyAccessRecord].self, from: data) {
            familyAccessRecords = records
        }
        if restoresSession { restoreSession() }
    }

    /// Invalidate every suspended connection operation before a new intent takes over.
    @discardableResult
    private func beginConnectionChange() -> UUID {
        onConnectionWillChange?()
        connectionGeneration = UUID()
        isSigningIn = false
        isRestoring = false
        isReconnecting = false
        isJoiningFamily = false
        pendingReconnectPassword = nil
        reconnectRequestedDuringAttempt = false
        isScanRequestPending = false
        indexer.cancel()
        demoTask?.cancel()
        demoTask = nil
        demoScanning = false
        // Tag writes belong to the connection they started on; the song being written finishes, the rest stop.
        library.metadataWriter.cancel()
        return connectionGeneration
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    public func findServers() {
        joiningFamily = nil
        pendingCloudConnection = nil
        pendingCloudCredentialSync = false
        beginConnectionChange()
        stage = .discovering
        discovery.start()
    }

    public func select(_ server: DiscoveredServer) {
        joiningFamily = nil
        pendingCloudConnection = nil
        pendingCloudCredentialSync = false
        beginConnectionChange()
        signInError = nil
        needsOTP = false
        pendingServer = server
    }

    /// Accepts a host, host:port or full URL typed by the user.
    @discardableResult
    public func enterAddress(_ text: String) -> Bool {
        guard let url = SynologyClient.baseURL(from: text), let host = url.host() else { return false }
        if stage == .welcome { stage = .discovering; discovery.start() }
        select(DiscoveredServer(name: host, baseURL: url, model: nil))
        return true
    }

    /// Takes an address, finds where DSM answers, and offers that server for sign-in.
    public func connect(to entry: String, provider kind: NASProviderKind = .synology, share: String = "", domain: String = "", requiresEncryption: Bool = true) async throws {
        if kind != .synology {
            let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text.contains("://") ? text : (kind == .smb ? "smb://" : "https://") + text) else { throw ProviderError.invalidConfiguration }
            // A pasted "Music " must not reach the server as a different share name.
            let share = share.trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = try ProviderConfiguration(kind: kind, endpoint: url, share: kind == .smb ? share : nil,
                                                   domain: kind == .smb ? domain : nil, requiresEncryption: requiresEncryption)
            if stage == .welcome { stage = .discovering }
            select(DiscoveredServer(name: url.host() ?? kind.title, baseURL: config.endpoint, model: nil, provider: config))
            return
        }
        let generation = beginConnectionChange()
        let url = try await SynologyClient.reachableBaseURL(for: entry.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isCurrent(generation) else { throw CancellationError() }
        guard enterAddress(url.absoluteString) else { throw SynologyError.invalidAddress }
    }

    /// Offers a DSM found on the network for sign-in once HTTPS answers at its address with a
    /// certificate this device trusts. Discovery resolves a LAN address, which DSM's own certificate
    /// and certificates for a hostname rarely cover, so that is found out before any password is
    /// typed and reported with the same advice as a typed address.
    public func connect(to server: DiscoveredServer) async throws {
        guard server.providerKind == .synology, server.provider == nil, NASOrigin(url: server.baseURL)?.isHTTPS == true else {
            select(server)
            return
        }
        let generation = beginConnectionChange()
        let url = try await SynologyClient.reachableBaseURL(for: server.baseURL.absoluteString)
        guard isCurrent(generation) else { throw CancellationError() }
        select(DiscoveredServer(name: server.name, baseURL: url, model: server.model))
    }

    public func cancelSignIn() {
        beginConnectionChange()
        pendingCloudConnection = nil
        pendingCloudCredentialSync = false
        pendingServer = nil
        needsOTP = false
        pendingReconnectPassword = nil
    }

    public func signIn(account: String, password: String, otpCode: String, remember: Bool, syncCredentials: Bool = false) async {
        // Return in a field can arrive while an attempt is running. Starting again would discard it,
        // count a wrong password twice toward DSM's auto-block, or send a one-time code twice.
        guard !isSigningIn, let server = pendingServer else { return }
        let cloudConnection = pendingCloudConnection
        let wasUsingSyncedCredentials = pendingCloudCredentialSync
        // A scan asked for while offline may have led here, when the saved sign-in needed the person.
        let scanRequested = isScanRequestPending
        let generation = beginConnectionChange()
        isSigningIn = true
        signInError = nil
        credentialSyncError = nil
        defer { if generation == connectionGeneration { isSigningIn = false } }
        do {
            let opened = try await openConnection(ServerConnection(name: server.name, baseURL: server.baseURL, account: account, musicPath: nil, provider: server.provider), password: password, otp: otpCode.isEmpty ? nil : otpCode)
            guard isCurrent(generation) else { if let session = opened.session { await services.logout(session) }; return }
            let name = opened.name
            var connection = ServerConnection(
                name: name, baseURL: server.baseURL, account: account,
                musicPath: nil, provider: server.provider
            )
            if let previous = self.connection, previous.sourceID == connection.sourceID {
                connection.musicPath = previous.musicPath
            }
            if connection.musicPath == nil, let cloudConnection, cloudConnection.sourceID == connection.sourceID {
                connection.musicPath = cloudConnection.musicPath
            }
            if connection.musicPath == nil, let family = joiningFamily, family.familyAccount == nil || family.familyAccount == account, (try? family.connection(account: account).sourceID) == connection.sourceID {
                connection.musicPath = family.musicPath
            }
            self.connection = connection
            saveConnection()
            if remember {
                services.savePassword(password, connection.keychainAccount)
            } else {
                services.deletePassword(connection.keychainAccount)
                if connection.providerKind == .synology { services.deletePassword(connection.legacyKeychainAccount) }
            }
            if supportsCredentialSync {
                if remember && syncCredentials {
                    if services.saveSyncedPassword(password, connection) {
                        recordCredentialSync(true, for: connection)
                    } else {
                        // Keep the newly verified local password usable if an older cloud copy
                        // could not be replaced (for example while Keychain is locked).
                        recordCredentialSync(false, for: connection)
                        credentialSyncError = "Connected, but your sign-in couldn’t be saved to iCloud Keychain. Try again in Music Server settings."
                    }
                } else if credentialSyncEnabled(for: connection) || (wasUsingSyncedCredentials && cloudConnection?.sourceID == connection.sourceID) {
                    // A new device may be completing an OTP challenge before it has saved a
                    // local preference. Respect an explicit opt-out of that received secret too.
                    recordCredentialSync(true, for: connection)
                    setCredentialSyncEnabled(false)
                }
            }
            // Even if removal from a locked Keychain failed, opting out of Remember me must
            // not silently restore this device from the remaining synchronized copy.
            if !remember { recordCredentialSync(false, for: connection) }
            self.session = opened.session
            awaitsSignIn = false
            let drive = opened.drive
            services.log("Signed in to \(name) at \(server.address)")
            pendingServer = nil
            needsOTP = false
            pendingReconnectPassword = nil
            pendingCloudConnection = nil
            pendingCloudCredentialSync = false
            discovery.stop()
            if library.catalogue.belongs(to: connection), !library.isEmpty {
                library.drive = drive
                stage = .ready
                if scanRequested || isScanRequestPending { startIndexing(showsProgress: false) }
                startAutoRefresh()
            } else {
                library.replace(with: .empty, drive: drive)
                if connection.musicPath != nil { startIndexing(showsProgress: true) }
                else { stage = .chooseFolder }
            }
        } catch SynologyError.twoFactorRequired {
            guard isCurrent(generation) else { return }
            needsOTP = true
            if cloudConnection != nil && syncCredentials { pendingReconnectPassword = password }
            // DSM answers a code it didn't accept (Auth 404) the same way as a missing one.
            signInError = otpCode.isEmpty ? "Enter the code from your authenticator app."
                : "That code didn’t work. Enter the current code from your authenticator app."
        } catch {
            guard isCurrent(generation) else { return }
            services.log("Sign-in failed at \(server.address): \(error.localizedDescription)")
            signInError = error.localizedDescription
        }
    }

    /// Back to the folder picker, keeping the session.
    public func chooseAnotherFolder() {
        beginConnectionChange()
        stage = .chooseFolder
    }

    /// Signs in again at the saved address, keeping the current library.
    public func reconnect() async {
        await reconnect(within: nil)
    }

    /// Asking to reconnect is a new connection intent, so work tied to the old one stops. An automatic
    /// attempt stays `within` the connection generation it was started in and only retries the saved
    /// sign-in of an offline library: what waits for the server carries on, such as a voice request,
    /// an album link or a paused download, and anything the person starts meanwhile supersedes it.
    private func reconnect(within current: UUID?, thenScan: Bool = false) async {
        guard let saved = connection else { return }
        if let current, !isCurrent(current) || isReconnecting { return }
        let automatic = current != nil
        let generation = current ?? beginConnectionChange()
        if thenScan { isScanRequestPending = true }
        guard let password = storedPassword(for: saved) else {
            requestReauthentication(saved, needsOTP: false)
            return
        }
        isReconnecting = true
        defer {
            if generation == connectionGeneration {
                isReconnecting = false
                answerReconnectRequestedDuringAttempt()
            }
        }
        let connection = saved
        do {
            let opened = try await openConnection(connection, password: password)
            guard isCurrent(generation), !automatic || (self.connection == saved && library.drive == nil) else {
                if let session = opened.session { await services.logout(session) }
                return
            }
            self.session = opened.session
            self.connection = connection
            if credentialSyncEnabled(for: connection) { services.savePassword(password, connection.keychainAccount) }
            saveConnection()
            library.drive = opened.drive
            signInError = nil
            awaitsSignIn = false
            // A library that opened offline has not started its refreshes yet.
            if stage == .ready {
                if isScanRequestPending { startIndexing(showsProgress: false) }
                else if !library.isEmpty { refreshIfStale(olderThan: 30 * 60) }
                if !library.isEmpty { startAutoRefresh() }
            }
        } catch SynologyError.twoFactorRequired {
            guard isCurrent(generation) else { return }
            pendingReconnectPassword = password
            requestReauthentication(connection, needsOTP: true)
        } catch let error as SynologyError where error.requiresNewCredentials || error.refusesSignIn {
            guard isCurrent(generation) else { return }
            requestReauthentication(saved, needsOTP: false)
            signInError = error.localizedDescription
        } catch let error as NASTransportError {
            guard isCurrent(generation) else { return }
            requestReauthentication(saved, needsOTP: false)
            signInError = error.localizedDescription
        } catch where error.requiresProviderSignIn {
            guard isCurrent(generation) else { return }
            requestReauthentication(saved, needsOTP: false)
            signInError = error.localizedDescription
        } catch {
            guard isCurrent(generation) else { return }
            signInError = error.localizedDescription
        }
    }

    private func requestReauthentication(_ saved: ServerConnection, needsOTP: Bool) {
        awaitsSignIn = true
        if stage != .ready { stage = .discovering }
        pendingServer = DiscoveredServer(name: saved.name, baseURL: saved.baseURL, model: nil, provider: saved.provider)
        self.needsOTP = needsOTP
        if needsOTP {
            if pendingReconnectPassword != nil {
                signInError = "Enter the code from your authenticator app to reconnect."
            } else {
                signInError = "Enter your password and the code from your authenticator app to reconnect."
            }
        } else if saved.providerKind == .synology, services.password("\(saved.host)|\(saved.account)") != nil {
            signInError = "Confirm your password once for this server address. Earlier versions saved it without distinguishing server ports. After connecting and scanning, Settings can recover older favourites and playlists."
        } else {
            signInError = "Sign in again to reconnect to your server."
        }
    }

    private func openConnection(_ connection: ServerConnection, password: String, otp: String? = nil) async throws -> (session: DSMSession?, drive: any RemoteDrive, name: String) {
        if connection.providerKind != .synology {
            let drive = try await services.openProvider(connection, password)
            return (nil, drive, connection.name)
        }
        let session = try await services.login(connection.baseURL, connection.account, password, otp)
        let info = await services.info(session)
        let name = info?.model.map { "Synology \($0)" } ?? connection.name
        let sourceID = connection.sourceID
        // DSM ends sessions after a while; the drive then asks for a new one instead of failing from then on.
        let drive = services.synologyDrive(session, name) { [weak self] expired in
            guard let self else { throw SynologyError.notSignedIn }
            return try await self.renewSession(expired, sourceID: sourceID)
        }
        return (session, drive, name)
    }

    /// Signs in again with the saved password when DSM ends the session the library's drive uses,
    /// so playback and refreshes carry on unnoticed. Only the session this connection holds now is
    /// renewed. What only the person can answer, a one-time code or a changed password, is asked
    /// once through the usual sign-in, and the library stays offline rather than repeat a refusal.
    private func renewSession(_ expired: DSMSession, sourceID: String) async throws -> DSMSession {
        func stillCurrent() -> Bool {
            session?.sid == expired.sid && connection?.sourceID == sourceID
                && !isSigningIn && !isReconnecting && !isRestoring && !isJoiningFamily
        }
        // Not now rather than refused: the drive may ask again once the connection has settled.
        guard stillCurrent(), let saved = connection else { throw CancellationError() }
        guard let password = storedPassword(for: saved) else {
            sessionNeedsSignIn(expired, saved, needsOTP: false)
            throw SynologyError.notSignedIn
        }
        services.log("\(saved.name) ended the session; signing in again")
        let renewed: DSMSession
        do {
            renewed = try await services.login(saved.baseURL, saved.account, password, nil)
        } catch SynologyError.twoFactorRequired {
            if stillCurrent() {
                pendingReconnectPassword = password
                sessionNeedsSignIn(expired, saved, needsOTP: true)
            }
            throw SynologyError.twoFactorRequired
        } catch let error as SynologyError where error.requiresNewCredentials || error.refusesSignIn {
            if stillCurrent() {
                sessionNeedsSignIn(expired, saved, needsOTP: false)
                signInError = error.localizedDescription
            }
            throw error
        } catch let error as NASTransportError {
            if stillCurrent() {
                sessionNeedsSignIn(expired, saved, needsOTP: false)
                signInError = error.localizedDescription
            }
            throw error
        }
        guard stillCurrent() else {
            await services.logout(renewed)
            throw CancellationError()
        }
        // Sign-out and account administration use the live session from now on.
        session = renewed
        services.log("Signed in to \(saved.name) again")
        return renewed
    }

    /// The ended session can't be renewed without the person: the library goes offline and the
    /// sign-in sheet asks for what is missing.
    private func sessionNeedsSignIn(_ expired: DSMSession, _ saved: ServerConnection, needsOTP: Bool) {
        if let drive = library.drive as? SynologyDrive, drive.session.sid == expired.sid { library.drive = nil }
        session = nil
        requestReauthentication(saved, needsOTP: needsOTP)
    }

    public func downloadSource(for track: Track) -> RemoteDownloadSource? {
        guard let connection, let path = track.path, let drive = library.drive,
              profiles?.isLocked != true, drive.id == connection.sourceID,
              library.contentSourceID == drive.id, library.catalogue.driveID == drive.id,
              library.track(id: track.id)?.path == path else { return nil }
        if let webDAV = drive as? WebDAVDrive, services.password(connection.keychainAccount) != nil,
           let origin = NASOrigin(url: connection.baseURL), origin.isHTTPS,
           var request = try? webDAV.authenticatedRequest(for: path) {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            if let version = WebDAVDrive.strongETag(track.sourceVersion) {
                request.setValue(version, forHTTPHeaderField: "If-Match")
            }
            return .http(request, DownloadAuthentication(origin: origin, account: connection.account, keychainAccount: connection.keychainAccount))
        }
        if connection.providerKind != .synology, let files = drive as? any RemoteFileDrive { return .file(drive: files, path: path) }
        return nil
    }

    public var downloadsRequireOpenApp: Bool {
        guard let connection else { return false }
        return connection.providerKind == .smb
            || (connection.providerKind == .webDAV && services.password(connection.keychainAccount) == nil)
    }

    // MARK: Music folder

    public var musicPath: String? { connection?.musicPath }
    public var musicFolderLabel: String {
        guard let path = musicPath else { return "Not chosen" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Lists folders on the drive; nil lists the shared folders.
    public func loadFolders(in parent: String?) async throws -> [RemoteEntry] {
        guard let drive = library.drive else { throw SynologyError.notSignedIn }
        guard let parent else {
            let roots = try await drive.roots()
            services.log("Shares: \(roots.map(\.path).joined(separator: ", "))")
            return roots
        }
        let entries = try await drive.list(parent)
        services.log("Picker listed \(parent): \(entries.count) entries, \(entries.filter(\.isAudio).count) audio files")
        return entries.filter { $0.isDirectory && !RemoteDriveSupport.isSystemFolder($0.name) }
    }

    /// Records the folder to index and starts indexing. A library already open from this server stays
    /// on screen, with its favourites and playlists, until the new folder's scan publishes; that scan
    /// reuses the tags already read for songs the two folders share.
    public func chooseMusicFolder(path: String, showsProgress: Bool) {
        guard profiles?.isLocked != true, var connection, let drive = library.drive else { return }
        beginConnectionChange()
        let changed = connection.musicPath != path
        connection.musicPath = path
        self.connection = connection
        saveConnection()
        if (changed && showsProgress) || library.isEmpty || library.catalogue.driveID != drive.id {
            // Nothing of this server's to keep showing. The placeholder still belongs to it: the sample
            // library's empty source ID would load, and save edits into, the sample library's profile data.
            library.replace(with: Catalogue(serverName: connection.name, albums: [], indexedAt: .distantPast,
                                            rootPath: path, driveID: drive.id), drive: drive)
        }
        startIndexing(showsProgress: showsProgress)
    }

    /// Back from the folder picker to pick another server.
    public func cancelFolderChoice() {
        beginConnectionChange()
        if let session { Task { await SynologyClient.logout(session) } }
        session = nil
        library.replace(with: .empty, drive: nil)
        connection = nil
        saveConnection()
        stage = .discovering
        discovery.start()
    }

    // MARK: Indexing

    public private(set) var demoCount = 0
    private var demoTask: Task<Void, Never>?

    public var indexedCount: Int { isDemo ? demoCount : indexer.tracksFound }
    public var indexingFailure: LibraryIndexer.Failure? {
        if case .failed(let failure) = indexer.phase { return failure }
        return nil
    }
    public var isIndexed: Bool {
        isDemo ? demoCount >= SampleLibrary.displayedTrackTotal : indexer.structureReady && !library.isEmpty
    }
    public var scanCompleted: Bool { isDemo ? !demoScanning : indexer.phase == .done }
    public var scanStatusText: String {
        if isScanning { return "Scanning…" }
        if indexingFailure != nil { return "Scan failed" }
        return scanCompleted ? "Up to date" : "Not scanned this session"
    }
    public var isScanning: Bool { isDemo ? demoScanning : indexer.isRunning }
    private var demoScanning = false
    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only fixture for gestures and navigation while a refresh remains in progress.
    public var sampleScanDuration: Duration = .seconds(2.4)
    #else
    private let sampleScanDuration: Duration = .seconds(2.4)
    #endif

    private func startIndexing(showsProgress: Bool, forceMetadataReread: Bool = false) {
        guard !library.isDeletingFiles, !library.metadataWriter.isWriting, let drive = library.drive, let connection, let path = connection.musicPath else { return }
        isScanRequestPending = false
        if showsProgress { stage = .indexing }
        let shown = library.catalogue.isEmpty ? nil : library.catalogue
        // The library on screen may still be the previous folder's, kept while a newly chosen one is
        // scanned: its tags are reused, but its songs are not expected in the new folder.
        let existing = shown?.rootPath == path ? shown : nil
        let generation = connectionGeneration
        let metadataRevision = library.metadataMutationRevision
        indexer.start(drive: drive, rootPath: path, serverName: connection.name, existing: existing, reusingTagsFrom: existing == nil ? shown : nil, forceMetadataReread: forceMetadataReread, onVerifiedListing: { [weak self] catalogue in
            guard let self, generation == self.connectionGeneration,
                  metadataRevision == self.library.metadataMutationRevision,
                  self.connection == connection, self.library.drive?.id == drive.id else { return }
            let presentIDs = Set(catalogue.albums.flatMap(\.tracks).map(\.id))
            self.onVerifiedServerListing?(catalogue.driveID, presentIDs)
            guard let existing, existing.driveID == catalogue.driveID, existing.rootPath == catalogue.rootPath else { return }
            let removed = existing.removedTrackIDs(present: presentIDs)
            if !removed.isEmpty { self.library.onServerTracksDeleted?(catalogue.driveID, removed) }
        }) { [weak self] catalogue in
            guard let self, generation == connectionGeneration,
                  metadataRevision == library.metadataMutationRevision,
                  self.connection == connection, library.drive?.id == drive.id else { return }
            library.replace(with: catalogue, drive: drive)
            library.saveCatalogue()
        }
    }

    public func useSampleLibrary() {
        beginConnectionChange()
        pendingCloudConnection = nil
        pendingCloudCredentialSync = false
        joiningFamily = nil
        pendingServer = nil
        connection = nil
        saveConnection()
        session = nil
        indexer.cancel()
        library.replace(with: SampleLibrary.catalogue, drive: nil)
        library.seedDemoHistory()
        discovery.stop()
        startDemoIndexing()
    }

    public func openLibrary() {
        demoTask?.cancel()
        demoTask = nil
        demoScanning = false
        stage = .ready
        startAutoRefresh()
    }

    // MARK: Automatic refresh

    private var autoRefreshTask: Task<Void, Never>?

    /// Reconnects an offline library, checks a session that sat unused and refreshes stale library
    /// data on activation, while preserving the screen the user chose.
    /// Playback state is not a navigation request; only a tap or an explicit link opens the player.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .active else { return }
        reconnectIfOffline()
        checkSessionIfIdle()
        refreshIfStale(olderThan: 30 * 60)
    }

    // MARK: Automatic reconnection

    /// Automatic attempts are at least this far apart, however often the app returns or the network changes.
    var automaticReconnectInterval: Duration = .seconds(20)
    private var lastAutomaticReconnect: ContinuousClock.Instant?
    /// The one attempt waiting for the interval to end.
    private(set) var pendingAutomaticReconnect: Task<Void, Never>?
    /// Set while only the person can put the sign-in right (a one-time code, a rejected or missing
    /// password, an account DSM won't let in). Trying again unasked would repeat a refusal that DSM
    /// counts towards blocking the device.
    private var awaitsSignIn = false
    /// Set when a reason to reconnect came while the launch sign-in or a reconnection was on its way.
    /// That attempt may have set out on the network being left, so if it fails, another follows.
    private(set) var reconnectRequestedDuringAttempt = false
    private var stopObservingNetwork: (() -> Void)?

    /// A library that opened without its server, for example launched away from a home-only NAS,
    /// connects again by itself when the app returns, the network changes or a song needs the server.
    /// An attempt that can't reach the server stays quiet; a refused sign-in asks the person once.
    private func reconnectIfOffline() {
        guard stage == .ready, !isDemo, let saved = connection, library.drive == nil, pendingServer == nil, !awaitsSignIn,
              !isSigningIn, !isJoiningFamily else { return }
        guard !isRestoring, !isReconnecting else {
            reconnectRequestedDuringAttempt = true
            return
        }
        let now = ContinuousClock.now
        if let last = lastAutomaticReconnect, now < last + automaticReconnectInterval {
            // Too soon after the last attempt: one more follows when the interval is up.
            guard pendingAutomaticReconnect == nil else { return }
            let delay = last + automaticReconnectInterval - now
            pendingAutomaticReconnect = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.pendingAutomaticReconnect = nil
                self?.reconnectIfOffline()
            }
            return
        }
        lastAutomaticReconnect = now
        services.log("\(saved.name) is offline; reconnecting")
        let generation = connectionGeneration
        Task { await reconnect(within: generation) }
    }

    /// Called as the launch sign-in or a reconnection ends: a reason to reconnect that came meanwhile
    /// is answered now, if the library is still offline, spaced out like any other attempt.
    private func answerReconnectRequestedDuringAttempt() {
        guard reconnectRequestedDuringAttempt else { return }
        reconnectRequestedDuringAttempt = false
        reconnectIfOffline()
    }

    /// Watches for network changes only while there is a saved server to go back to.
    private func updateNetworkObservation() {
        guard connection != nil else {
            stopObservingNetwork?()
            stopObservingNetwork = nil
            return
        }
        guard stopObservingNetwork == nil else { return }
        stopObservingNetwork = services.observeNetwork { [weak self] in
            Task { @MainActor in self?.reconnectIfOffline() }
        }
    }

    /// Unused this long, a session is checked before the next song's stream address is made.
    var sessionCheckIdleTime: Duration = .seconds(5 * 60)

    /// DSM ends sessions that sit unused, and a player fetches a song's address on its own, where a
    /// refusal only reads as a broken track. After a pause one small request finds out first, and
    /// the drive renews the session if it has ended.
    private func checkSessionIfIdle() {
        guard stage == .ready, !isDemo, !isRestoring, !isReconnecting, let folder = connection?.musicPath,
              let drive = library.drive as? SynologyDrive, drive.timeSinceLastResponse >= sessionCheckIdleTime else { return }
        Task { try? await drive.checkSession(folder: folder) }
    }

    /// A song streaming from DSM failed. Its address may carry a session that has ended, or one
    /// renewed since: check, renewing if needed, and report whether a fresh address can be made now,
    /// so the player loads the song once more.
    public func recoverStream(from url: URL) async -> Bool {
        guard !isDemo, let folder = connection?.musicPath, let drive = library.drive as? SynologyDrive,
              let used = drive.sessionID(of: url) else { return false }
        if used == drive.session.sid { try? await drive.checkSession(folder: folder) }
        guard let current = library.drive as? SynologyDrive else { return false }
        return current.session.sid != used
    }

    public func refreshIfStale(olderThan age: TimeInterval) {
        guard watchFolder, stage == .ready, isConnected, !isDemo, !isScanning else { return }
        guard Date.now.timeIntervalSince(library.catalogue.indexedAt) > age else { return }
        services.log("Automatic refresh started")
        startIndexing(showsProgress: false)
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                guard let self, !Task.isCancelled else { return }
                refreshIfStale(olderThan: 55 * 60)
            }
        }
    }

    public func retryIndexing() {
        startIndexing(showsProgress: true)
    }

    public func backToServers() {
        beginConnectionChange()
        stage = .discovering
        discovery.start()
    }

    /// What keeps a scan from starting right now, so a pull or a tap that can't scan says why.
    public nonisolated enum ScanBlocker: Equatable, Sendable {
        /// Files are being deleted from the server; a listing now could catch the deletion half done.
        case deletingFiles
        /// Song information is being written into files; a scan now would read songs mid-write.
        case writingTags
        /// The saved server is being signed in to; a scan asked for now starts once it connects.
        case connecting
        /// The saved server can't be reached; asking to scan reconnects first.
        case offline

        public var message: String {
            switch self {
            case .deletingFiles: "Gumbo is deleting files from your music server. Scan again once that has finished."
            case .writingTags: "Gumbo is saving song information to your music files. Scan again once that has finished."
            case .connecting: "Connecting to your music server. A scan asked for now starts once it’s connected."
            case .offline: "Your music server can’t be reached right now. Gumbo reconnects before scanning."
            }
        }
    }

    public var scanBlocker: ScanBlocker? {
        guard !isDemo, stage == .ready else { return nil }
        if library.isDeletingFiles { return .deletingFiles }
        if library.metadataWriter.isWriting { return .writingTags }
        guard connection != nil, !isConnected else { return nil }
        return isRestoring || isReconnecting || isSigningIn ? .connecting : .offline
    }

    /// A scan was asked for that could not start yet. The next connection to the server starts it,
    /// and until a scan starts the library shows why it is waiting (`scanBlocker`).
    public private(set) var isScanRequestPending = false
    private var scanReconnectTask: Task<Void, Never>?

    /// Scans the music folder for changes. An offline library reconnects first, as Reconnect in
    /// Settings does, and scans once connected; while files are being written or deleted nothing
    /// starts, and `scanBlocker` says why.
    public func rescan() {
        // Repeated pulls join the scan already in progress rather than restarting it.
        guard !isScanning else { return }
        switch scanBlocker {
        case .deletingFiles?, .writingTags?, .connecting?:
            isScanRequestPending = true
            return
        case .offline?:
            isScanRequestPending = true
            // Until the attempt has set out, further pulls wait for this one.
            guard scanReconnectTask == nil else { return }
            scanReconnectTask = Task { [weak self] in
                await self?.reconnect(within: nil, thenScan: true)
                self?.scanReconnectTask = nil
            }
            return
        case nil:
            break
        }
        if isDemo {
            demoScanning = true
            demoTask?.cancel()
            let duration = sampleScanDuration
            demoTask = Task { [weak self] in
                do { try await Task.sleep(for: duration) }
                catch { return }
                self?.demoScanning = false
                self?.demoTask = nil
            }
        } else {
            startIndexing(showsProgress: false)
        }
    }

    /// Reads every song's tags again, including files whose server revision has not changed.
    /// The complete existing catalogue remains available if the folder listing fails.
    public func rereadMetadata() {
        guard isConnected, !isDemo, !isScanning else { return }
        startIndexing(showsProgress: false, forceMetadataReread: true)
    }

    public func signOut() async {
        beginConnectionChange()
        pendingCloudConnection = nil
        pendingCloudCredentialSync = false
        credentialSyncError = nil
        pendingServer = nil
        joiningFamily = nil
        needsOTP = false
        demoTask?.cancel()
        autoRefreshTask?.cancel()
        pendingAutomaticReconnect?.cancel()
        pendingAutomaticReconnect = nil
        lastAutomaticReconnect = nil
        awaitsSignIn = false
        let oldSession = session
        session = nil
        if let connection {
            services.deletePassword(connection.keychainAccount)
            if connection.providerKind == .synology { services.deletePassword(connection.legacyKeychainAccount) }
        }
        connection = nil
        saveConnection()
        onSignedOut?()
        services.deleteCatalogue()
        library.replace(with: .empty, drive: nil)
        selectedTab = .library
        facet = .recentlyAdded
        stage = .welcome
        if let oldSession { await services.logout(oldSession) }
    }

    /// Demo mode counts up to the sample catalogue's size before opening.
    private func startDemoIndexing() {
        demoTask?.cancel()
        demoCount = 0
        demoScanning = true
        stage = .indexing
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let total = SampleLibrary.displayedTrackTotal
                let remaining = total - demoCount
                demoCount = min(total, demoCount + Int((Double(remaining) / 14).rounded(.up)) + 37)
                if demoCount >= total {
                    demoScanning = false
                    return
                }
            }
        }
    }

    /// What a paired Apple Watch needs to reach the server on its own: the same address and account
    /// this device uses, with the password the Keychain holds for it. Nothing for the sample library.
    public func watchCredentials() -> WatchCredentials? {
        guard profiles?.sessionID != nil, let connection, !isDemo else { return nil }
        if connection.providerKind == .smb {
            return WatchCredentials(baseURL: connection.baseURL, account: "", password: "", driveID: library.catalogue.driveID, provider: connection.provider)
        }
        guard let password = storedPassword(for: connection) else { return nil }
        return WatchCredentials(baseURL: connection.baseURL, account: connection.account, password: password, driveID: library.catalogue.driveID, provider: connection.provider)
    }

    /// Only an exact-address legacy entry can migrate automatically; hostname-only entries require sign-in.
    private func storedPassword(for connection: ServerConnection) -> String? {
        if supportsCredentialSync, credentialSyncEnabled(for: connection),
           let password = services.syncedPassword(connection) { return password }
        if let password = services.password(connection.keychainAccount) { return password }
        guard connection.providerKind == .synology, let legacy = services.password(connection.legacyKeychainAccount) else { return nil }
        services.savePassword(legacy, connection.keychainAccount)
        if connection.providerKind == .synology { services.deletePassword(connection.legacyKeychainAccount) }
        return legacy
    }

    // MARK: Session restore

    private func restoreSession() {
        guard let data = defaults.data(forKey: "connection"),
              let saved = try? JSONDecoder().decode(ServerConnection.self, from: data)
        else { return }
        connection = saved
        restoreTagServiceConfiguration()
        if let cached = services.loadCatalogue(), cached.belongs(to: saved), !cached.isEmpty {
            library.replace(with: cached, drive: nil)
            stage = .ready
        }
        guard let password = storedPassword(for: saved) else {
            requestReauthentication(saved, needsOTP: false)
            return
        }
        let generation = connectionGeneration
        isRestoring = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == connectionGeneration {
                    isRestoring = false
                    answerReconnectRequestedDuringAttempt()
                }
            }
            let connection = saved
            do {
                let opened = try await openConnection(connection, password: password)
                guard isCurrent(generation) else { if let session = opened.session { await services.logout(session) }; return }
                self.session = opened.session
                if credentialSyncEnabled(for: connection) { services.savePassword(password, connection.keychainAccount) }
                let drive = opened.drive
                if library.isEmpty {
                    library.replace(with: .empty, drive: drive)
                    if connection.musicPath != nil {
                        startIndexing(showsProgress: true)
                    } else {
                        stage = .chooseFolder
                    }
                } else {
                    library.drive = drive
                    if isScanRequestPending { startIndexing(showsProgress: false) }
                    else { refreshIfStale(olderThan: 30 * 60) }
                    startAutoRefresh()
                }
            } catch SynologyError.twoFactorRequired {
                guard isCurrent(generation) else { return }
                pendingReconnectPassword = password
                requestReauthentication(saved, needsOTP: true)
            } catch let error as SynologyError where error.requiresNewCredentials || error.refusesSignIn {
                guard isCurrent(generation) else { return }
                requestReauthentication(saved, needsOTP: false)
                signInError = error.localizedDescription
            } catch let error as NASTransportError {
                guard isCurrent(generation) else { return }
                requestReauthentication(saved, needsOTP: false)
                signInError = error.localizedDescription
            } catch where error.requiresProviderSignIn {
                guard isCurrent(generation) else { return }
                requestReauthentication(saved, needsOTP: false)
                signInError = error.localizedDescription
            } catch {
                guard isCurrent(generation) else { return }
                if library.isEmpty {
                    stage = .discovering
                    discovery.start()
                    requestReauthentication(saved, needsOTP: false)
                }
                signInError = error.localizedDescription
            }
        }
    }

    private func saveConnection() {
        restoreTagServiceConfiguration()
        if let connection, let data = try? JSONEncoder().encode(connection) {
            defaults.set(data, forKey: "connection")
        } else {
            defaults.removeObject(forKey: "connection")
        }
    }

    // MARK: Browsing

    public var selectedTab: AppTab = .library {
        didSet {
            if selectedTab != .library { cancelPendingAlbumNavigation() }
            if selectedTab != .playlists { cancelPendingPlaylistNavigation() }
        }
    }
    public var facet: LibraryFacet = .recentlyAdded
    /// Set to push an album onto the Library tab from outside it, for example from the player sheet.
    public var albumToOpen: Album?
    public private(set) var albumNavigationRequest = 0
    private var albumNavigationCommand = UUID()

    struct PendingAlbumNavigation {
        let command: UUID
        let albumID: String
        let sourceID: String
        let connection: UUID
        let profileID: String?
        let profileSession: UUID?
    }

    /// Closes whatever is in front, switches to the Library tab and opens the album there.
    public func showAlbum(_ album: Album) {
        leaveNowPlaying()
        guard let request = beginAlbumNavigation(album) else { return }
        #if os(macOS)
        finishAlbumNavigation(request)
        #else
        Task { [weak self] in
            // Let the sheet finish dismissing before the page pushes underneath it.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.finishAlbumNavigation(request)
        }
        #endif
    }

    /// Platform navigation owners cancel a pending push when the listener chooses another section.
    public func cancelPendingAlbumNavigation() { albumNavigationCommand = UUID() }

    func beginAlbumNavigation(_ album: Album) -> PendingAlbumNavigation? {
        guard profiles?.isLocked != true, library.contentSourceID == library.catalogue.driveID,
              library.album(id: album.id) != nil else { return nil }
        albumNavigationCommand = UUID()
        albumNavigationRequest += 1
        selectedTab = .library
        return PendingAlbumNavigation(command: albumNavigationCommand, albumID: album.id,
                                      sourceID: library.catalogue.driveID, connection: connectionGeneration,
                                      profileID: profiles?.activeID, profileSession: profiles?.sessionID)
    }

    func finishAlbumNavigation(_ request: PendingAlbumNavigation) {
        guard request.command == albumNavigationCommand, selectedTab == .library,
              connectionGeneration == request.connection, profiles?.isLocked != true,
              profiles?.activeID == request.profileID, profiles?.sessionID == request.profileSession,
              library.catalogue.driveID == request.sourceID, library.contentSourceID == request.sourceID,
              let album = library.album(id: request.albumID) else { return }
        albumToOpen = album
    }

    public var playlistToOpen: Playlist?
    public private(set) var playlistNavigationRequest = 0
    private var playlistNavigationCommand = UUID()

    struct PendingPlaylistNavigation {
        let command: UUID
        let playlistID: String
        let sourceID: String
        let rootPath: String
        let connection: UUID
        let profileSession: UUID?
    }

    public func cancelPendingPlaylistNavigation() { playlistNavigationCommand = UUID() }

    func beginPlaylistNavigation(_ playlist: Playlist) -> PendingPlaylistNavigation? {
        guard profiles?.isLocked != true, library.contentSourceID == library.catalogue.driveID,
              library.playlist(id: playlist.id) != nil else { return nil }
        playlistNavigationCommand = UUID()
        playlistNavigationRequest += 1
        selectedTab = .playlists
        return PendingPlaylistNavigation(command: playlistNavigationCommand, playlistID: playlist.id,
            sourceID: library.catalogue.driveID, rootPath: library.catalogue.rootPath,
            connection: connectionGeneration, profileSession: profiles?.sessionID)
    }

    func finishPlaylistNavigation(_ request: PendingPlaylistNavigation) {
        guard request.command == playlistNavigationCommand, selectedTab == .playlists,
              connectionGeneration == request.connection, profiles?.isLocked != true,
              profiles?.sessionID == request.profileSession,
              library.catalogue.driveID == request.sourceID, library.contentSourceID == request.sourceID,
              library.catalogue.rootPath == request.rootPath,
              let playlist = library.playlist(id: request.playlistID) else { return }
        playlistToOpen = playlist
    }

    public func clearProfileNavigation() {
        searchQuery = ""
        cancelPendingAlbumNavigation()
        cancelPendingPlaylistNavigation()
        albumToOpen = nil
        playlistToOpen = nil
    }

    /// Switches to the Playlists tab and opens its current contents in the same authenticated session.
    public func showPlaylist(_ playlist: Playlist) {
        leaveNowPlaying()
        guard let request = beginPlaylistNavigation(playlist) else { return }
        #if os(macOS)
        finishPlaylistNavigation(request)
        #else
        Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.finishPlaylistNavigation(request)
        }
        #endif
    }

    /// A tab by the name a widget link carries.
    public func showTab(named name: String) {
        leaveNowPlaying()
        switch name {
        case "library": selectedTab = .library
        case "playlists": selectedTab = .playlists
        case "downloads": selectedTab = .downloads
        default: break
        }
    }

    // MARK: Now Playing

    /// The player sheet is up, or has been asked for from outside it. The phone binds its sheet to this;
    /// the Mac and the television have their own player surfaces and leave it alone.
    public var isNowPlayingPresented = false

    /// Opens the player in response to a mini-player tap or an explicit Live Activity/widget link.
    /// Nothing happens while a profile is locked, before the library is open or while the sign-in
    /// sheet is in front, and a sheet that is already up stays as it is.
    public func showNowPlaying() {
        guard stage == .ready, profiles?.isLocked != true, pendingServer == nil else { return }
        isNowPlayingPresented = true
    }

    /// Another destination is taking over, so close the player before navigating.
    private func leaveNowPlaying() {
        isNowPlayingPresented = false
    }

    /// Waits for the server sign-in that starts at launch, or for a reconnection of a library that
    /// is offline, so a song can stream, or gives up after the limit.
    public func waitForDrive(upTo limit: Duration) async {
        reconnectIfOffline()
        let deadline = ContinuousClock.now + limit
        while library.drive == nil, !isDemo, ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    public var searchQuery = ""

    public func browse(_ entry: BrowseEntry) {
        facet = entry.facet
        selectedTab = .library
    }

    // MARK: Optional NAS-side metadata

    private var tagServiceSetupGeneration = UUID()
    public var tagServiceConfiguration: TagServiceConfiguration? { library.tagServiceConfiguration }

    private func restoreTagServiceConfiguration() {
        guard let connection, let root = connection.musicPath,
              let data = defaults.data(forKey: "tagHelper." + connection.sourceID),
              let value = try? JSONDecoder().decode(TagServiceConfiguration.self, from: data),
              value.sourceID == connection.sourceID, value.libraryRoot == root else {
            library.tagServiceConfiguration = nil
            return
        }
        library.tagServiceConfiguration = value
    }

    public func configureTagService(address: String, token: String, allowsReviewedDeletion: Bool = false) async throws {
        try Task.checkCancellation()
        guard profiles?.canManageProfiles == true, let connection, let root = connection.musicPath, isConnected,
              !library.metadataWriter.isWriting, !library.isDeletingFiles,
              library.catalogue.driveID == connection.sourceID, library.contentSourceID == connection.sourceID,
              library.catalogue.rootPath == root, library.contentRootPath == root,
              let endpoint = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ProviderError.invalidConfiguration }
        let generation = connectionGeneration
        let profileSession = profiles?.sessionID
        let setup = UUID()
        tagServiceSetupGeneration = setup
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard tagServiceSetupGeneration == setup, isCurrent(generation),
                  profiles?.sessionID == profileSession, profiles?.canManageProfiles == true,
                  self.connection?.sourceID == connection.sourceID, self.connection?.musicPath == root,
                  !library.metadataWriter.isWriting, !library.isDeletingFiles else { throw CancellationError() }
        }
        let value = TagServiceConfiguration(endpoint: endpoint, sourceID: connection.sourceID, libraryRoot: root, allowsReviewedDeletion: allowsReviewedDeletion)
        let client = try services.tagService(endpoint, token)
        let capabilities = try await client.capabilities()
        try checkCurrent()
        guard !allowsReviewedDeletion || (capabilities.supportsReviewedDeletion == true && capabilities.supportsVerifiedInspection == true) else {
            throw RemoteTagService.Error.service(code: "deletion_disabled", message: "Enable reviewed deletion in the helper's server settings before enabling it here.")
        }
        // Catch a wrong mount before enabling writes. The user explicitly confirms the folder mapping.
        guard let sample = library.catalogue.albums.flatMap(\.tracks).first(where: { track in
            guard let path = track.path, !track.isHiddenFile else { return false }
            let extensionName = (path as NSString).pathExtension.lowercased()
            return allowsReviewedDeletion ? RemoteDriveSupport.audioExtensions.contains(extensionName) : ["mp3", "flac", "m4a"].contains(extensionName)
        }), let path = sample.path else { throw MetadataWriteError.noFile }
        if allowsReviewedDeletion {
            guard let base = library.drive as? any RemoteFileDrive else { throw ProviderError.invalidConfiguration }
            let reviewed = try await HelperDeletionDrive(base: base, configuration: value, service: client).reviewDeletion(path)
            guard sample.fileSize == nil || sample.fileSize == reviewed.size else { throw ProviderError.changed }
        } else {
            let state = try await client.stat(path: value.relativePath(path))
            guard sample.fileSize == nil || sample.fileSize == state.expected.size else { throw ProviderError.changed }
        }
        try checkCurrent()
        services.savePassword(token, value.keychainAccount)
        guard services.password(value.keychainAccount) == token else { throw RemoteTagService.Error.invalidToken }
        defaults.set(try JSONEncoder().encode(value), forKey: "tagHelper." + connection.sourceID)
        library.tagServiceConfiguration = value
    }

    public func disableTagService() {
        guard profiles?.canManageProfiles == true, let connection, !library.metadataWriter.isWriting, !library.isDeletingFiles else { return }
        tagServiceSetupGeneration = UUID()
        if let value = library.tagServiceConfiguration { services.deletePassword(value.keychainAccount) }
        defaults.removeObject(forKey: "tagHelper." + connection.sourceID)
        library.tagServiceConfiguration = nil
    }

    // MARK: Settings

    /// Scans stop when the phone locks; leaving the screen on is the one reliable way to finish a long one.
    public var keepsScreenOnWhileScanning: Bool = UserDefaults.standard.object(forKey: "scan.keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepsScreenOnWhileScanning, forKey: "scan.keepAwake") }
    }

    public var watchFolder = true {
        didSet {
            guard profiles?.isLocked != true else { watchFolder = oldValue; return }
            defaults.set(watchFolder, forKey: "watchFolder")
            if watchFolder { refreshIfStale(olderThan: 10 * 60) }
        }
    }
    public var profiles: ProfileStore?
    public var quality: StreamQuality = .lossless { didSet { profiles?.updateSettings { $0.quality = quality.rawValue } } }
    public var appearance: Appearance = .auto { didSet { profiles?.updateSettings { $0.appearance = appearance.rawValue } } }
    public var gapless = true { didSet { profiles?.updateSettings { $0.gapless = gapless } } }

    /// What the family record says about this server, once a folder is chosen.
    public var familyInfo: FamilyInfo? {
        guard let connection, connection.musicPath != nil else { return nil }
        // Family Access kept here names its account even when its password cannot be read on this
        // device, so sync keeps iCloud's copy instead of taking it for a removal.
        let source = connection.sourceID
        let record = familyRevocationPending ? nil : familyAccessRecords[source].flatMap { $0.sourceID == source ? $0 : nil }
        let access = record == nil ? nil : familyAccess
        return FamilyInfo(
            name: "\(connection.name) family", serverName: connection.name,
            serverAccount: connection.account, musicPath: connection.musicPath, updatedAt: .distantPast,
            familyAccount: record?.account, familyPassword: access?.password,
            address: connection.baseURL.absoluteString, provider: connection.provider,
            credentialsRevision: record?.revision
        )
    }

    // MARK: Family access

    /// A connection sees only family credentials verified for its exact origin and provisioning account.
    private var familyAccessRecords: [String: FamilyAccessRecord] = [:]
    public var familyAccess: FamilyAccess? {
        guard let source = connection?.sourceID, let record = familyAccessRecords[source],
              record.sourceID == source, let password = services.password(record.keychainAccount) else { return nil }
        return FamilyAccess(account: record.account, password: password, sourceID: source)
    }
    public var familyRevocationPending: Bool {
        guard let source = connection?.sourceID else { return false }
        return familyAccessRecords[source]?.pendingRevocationScope != nil
    }
    public var canManageNASAccounts: Bool { connection?.providerKind == .synology }
    public var familyAccessNeedsVerification: Bool {
        familyAccess == nil && (!familyAccessRecords.isEmpty || defaults.string(forKey: "family.account") != nil)
    }
    public var onFamilyAccessChanged: (() -> Void)?
    public private(set) var isChangingFamilyAccess = false
    public private(set) var isJoiningFamily = false

    private func persistFamilyRecords() throws {
        defaults.set(try JSONEncoder().encode(familyAccessRecords), forKey: "family.access.v2")
    }

    private func store(_ access: FamilyAccess?, sourceID: String) throws {
        guard connection?.sourceID == sourceID else { throw CancellationError() }
        let previous = familyAccessRecords[sourceID]
        if let previous, previous.pendingRevocationScope != nil, access?.account != previous.account {
            throw CocoaError(.userCancelled)
        }
        if let access {
            guard access.sourceID == sourceID else { throw CancellationError() }
            let record = FamilyAccessRecord(account: access.account, sourceID: sourceID,
                                            pendingRevocationScope: previous?.pendingRevocationScope,
                                            revision: UUID().uuidString)
            services.savePassword(access.password, record.keychainAccount)
            guard services.password(record.keychainAccount) == access.password else {
                throw CocoaError(.fileWriteNoPermission)
            }
            familyAccessRecords[sourceID] = record
            try persistFamilyRecords()
            if let previous, previous.keychainAccount != record.keychainAccount {
                services.deletePassword(previous.keychainAccount)
            }
        } else {
            familyAccessRecords.removeValue(forKey: sourceID)
            try persistFamilyRecords()
            if let previous { services.deletePassword(previous.keychainAccount) }
        }
        onFamilyAccessChanged?()
    }

    private struct FamilyContext {
        let connection: UUID
        let profileSession: UUID?
    }

    private var familyContext: FamilyContext {
        FamilyContext(connection: connectionGeneration, profileSession: profiles?.sessionID)
    }

    private func checkFamilyContext(_ expected: FamilyContext, sourceID: String) throws {
        guard isCurrent(expected.connection), connection?.sourceID == sourceID,
              profiles?.sessionID == expected.profileSession, profiles?.isLocked != true else { throw CancellationError() }
    }

    private var musicShareName: String? {
        connection?.musicPath?.split(separator: "/").first.map(String.init)
    }

    /// Makes the family account on the NAS with a long random password and read-only access to the
    /// music share. Returns what went wrong, if anything; the owner's account must be an administrator.
    public func setUpFamilyAccess() async -> String? {
        guard profiles?.canManageProfiles != false else { return "Open the owner profile before changing family access." }
        guard !isChangingFamilyAccess else { return "Wait for the current family access change to finish." }
        isChangingFamilyAccess = true
        defer { isChangingFamilyAccess = false }
        guard !familyRevocationPending else { return "Finish stopping sharing before creating another family account." }
        guard session != nil, let connection else { return "Not connected to the server." }
        guard let share = musicShareName else { return "Choose the music folder first." }
        let expected = familyContext
        let account = "gumbo-" + Self.randomToken(length: 6, from: "abcdefghijkmnpqrstuvwxyz23456789")
        let password = Self.randomPassword()
        do {
            try await withAdministrator { admin, confirm in
                try await self.services.createFamilyUser(admin, account, password, share, confirm)
            }
            try checkFamilyContext(expected, sourceID: connection.sourceID)
            try store(FamilyAccess(account: account, password: password, sourceID: connection.sourceID), sourceID: connection.sourceID)
            services.log("Family account \(account) ready with read-only access to “\(share)” on \(connection.name)")
            return nil
        } catch {
            services.log("Family account could not be created: \(error.localizedDescription)")
            return "Your NAS wouldn't let the app create the account. DSM blocks account management from outside its own web interface, especially with two-factor authentication on. Use “Add an account yourself” below; it takes a minute and works everywhere."
        }
    }

    /// Runs a change that DSM treats as privileged. Two things can stand in the way: DSM wants a
    /// fresh confirmation of the host's own password, and over a public route it only accepts these
    /// calls from a session that did the full sign-in handshake. The work is tried on the session
    /// that is already open, then on a dedicated DSM session that has both.
    private func withAdministrator(_ body: (DSMSession, String?) async throws -> Void) async throws {
        guard profiles?.canManageProfiles != false, let session, let connection else { throw SynologyError.notSignedIn }
        // Only the session that is already open is used. Signing in again to gain more rights fails
        // on any account with two-factor authentication, and repeated tries make DSM mail its owner
        // emergency codes and eventually block the device, so the app never does that on its own.
        let expected = familyContext
        guard await services.canManageUsers(session) == true else {
            services.log("\(connection.account) may not manage users through this connection")
            throw SynologyError.api(code: 105, api: "SYNO.Core.User")
        }
        try checkFamilyContext(expected, sourceID: connection.sourceID)
        var confirm: String?
        if let password = storedPassword(for: connection) {
            confirm = await services.confirmPassword(session, password)
        }
        try checkFamilyContext(expected, sourceID: connection.sourceID)
        try await body(session, confirm)
    }

    /// An account the owner made by hand; checked with a sign-in before it is kept.
    public func useFamilyAccess(account: String, password: String) async -> String? {
        guard profiles?.canManageProfiles != false else { return "Open the owner profile before changing family access." }
        guard !isChangingFamilyAccess else { return "Wait for the current family access change to finish." }
        isChangingFamilyAccess = true
        defer { isChangingFamilyAccess = false }
        guard let connection else { return "Not connected to the server." }
        if let pending = familyAccessRecords[connection.sourceID], pending.pendingRevocationScope != nil,
           pending.account != account {
            return "Verify the existing family account \(pending.account) to finish stopping sharing before using another account."
        }
        let expected = familyContext
        do {
            var candidate = connection
            candidate.account = account
            let probe = try await openConnection(candidate, password: password)
            if let session = probe.session { await services.logout(session) }
            try checkFamilyContext(expected, sourceID: connection.sourceID)
            try store(FamilyAccess(account: account, password: password, sourceID: connection.sourceID), sourceID: connection.sourceID)
            services.log("Family account \(account) set by hand")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A new password for the family account, so devices that left stop working.
    public func rotateFamilyAccess() async -> String? {
        guard !isChangingFamilyAccess else { return "Wait for the current family access change to finish." }
        isChangingFamilyAccess = true
        defer { isChangingFamilyAccess = false }
        guard !familyRevocationPending else { return "Finish stopping sharing before changing the family password." }
        return await rotateFamilyAccess(verifyScope: { true })
    }

    private func rotateFamilyAccess(verifyScope: () -> Bool) async -> String? {
        guard session != nil, let access = familyAccess else { return "Reconnect to the NAS before changing family access." }
        let expected = familyContext
        let password = Self.randomPassword()
        do {
            try await withAdministrator { admin, confirm in
                try await self.services.setFamilyPassword(admin, access.account, password, confirm)
            }
            try checkFamilyContext(expected, sourceID: access.sourceID)
            guard verifyScope() else { throw CancellationError() }
            try store(FamilyAccess(account: access.account, password: password, sourceID: access.sourceID), sourceID: access.sourceID)
            services.log("Family account password rotated")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Keep the local recovery details until the NAS confirms deletion.
    public func removeFamilyAccess() async -> String? {
        guard profiles?.canManageProfiles != false else { return "Open the owner profile before changing family access." }
        guard !isChangingFamilyAccess else { return "Wait for the current family access change to finish." }
        isChangingFamilyAccess = true
        defer { isChangingFamilyAccess = false }
        guard !familyRevocationPending else { return "Finish stopping sharing before removing the saved family account." }
        guard session != nil, let access = familyAccess else { return "Reconnect to the NAS before removing family access." }
        let expected = familyContext
        do {
            try await withAdministrator { admin, confirm in
                try await self.services.deleteFamilyUser(admin, access.account, confirm)
            }
            try checkFamilyContext(expected, sourceID: access.sourceID)
            try store(nil, sourceID: access.sourceID)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Revocation is complete only after CloudKit confirms removal and the NAS password changes.
    public func stopFamilySharing(using cloud: CloudSync, authorization supplied: CloudSync.SharingAuthorization? = nil) async -> String? {
        guard let authorization = supplied ?? cloud.sharingAuthorization() else { return "Open your own profile before changing family sharing." }
        do { try cloud.checkSharingAuthorization(authorization) } catch { return "The profile changed. Try again from your current profile." }
        guard !isChangingFamilyAccess else { return "Wait for the current family access change to finish." }
        isChangingFamilyAccess = true
        defer { isChangingFamilyAccess = false }
        let wasOwner = cloud.isOwner
        let expected = familyContext
        let source = connection?.sourceID
        let scope = cloud.sharingScopeIdentifier
        let hadNASAccess = familyAccess != nil || !familyAccessRecords.isEmpty
            || defaults.string(forKey: "family.account") != nil || cloud.family?.familyAccount != nil
        do {
            if wasOwner, let source, var record = familyAccessRecords[source] {
                guard let scope else { return "Refresh iCloud before stopping family sharing." }
                if let pending = record.pendingRevocationScope, pending != scope {
                    return "This pending change belongs to another Apple Account or family. Return to that account to finish it."
                }
                record.pendingRevocationScope = scope
                familyAccessRecords[source] = record
                try persistFamilyRecords()
            }
            try await cloud.stopSharing(authorization: authorization)
            guard wasOwner else { return nil }
            guard let source else {
                return hadNASAccess ? "iCloud sharing has stopped. Reconnect to the original NAS and revoke its family account in your NAS administration; NAS access has not been confirmed as revoked." : nil
            }
            try checkFamilyContext(expected, sourceID: source)
            guard scope == cloud.sharingScopeIdentifier else { throw CancellationError() }
            if familyAccess != nil {
                if !canManageNASAccounts {
                    onFamilyAccessChanged?()
                    return "iCloud sharing has stopped. Change or disable the shared account in your NAS administration and end its existing sessions. Gumbo cannot revoke this provider's account automatically; downloaded files may remain on other devices."
                }
                if let error = await rotateFamilyAccess(verifyScope: { cloud.sharingScopeIdentifier == scope }) {
                    return "iCloud sharing has stopped, but NAS access has not been revoked. \(error) Retry here, or change the family account password in DSM. Existing NAS sessions may also need to be ended in DSM."
                }
                try checkFamilyContext(expected, sourceID: source)
                guard cloud.sharingScopeIdentifier == scope else { throw CancellationError() }
                familyAccessRecords[source]?.pendingRevocationScope = nil
                try persistFamilyRecords()
                onFamilyAccessChanged?()
            } else if hadNASAccess {
                return "iCloud sharing has stopped, but the saved NAS credentials could not be verified. Change or disable the family account in your NAS administration, end its existing sessions, then verify family access here."
            }
            return nil
        } catch {
            return "Family sharing could not be fully stopped. \(error.localizedDescription) Retry after reconnecting."
        }
    }

    /// The owner reports completing revocation outside Gumbo. This never claims that Gumbo
    /// inspected NAS sessions, and cannot clear recovery while iCloud sharing still exists.
    public func acknowledgeManualFamilyRevocation(using cloud: CloudSync) async -> String? {
        guard profiles?.canManageProfiles != false, let authorization = cloud.sharingAuthorization(),
              cloud.isOwner, !cloud.isShared, !canManageNASAccounts,
              !isChangingFamilyAccess, let source = connection?.sourceID,
              let record = familyAccessRecords[source], let scope = record.pendingRevocationScope,
              scope == cloud.sharingScopeIdentifier else {
            return "Stop iCloud sharing from the owner profile before finishing this step."
        }
        let expected = familyContext
        isChangingFamilyAccess = true
        defer { isChangingFamilyAccess = false }
        do {
            // isShared is a local snapshot; an explicit acknowledgement is still required when
            // the previous stop failed, the app relaunched, or the share was recreated elsewhere.
            try await cloud.stopSharing(authorization: authorization)
            try cloud.checkSharingAuthorization(authorization)
            try checkFamilyContext(expected, sourceID: source)
            guard cloud.sharingScopeIdentifier == scope else { throw CancellationError() }
            familyAccessRecords[source] = nil
            try persistFamilyRecords()
            services.deletePassword(record.keychainAccount)
            onFamilyAccessChanged?()
            return nil
        } catch { return "The saved family account could not be removed. Try again." }
    }

    /// The family record arrived: a member's device connects with the family account on its own,
    /// and picks up a rotated password.
    public func familyArrived(_ info: FamilyInfo, isOwner: Bool = false) {
        // An owner chooses their personal synced sign-in through Use This Library. Don't let
        // arrival of the family's separate read-only credentials win that setup race.
        if isOwner && connection == nil && supportsCredentialSync { return }
        guard let account = info.familyAccount, let password = info.familyPassword else { return }
        if let connection {
            if connection.account == account, (try? info.connection(account: account).sourceID) == connection.sourceID,
               storedPassword(for: connection) != password {
                services.savePassword(password, connection.keychainAccount)
                if supportsCredentialSync && credentialSyncEnabled(for: connection), !services.saveSyncedPassword(password, connection) {
                    recordCredentialSync(false, for: connection)
                    credentialSyncError = "Family Access has a new password. It is saved on this device, but couldn’t be updated in iCloud Keychain. Try again in Music Server settings."
                }
                Task { await reconnect() }
            }
            return
        }
        guard familyAccess == nil else { return }
        Task { await connectWithFamilyAccess(info) }
    }

    /// Signs in with the family account and indexes the family's folder; no password asked.
    public func connectWithFamilyAccess(_ info: FamilyInfo) async {
        guard info.isReachable, let account = info.familyAccount, let password = info.familyPassword, !isJoiningFamily else { return }
        let generation = beginConnectionChange()
        isJoiningFamily = true
        signInError = nil
        defer { if generation == connectionGeneration { isJoiningFamily = false } }
        do {
            let url = try familyURL(info)
            let saved = try info.connection(account: account)
            let opened = try await openConnection(saved, password: password)
            guard isCurrent(generation) else { if let session = opened.session { await services.logout(session) }; return }
            let name = opened.name
            let connection = ServerConnection(name: name, baseURL: url, account: account, musicPath: info.musicPath, provider: info.provider)
            self.connection = connection
            saveConnection()
            services.savePassword(password, connection.keychainAccount)
            self.session = opened.session
            awaitsSignIn = false
            discovery.stop()
            library.replace(with: .empty, drive: opened.drive)
            services.log("Connected to \(name) with the family account at \(url.host() ?? "its address")")
            if connection.musicPath != nil {
                startIndexing(showsProgress: true)
            } else {
                stage = .chooseFolder
            }
        } catch let error as SynologyError where error.requiresNewCredentials {
            guard isCurrent(generation) else { return }
            if let url = try? familyURL(info) {
                select(DiscoveredServer(name: info.serverName, baseURL: url, model: nil, provider: info.provider))
                joiningFamily = info
            }
            signInError = error.localizedDescription
        } catch let error as NASTransportError {
            guard isCurrent(generation) else { return }
            if let url = try? familyURL(info) {
                select(DiscoveredServer(name: info.serverName, baseURL: url, model: nil, provider: info.provider))
                joiningFamily = info
            }
            signInError = error.localizedDescription
        } catch where error.requiresProviderSignIn {
            guard isCurrent(generation) else { return }
            if let url = try? familyURL(info) {
                select(DiscoveredServer(name: info.serverName, baseURL: url, model: nil, provider: info.provider))
                joiningFamily = info
            }
            signInError = error.localizedDescription
        } catch {
            guard isCurrent(generation) else { return }
            services.log("Family sign-in failed: \(error.localizedDescription)")
            signInError = error.localizedDescription
        }
    }

    private static func randomToken(length: Int, from alphabet: String) -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    /// Twenty-four characters with letters of both cases, digits and symbols, for any DSM password policy.
    private static func randomPassword() -> String {
        let sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789", "!#*@_-"]
        var characters = sets.map { $0.randomElement()! }
        let all = sets.joined()
        characters += (0..<20).map { _ in all.randomElement()! }
        return String(characters.shuffled())
    }

    /// The family this device is joining; its music folder is used instead of asking.
    private var joiningFamily: FamilyInfo?
    public var pendingFamilyAccount: String? { pendingCloudConnection?.account ?? joiningFamily?.familyAccount }
    public var pendingFamilyPassword: String? {
        if pendingCloudConnection != nil { return pendingReconnectPassword }
        return joiningFamily?.familyPassword
    }

    /// Use a personal Keychain item only for a verified owner's exact saved server/account.
    /// Members keep the separate Family Access route. No personal secret enters CloudKit.
    public func useCloudLibrary(_ info: FamilyInfo, isOwner: Bool) async {
        guard info.isReachable, !isSigningIn, !isJoiningFamily else { return }
        if isOwner, let saved = try? info.connection(account: info.serverAccount),
           !info.serverAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let password = supportsCredentialSync ? services.syncedPassword(saved) : nil
            if password != nil || info.familyAccount == nil || info.familyPassword == nil {
                if stage == .welcome { stage = .discovering }
                select(DiscoveredServer(name: saved.name, baseURL: saved.baseURL, model: nil, provider: saved.provider))
                joiningFamily = info
                pendingCloudConnection = saved
                pendingCloudCredentialSync = password != nil
                guard let password else { return }
                await signIn(account: saved.account, password: password, otpCode: "", remember: true, syncCredentials: true)
                return
            }
        }
        if info.familyAccount != nil && info.familyPassword != nil {
            await connectWithFamilyAccess(info)
        } else {
            await joinFamilyServer(info)
        }
    }

    /// A member's device: reach the family's server and ask for the password.
    public func joinFamilyServer(_ info: FamilyInfo) async {
        guard info.isReachable else { return }
        do {
            select(DiscoveredServer(name: info.serverName, baseURL: try familyURL(info), model: nil, provider: info.provider))
            joiningFamily = info
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// The family's server as the owner reaches it.
    private func familyURL(_ info: FamilyInfo) throws -> URL {
        return try info.connection(account: info.serverAccount).baseURL
    }

    /// Reads the active profile's preferences.
    public func applyProfileSettings() {
        guard let settings = profiles?.state.settings else { return }
        if let value = StreamQuality(rawValue: settings.quality), value != quality { quality = value }
        if let value = Appearance(rawValue: settings.appearance), value != appearance { appearance = value }
        if settings.gapless != gapless { gapless = settings.gapless }
    }

    /// Subtitle under the Library title: scan progress while indexing, otherwise when the folder was last read.
    public var librarySubtitle: String {
        if isScanning { return isDemo ? "Updating…" : (indexer.statusText ?? "Updating…") }
        guard library.catalogue.indexedAt > .distantPast else { return "" }
        let date = library.catalogue.indexedAt
        if Date.now.timeIntervalSince(date) < 60 { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: .now))"
    }

    /// When the folder was last read: the time today or yesterday, otherwise the date and time.
    public var lastScanText: String {
        if isScanning { return isDemo ? "Scanning…" : (indexer.statusText ?? "Scanning…") }
        let date = library.catalogue.indexedAt
        guard date > .distantPast else { return "Never" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " at " + time
    }

    private func loadSettings() {
        if defaults.object(forKey: "watchFolder") != nil { watchFolder = defaults.bool(forKey: "watchFolder") }
    }
}
