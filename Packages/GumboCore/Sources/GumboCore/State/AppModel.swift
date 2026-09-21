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
    public private(set) var connection: ServerConnection?
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
        if let pendingServer, NASOrigin(url: pendingServer.baseURL) != NASOrigin(url: connection.baseURL) { return false }
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
    public var isConnected: Bool { session != nil }
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
        connectionGeneration = UUID()
        isSigningIn = false
        isRestoring = false
        isReconnecting = false
        isJoiningFamily = false
        pendingReconnectPassword = nil
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
    public func connect(to entry: String) async throws {
        let generation = beginConnectionChange()
        let url = try await SynologyClient.reachableBaseURL(for: entry.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isCurrent(generation) else { throw CancellationError() }
        guard enterAddress(url.absoluteString) else { throw SynologyError.invalidAddress }
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
        guard let server = pendingServer else { return }
        let cloudConnection = pendingCloudConnection
        let wasUsingSyncedCredentials = pendingCloudCredentialSync
        let generation = beginConnectionChange()
        isSigningIn = true
        signInError = nil
        credentialSyncError = nil
        defer { if generation == connectionGeneration { isSigningIn = false } }
        do {
            let session = try await services.login(server.baseURL, account, password, otpCode.isEmpty ? nil : otpCode)
            guard isCurrent(generation) else { await services.logout(session); return }
            let info = await services.info(session)
            guard isCurrent(generation) else { await services.logout(session); return }
            let name = (info?.model ?? server.model).map { "Synology \($0)" } ?? server.name
            var connection = ServerConnection(
                name: name, baseURL: server.baseURL, account: account,
                musicPath: nil
            )
            if let previous = self.connection, previous.sourceID == connection.sourceID {
                connection.musicPath = previous.musicPath
            }
            if connection.musicPath == nil, let cloudConnection, cloudConnection.sourceID == connection.sourceID {
                connection.musicPath = cloudConnection.musicPath
            }
            if connection.musicPath == nil, let family = joiningFamily, family.familyAccount == nil || family.familyAccount == account, family.address.flatMap(URL.init(string:)).flatMap(NASOrigin.init(url:)) == NASOrigin(url: server.baseURL) {
                connection.musicPath = family.musicPath
            }
            self.connection = connection
            saveConnection()
            if remember {
                services.savePassword(password, connection.keychainAccount)
            } else {
                services.deletePassword(connection.keychainAccount)
                services.deletePassword(connection.legacyKeychainAccount)
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
            self.session = session
            let drive = SynologyDrive(session: session, displayName: name)
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
            signInError = "Enter the code from your authenticator app."
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
        guard let saved = connection else { return }
        let generation = beginConnectionChange()
        guard let password = storedPassword(for: saved) else {
            requestReauthentication(saved, needsOTP: false)
            return
        }
        isReconnecting = true
        defer { if generation == connectionGeneration { isReconnecting = false } }
        let connection = saved
        do {
            let session = try await services.login(connection.baseURL, connection.account, password, nil)
            guard isCurrent(generation) else { await services.logout(session); return }
            self.session = session
            self.connection = connection
            if credentialSyncEnabled(for: connection) { services.savePassword(password, connection.keychainAccount) }
            saveConnection()
            library.drive = SynologyDrive(session: session, displayName: connection.name)
            signInError = nil
        } catch SynologyError.twoFactorRequired {
            guard isCurrent(generation) else { return }
            pendingReconnectPassword = password
            requestReauthentication(connection, needsOTP: true)
        } catch let error as SynologyError where error.requiresNewCredentials {
            guard isCurrent(generation) else { return }
            requestReauthentication(saved, needsOTP: false)
            signInError = error.localizedDescription
        } catch let error as NASTransportError {
            guard isCurrent(generation) else { return }
            requestReauthentication(saved, needsOTP: false)
            signInError = error.localizedDescription
        } catch {
            guard isCurrent(generation) else { return }
            signInError = error.localizedDescription
        }
    }

    private func requestReauthentication(_ saved: ServerConnection, needsOTP: Bool) {
        if stage != .ready { stage = .discovering }
        pendingServer = DiscoveredServer(name: saved.name, baseURL: saved.baseURL, model: nil)
        self.needsOTP = needsOTP
        if needsOTP {
            if pendingReconnectPassword != nil {
                signInError = "Enter the code from your authenticator app to reconnect."
            } else {
                signInError = "Enter your password and the code from your authenticator app to reconnect."
            }
        } else if services.password("\(saved.host)|\(saved.account)") != nil {
            signInError = "Confirm your password once for this server address. Earlier versions saved it without distinguishing server ports. After connecting and scanning, Settings can recover older favourites and playlists."
        } else {
            signInError = "Sign in again to reconnect to your server."
        }
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
        return entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") && $0.name != "@eaDir" && $0.name != "#recycle" }
    }

    /// Records the folder to index and starts indexing.
    public func chooseMusicFolder(path: String, showsProgress: Bool) {
        guard profiles?.isLocked != true, var connection, let drive = library.drive else { return }
        beginConnectionChange()
        let changed = connection.musicPath != path
        connection.musicPath = path
        self.connection = connection
        saveConnection()
        if changed {
            indexer.cancel()
            library.replace(with: .empty, drive: drive)
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
        if showsProgress { stage = .indexing }
        let existing = library.catalogue.isEmpty ? nil : library.catalogue
        let generation = connectionGeneration
        let metadataRevision = library.metadataMutationRevision
        indexer.start(drive: drive, rootPath: path, serverName: connection.name, existing: existing, forceMetadataReread: forceMetadataReread, onVerifiedListing: { [weak self] catalogue in
            guard let self, generation == self.connectionGeneration,
                  metadataRevision == self.library.metadataMutationRevision,
                  self.connection == connection, self.library.drive?.id == drive.id else { return }
            let presentIDs = Set(catalogue.albums.flatMap(\.tracks).map(\.id))
            self.onVerifiedServerListing?(catalogue.driveID, presentIDs)
            guard let existing, existing.driveID == catalogue.driveID, existing.rootPath == catalogue.rootPath else { return }
            let previousIDs = Set(existing.albums.flatMap(\.tracks).map(\.id))
            let removed = previousIDs.subtracting(presentIDs)
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

    /// Refreshes stale library data on activation while preserving the screen the user chose.
    /// Playback state is not a navigation request; only a tap or an explicit link opens the player.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .active else { return }
        refreshIfStale(olderThan: 30 * 60)
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

    public func rescan() {
        // Repeated pulls join the scan already in progress rather than restarting it.
        guard !isScanning else { return }
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
        let oldSession = session
        session = nil
        if let connection {
            services.deletePassword(connection.keychainAccount)
            services.deletePassword(connection.legacyKeychainAccount)
        }
        connection = nil
        saveConnection()
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
        guard profiles?.sessionID != nil, let connection, !isDemo, let password = storedPassword(for: connection) else { return nil }
        return WatchCredentials(baseURL: connection.baseURL, account: connection.account, password: password, driveID: library.catalogue.driveID)
    }

    /// Only an exact-address legacy entry can migrate automatically; hostname-only entries require sign-in.
    private func storedPassword(for connection: ServerConnection) -> String? {
        if supportsCredentialSync, credentialSyncEnabled(for: connection),
           let password = services.syncedPassword(connection) { return password }
        if let password = services.password(connection.keychainAccount) { return password }
        guard let legacy = services.password(connection.legacyKeychainAccount) else { return nil }
        services.savePassword(legacy, connection.keychainAccount)
        services.deletePassword(connection.legacyKeychainAccount)
        return legacy
    }

    // MARK: Session restore

    private func restoreSession() {
        guard let data = defaults.data(forKey: "connection"),
              let saved = try? JSONDecoder().decode(ServerConnection.self, from: data)
        else { return }
        connection = saved
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
            defer { if generation == connectionGeneration { isRestoring = false } }
            let connection = saved
            do {
                let session = try await services.login(connection.baseURL, saved.account, password, nil)
                guard isCurrent(generation) else { await services.logout(session); return }
                self.session = session
                if credentialSyncEnabled(for: connection) { services.savePassword(password, connection.keychainAccount) }
                let drive = SynologyDrive(session: session, displayName: connection.name)
                if library.isEmpty {
                    library.replace(with: .empty, drive: drive)
                    if connection.musicPath != nil {
                        startIndexing(showsProgress: true)
                    } else {
                        stage = .chooseFolder
                    }
                } else {
                    library.drive = drive
                    refreshIfStale(olderThan: 30 * 60)
                    startAutoRefresh()
                }
            } catch SynologyError.twoFactorRequired {
                guard isCurrent(generation) else { return }
                pendingReconnectPassword = password
                requestReauthentication(saved, needsOTP: true)
            } catch let error as SynologyError where error.requiresNewCredentials {
                guard isCurrent(generation) else { return }
                requestReauthentication(saved, needsOTP: false)
                signInError = error.localizedDescription
            } catch let error as NASTransportError {
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

    /// Waits for the server sign-in that starts at launch, so a song can stream, or gives up after the limit.
    public func waitForDrive(upTo limit: Duration) async {
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
        let access = familyRevocationPending ? nil : familyAccess
        return FamilyInfo(
            name: "\(connection.name) family", serverName: connection.name,
            serverAccount: connection.account, musicPath: connection.musicPath, updatedAt: .distantPast,
            familyAccount: access?.account, familyPassword: access?.password,
            address: connection.baseURL.absoluteString
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
                                            pendingRevocationScope: previous?.pendingRevocationScope)
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
            let probe = try await services.login(connection.baseURL, account, password, nil)
            await services.logout(probe)
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
                return hadNASAccess ? "iCloud sharing has stopped. Reconnect to the original NAS and revoke its family account in DSM; NAS access has not been confirmed as revoked." : nil
            }
            try checkFamilyContext(expected, sourceID: source)
            guard scope == cloud.sharingScopeIdentifier else { throw CancellationError() }
            if familyAccess != nil {
                if let error = await rotateFamilyAccess(verifyScope: { cloud.sharingScopeIdentifier == scope }) {
                    return "iCloud sharing has stopped, but NAS access has not been revoked. \(error) Retry here, or change the family account password in DSM. Existing NAS sessions may also need to be ended in DSM."
                }
                try checkFamilyContext(expected, sourceID: source)
                guard cloud.sharingScopeIdentifier == scope else { throw CancellationError() }
                familyAccessRecords[source]?.pendingRevocationScope = nil
                try persistFamilyRecords()
                onFamilyAccessChanged?()
            } else if hadNASAccess {
                return "iCloud sharing has stopped, but the saved NAS credentials could not be verified. Change or disable the family account in DSM, end its existing sessions, then verify family access here."
            }
            return nil
        } catch {
            return "Family sharing could not be fully stopped. \(error.localizedDescription) Retry after reconnecting."
        }
    }

    /// The family record arrived: a member's device connects with the family account on its own,
    /// and picks up a rotated password.
    public func familyArrived(_ info: FamilyInfo, isOwner: Bool = false) {
        // An owner chooses their personal synced sign-in through Use This Library. Don't let
        // arrival of the family's separate read-only credentials win that setup race.
        if isOwner && connection == nil && supportsCredentialSync { return }
        guard let account = info.familyAccount, let password = info.familyPassword else { return }
        if let connection {
            if connection.account == account, info.address.flatMap(URL.init(string:)).flatMap(NASOrigin.init(url:)) == NASOrigin(url: connection.baseURL),
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
            let session = try await services.login(url, account, password, nil)
            guard isCurrent(generation) else { await services.logout(session); return }
            let dsm = await services.info(session)
            guard isCurrent(generation) else { await services.logout(session); return }
            let name = dsm?.model.map { "Synology \($0)" } ?? info.serverName
            let connection = ServerConnection(name: name, baseURL: url, account: account, musicPath: info.musicPath)
            self.connection = connection
            saveConnection()
            services.savePassword(password, connection.keychainAccount)
            self.session = session
            discovery.stop()
            library.replace(with: .empty, drive: SynologyDrive(session: session, displayName: name))
            services.log("Connected to \(name) with the family account at \(url.host() ?? "its address")")
            if connection.musicPath != nil {
                startIndexing(showsProgress: true)
            } else {
                stage = .chooseFolder
            }
        } catch let error as SynologyError where error.requiresNewCredentials {
            guard isCurrent(generation) else { return }
            if let url = try? familyURL(info) {
                select(DiscoveredServer(name: info.serverName, baseURL: url, model: nil))
                joiningFamily = info
            }
            signInError = error.localizedDescription
        } catch let error as NASTransportError {
            guard isCurrent(generation) else { return }
            if let url = try? familyURL(info) {
                select(DiscoveredServer(name: info.serverName, baseURL: url, model: nil))
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
        if isOwner, let url = try? familyURL(info), NASOrigin(url: url) != nil,
           !info.serverAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let saved = ServerConnection(name: info.serverName, baseURL: url, account: info.serverAccount, musicPath: info.musicPath)
            let password = supportsCredentialSync ? services.syncedPassword(saved) : nil
            if password != nil || info.familyAccount == nil || info.familyPassword == nil {
                if stage == .welcome { stage = .discovering }
                select(DiscoveredServer(name: saved.name, baseURL: saved.baseURL, model: nil))
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
            select(DiscoveredServer(name: info.serverName, baseURL: try familyURL(info), model: nil))
            joiningFamily = info
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// The family's server as the owner reaches it.
    private func familyURL(_ info: FamilyInfo) throws -> URL {
        guard let address = info.address, let url = URL(string: address) else { throw SynologyError.invalidAddress }
        return url
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
