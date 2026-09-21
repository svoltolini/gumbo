import Foundation
import Observation
import GumboCore
import WatchConnectivity

/// What the phone has told the watch: the playlists it may download and the sign-in for the server.
/// The catalogue is kept on disk, the password in the Keychain, so both survive relaunches.
///
/// When the phone sends a revocation message (profile lock/switch), this store clears the saved
/// credentials and catalogue immediately. Revocation is queued by WatchConnectivity, so a
/// disconnected Watch receives it on next sync — stale credentials never persist across a profile change.
@Observable
@MainActor
final class WatchStore: NSObject, WCSessionDelegate {
    private(set) var catalogue: WatchCatalogue?
    private(set) var hasCredentials = false
    private(set) var isSample = false
    private var authorization = WatchAuthorization(revision: 0, isGranted: false)
    private static let authorizationKey = "watch.authorization"
    private static let catalogueRevisionKey = "watch.catalogueRevision"
    private static let credentialsRevisionKey = "watch.credentialsRevision"

    private static let catalogueURL = AppDirectories.support.appending(path: "Gumbo/watch-catalogue.json")
    private static let accountKey = "watch.account"
    private static let baseURLKey = "watch.baseURL"
    private static let driveIDKey = "watch.driveID"
    private static let providerDescriptorKey = "watch.providerConnection.v2"

    override init() {
        super.init()
        WatchDownloads.shared.credentialsProvider = { [weak self] in self?.credentials() }
        WatchDownloads.shared.relayRequest = { [weak self] request in self?.requestAudio(request) }
        WatchDownloads.shared.relayCancellation = { [weak self] request in self?.cancelAudio(request) }
        authorization = WatchAuthorization.decode(UserDefaults.standard.data(forKey: Self.authorizationKey)) ?? authorization
        WatchPlayer.shared.setAuthorization(authorization)
        guard authorization.isGranted else {
            clearAccess()
            activateConnectivity()
            return
        }
        if UserDefaults.standard.string(forKey: Self.catalogueRevisionKey) == String(authorization.revision),
           let data = try? Data(contentsOf: Self.catalogueURL), let saved = try? JSONDecoder().decode(WatchCatalogue.self, from: data) {
            catalogue = saved
            WatchPlayer.shared.setArtwork(saved.artwork)
            WatchDownloads.shared.reconcile(saved)
        }
        hasCredentials = credentials() != nil
        activateConnectivity()
    }

    private func activateConnectivity() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// A new authorization clears both halves of the previous grant before either is applied.
    @discardableResult
    private func accept(_ data: Data?) -> Bool {
        guard let incoming = WatchAuthorization.decode(data), authorization.accepts(incoming) else { return false }
        if incoming != authorization {
            authorization = incoming
            UserDefaults.standard.set(incoming.encoded, forKey: Self.authorizationKey)
            clearAccess()
            WatchPlayer.shared.setAuthorization(incoming)
        }
        return incoming.isGranted
    }

    private func clearAccess() {
        WatchPlayer.shared.stop()
        WatchPlayer.shared.setArtwork([:])
        let defaults = UserDefaults.standard
        if let account = defaults.string(forKey: Self.accountKey) {
            KeychainStore.delete(account: "watch|\(account)")
        }
        if let driveID = defaults.string(forKey: Self.driveIDKey) { KeychainStore.delete(account: "watch.v2|\(driveID)") }
        defaults.removeObject(forKey: Self.accountKey)
        defaults.removeObject(forKey: Self.baseURLKey)
        defaults.removeObject(forKey: Self.driveIDKey)
        defaults.removeObject(forKey: Self.providerDescriptorKey)
        defaults.removeObject(forKey: Self.credentialsRevisionKey)
        defaults.removeObject(forKey: Self.catalogueRevisionKey)
        hasCredentials = false

        try? FileManager.default.removeItem(at: Self.catalogueURL)
        let previousCatalogue = catalogue
        catalogue = nil
        isSample = false

        WatchDownloads.shared.clearAll()
        DiagnosticsLog.shared.record("Watch: cleared previous authorization")

        if let previous = previousCatalogue {
            WatchDownloads.shared.reconcile(WatchCatalogue(serverName: previous.serverName, profileName: nil, playlists: []))
        }
    }

    /// The server sign-in the phone handed over, or nil until it has.
    func credentials() -> WatchCredentials? {
        let defaults = UserDefaults.standard
        guard authorization.isGranted,
              defaults.string(forKey: Self.credentialsRevisionKey) == String(authorization.revision) else { return nil }
        if let data = defaults.data(forKey: Self.providerDescriptorKey) {
            guard var credentials = try? JSONDecoder().decode(WatchCredentials.self, from: data),
                  let driveID = credentials.driveID else { return nil }
            if credentials.providerKind != .smb {
                guard let password = KeychainStore.password(for: "watch.v2|\(driveID)") else { return nil }
                credentials.password = password
            }
            return credentials.isUsable ? credentials : nil
        }
        guard
              let account = defaults.string(forKey: Self.accountKey),
              let base = defaults.string(forKey: Self.baseURLKey), let url = URL(string: base),
              let password = KeychainStore.password(for: "watch|\(account)") else { return nil }
        return WatchCredentials(baseURL: url, account: account, password: password, driveID: defaults.string(forKey: Self.driveIDKey))
    }

    /// Asks the phone for everything, when it is within reach. The phone answers the message
    /// directly with the catalogue and the sign-in; queued transfers cover the times it cannot.
    func requestSync() {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        // These run on WatchConnectivity's own queue, so they must not be tied to the main actor.
        WCSession.default.sendMessage(["kind": "requestSync"], replyHandler: { @Sendable reply in
            let authorizationData = reply["authorization"] as? Data
            let packed = reply["catalogue"] as? Data
            let status = reply["status"] as? String ?? "?"
            let base = reply["baseURL"] as? String
            let account = reply["account"] as? String
            let password = reply["password"] as? String
            let driveID = reply["driveID"] as? String
            let providerData = reply["providerConnectionV2"] as? Data
            Task { @MainActor in
                guard self.accept(authorizationData) else { return }
                DiagnosticsLog.shared.record("Watch: sync answered, status \(status), \(packed?.count ?? 0) bytes")
                if let packed, let data = try? (packed as NSData).decompressed(using: .lzfse) as Data {
                    self.apply(catalogueData: data)
                }
                if let providerData {
                    if let credentials = try? JSONDecoder().decode(WatchCredentials.self, from: providerData) { self.apply(credentials: credentials) }
                } else if let base, let url = URL(string: base), let account, let password {
                    self.apply(credentials: WatchCredentials(baseURL: url, account: account, password: password, driveID: driveID))
                }
            }
        }, errorHandler: { @Sendable error in
            let message = error.localizedDescription
            Task { @MainActor in DiagnosticsLog.shared.record("Watch: sync request failed: \(message)") }
        })
    }

    /// The demo playlists, for looking at the watch app without a phone or a server.
    func loadSample() {
        let playlists = SampleLibrary.playlists.map { playlist in
            WatchPlaylist(
                id: playlist.id, name: playlist.name, isSmart: playlist.kind == .smart,
                coverColours: playlist.covers.prefix(4).map { WatchColourPair(a: $0.colorA, b: $0.colorB) },
                tracks: playlist.tracks.prefix(WatchCatalogue.songLimit).map { track in
                    let album = SampleLibrary.catalogue.albums.first { $0.id == track.albumID }
                    return WatchTrack(
                        id: track.id, title: track.title, artist: track.artist ?? album?.artist ?? "",
                        album: album?.title ?? "", duration: track.duration,
                        path: track.path ?? "/music/\(track.id).flac", fileSize: track.fileSize ?? 28_000_000,
                        format: track.format, isLossless: track.isLossless, albumID: track.albumID
                    )
                },
                totalSongs: playlist.tracks.count
            )
        }
        catalogue = WatchCatalogue(serverName: SampleLibrary.serverName, profileName: "Me", playlists: playlists)
        isSample = true
        WatchPlayer.shared.setArtwork([:])
        if let catalogue { WatchDownloads.shared.reconcile(catalogue) }
    }

    private func apply(catalogueData data: Data) {
        guard var received = try? JSONDecoder().decode(WatchCatalogue.self, from: data) else {
            DiagnosticsLog.shared.record("Watch: catalogue could not be read (\(data.count) bytes)")
            return
        }
        // WatchConnectivity can deliver files out of order within the same authorization.
        // An older initial snapshot must not erase thumbnails delivered by the follow-up, or
        // undo a deletion/re-import. accept() clears catalogue when authorization changes.
        if let catalogue, !received.isAtLeastAsRecent(as: catalogue) { return }
        received.applyServerDeletions(received.serverDeletedTrackIDs)
        WatchPlayer.shared.stopIfServerFilesWereDeleted(received.deletedCacheKeys)
        DiagnosticsLog.shared.record("Watch: received \(received.playlists.count) playlists")
        catalogue = received
        WatchPlayer.shared.setArtwork(received.artwork)
        isSample = false
        WatchDownloads.shared.reconcile(received)
        try? FileManager.default.createDirectory(at: Self.catalogueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Persist normalized colours and their policy marker after receiving an older catalogue.
        if let normalized = try? JSONEncoder().encode(received) {
            if (try? normalized.write(to: Self.catalogueURL, options: .atomic)) != nil {
                UserDefaults.standard.set(String(authorization.revision), forKey: Self.catalogueRevisionKey)
            }
        }
    }

    private func apply(credentials: WatchCredentials) {
        guard credentials.isUsable else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.credentialsRevisionKey)
        hasCredentials = false
        if let previous = defaults.string(forKey: Self.accountKey), previous != credentials.account {
            KeychainStore.delete(account: "watch|\(previous)")
        }
        defaults.set(credentials.account, forKey: Self.accountKey)
        defaults.set(credentials.baseURL.absoluteString, forKey: Self.baseURLKey)
        defaults.set(credentials.driveID, forKey: Self.driveIDKey)
        if credentials.provider != nil, let driveID = credentials.driveID {
            if credentials.providerKind != .smb {
                KeychainStore.save(password: credentials.password, for: "watch.v2|\(driveID)")
                guard KeychainStore.password(for: "watch.v2|\(driveID)") == credentials.password else { return }
            }
            var descriptor = credentials
            descriptor.password = ""
            defaults.set(try? JSONEncoder().encode(descriptor), forKey: Self.providerDescriptorKey)
        } else {
            defaults.removeObject(forKey: Self.providerDescriptorKey)
            KeychainStore.save(password: credentials.password, for: "watch|\(credentials.account)")
            guard KeychainStore.password(for: "watch|\(credentials.account)") == credentials.password else { return }
        }
        defaults.set(String(authorization.revision), forKey: Self.credentialsRevisionKey)
        hasCredentials = true
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.requestSync() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file lives only for the length of this call: read it here, decode on the main actor.
        let authorizationData = file.metadata?["authorization"] as? Data
        let kind = file.metadata?["kind"] as? String ?? "?"
        if kind == "audioV2", let request = WatchAudioRelayRequest.decode(file.metadata?["request"] as? Data) {
            // WCSession's incoming URL expires after this delegate returns. Move only to a fresh
            // staging path here; authorization and ownership are checked before accepting it.
            let staged = FileManager.default.temporaryDirectory.appending(path: "watch-audio-\(UUID().uuidString)")
            guard (try? FileManager.default.copyItem(at: file.fileURL, to: staged)) != nil else { return }
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: staged) }
                guard WatchAuthorization.decode(authorizationData) == self.authorization, self.authorization.isGranted else { return }
                WatchDownloads.shared.receiveRelay(request, file: staged)
            }
            return
        }
        let data = try? Data(contentsOf: file.fileURL)
        Task { @MainActor in
            DiagnosticsLog.shared.record("Watch: file arrived, kind \(kind), \(data?.count ?? -1) bytes")
            guard kind == "catalogue", let data, self.accept(authorizationData) else { return }
            self.apply(catalogueData: data)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            self.requestSync()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let authorizationData = userInfo["authorization"] as? Data
        let kind = userInfo["kind"] as? String
        if kind == "revoke" {
            Task { @MainActor in _ = self.accept(authorizationData) }
            return
        }
        if kind == "audioFailureV2", let request = WatchAudioRelayRequest.decode(userInfo["request"] as? Data) {
            Task { @MainActor in
                guard WatchAuthorization.decode(authorizationData) == self.authorization, self.authorization.isGranted else { return }
                WatchDownloads.shared.failRelay(request)
            }
            return
        }
        if kind == "providerConnectionV2", let data = userInfo["providerConnectionV2"] as? Data,
           let credentials = try? JSONDecoder().decode(WatchCredentials.self, from: data) {
            Task { @MainActor in
                guard self.accept(authorizationData) else { return }
                self.apply(credentials: credentials)
            }
            return
        }
        guard kind == "credentials",
              let base = userInfo["baseURL"] as? String, let url = URL(string: base),
              let account = userInfo["account"] as? String, let password = userInfo["password"] as? String else { return }
        let credentials = WatchCredentials(baseURL: url, account: account, password: password, driveID: userInfo["driveID"] as? String)
        Task { @MainActor in
            guard self.accept(authorizationData) else { return }
            self.apply(credentials: credentials)
        }
    }

    private func requestAudio(_ request: WatchAudioRelayRequest) {
        guard authorization.isGranted, WCSession.default.activationState == .activated else {
            WatchDownloads.shared.failRelay(request); return
        }
        let grant = authorization
        let payload: [String: Any] = ["kind": "requestAudioV2", "request": request.encoded!, "authorization": grant.encoded!]
        guard WCSession.default.isReachable else { WatchDownloads.shared.failRelay(request); return }
        WCSession.default.sendMessage(payload, replyHandler: { @Sendable response in
            let accepted = response["accepted"] as? Bool == true
            Task { @MainActor in
                guard grant == self.authorization else { return }
                if !accepted { WatchDownloads.shared.failRelay(request) }
            }
        }, errorHandler: { @Sendable _ in
            Task { @MainActor in if grant == self.authorization { WatchDownloads.shared.failRelay(request) } }
        })
    }

    private func cancelAudio(_ request: WatchAudioRelayRequest) {
        guard authorization.isGranted, WCSession.default.activationState == .activated else { return }
        let payload: [String: Any] = ["kind": "cancelAudioV2", "request": request.encoded!, "authorization": authorization.encoded!]
        // Queued cancellation remains effective even if the devices lose reachability.
        _ = WCSession.default.transferUserInfo(payload)
        if WCSession.default.isReachable { WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil) }
    }
}
