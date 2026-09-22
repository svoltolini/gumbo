#if os(iOS)
import GumboCore
import WatchConnectivity
import UIKit

/// Keeps a paired Apple Watch supplied with the playlists it may download and the sign-in it needs
/// to fetch them from the server itself. The catalogue travels as a file, the credentials as a
/// queued user-info payload; both are delivered even while the watch app is closed.
///
/// When a profile is locked or switched, `revoke()` queues a revocation message that tells the
/// Watch to clear its cached credentials, catalogue, and downloads. This message is delivered
/// even when the Watch is disconnected — WatchConnectivity queues `transferUserInfo` payloads
/// and delivers them when the Watch becomes reachable again.
///
/// The grant is saved with the library it covers, so relaunching this app, even in the
/// background with no profile open yet, keeps its revision and the Watch keeps its downloads.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    /// The library a grant covers (open profile, source and folder), or nil while no profile is
    /// open on a ready library. Cheap, so the grant follows the app even with no Watch in reach.
    var scopeProvider: (() -> String?)?
    /// The open profile, whether or not its library is ready: another profile opening after a
    /// relaunch revokes the grant before its library loads.
    var profileProvider: (() -> String?)?
    /// The profiles on this iPhone, nil while their list cannot be read: the granted profile
    /// deleted or retired from the family revokes the grant even while no profile is open.
    var knownProfileIDsProvider: (() -> Set<String>?)?
    /// Asked for the current state whenever a sync is due. Its scope matches `scopeProvider`.
    var provider: (() -> (catalogue: WatchCatalogue, credentials: WatchCredentials?, scope: String)?)?
    var artworkProvider: ((WatchCatalogue) -> [WatchArtworkSource])?
    /// Produces a dedicated temporary copy, never a path into the phone's offline cache.
    var audioFileProvider: ((WatchPlaylist, WatchTrack) async throws -> URL)?
    private var relayQueue: [(request: WatchAudioRelayRequest, authorization: WatchAuthorization)] = []
    private var relayTask: Task<Void, Never>?
    private var activeRelay: WatchAudioRelayRequest?
    private var relayEpoch = UUID()
    private var backgroundObserver: NSObjectProtocol?
    private let artworkBuilder = WatchArtworkBuilder()
    private var artworkTask: Task<Void, Never>?
    private var artworkRequest: [WatchArtworkSource]?
    private var preparedArtworkSources: [WatchArtworkSource] = []
    private var preparedArtwork: [String: Data] = [:]
    private var artworkRequestID = UUID()
    /// Thumbnails live only in memory, while the Watch keeps the covers it was sent before this
    /// launch. Until the first batch is ready, a catalogue under the kept grant waits rather than
    /// remove them; after a new grant the Watch has cleared its covers, so nothing waits.
    private var awaitsCoversSinceLaunch = true
    private var holdsCatalogueForCovers: Bool { awaitsCoversSinceLaunch && artworkTask != nil }
    private var lastCatalogueKey: Data?
    private var lastCredentials: WatchCredentials?
    private static let deletionKey = "watch.serverDeletions.v1"
    private var serverDeletions: [String: [String]] = [:]
    private var deletionRevision: UInt64 = 0

    private static let grantKey = "watch.grant.v1"
    /// Earlier versions saved the authorization alone, here.
    private static let legacyAuthorizationKey = "watch.authorization"
    private var currentGrant: WatchGrant
    private var authorization: WatchAuthorization { currentGrant.authorization }
    private var authorizationScope: String? { currentGrant.scope }

    override init() {
        currentGrant = WatchGrant.restored(from: UserDefaults.standard.data(forKey: Self.grantKey),
                                           legacyAuthorization: UserDefaults.standard.data(forKey: Self.legacyAuthorizationKey))
        serverDeletions = UserDefaults.standard.dictionary(forKey: Self.deletionKey) as? [String: [String]] ?? [:]
        deletionRevision = UInt64(UserDefaults.standard.string(forKey: Self.deletionKey + ".revision") ?? "0") ?? 0
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendRelayPreparation() }
            }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func serverTracksDeleted(sourceID: String, trackIDs: Set<String>) {
        guard !sourceID.isEmpty, !trackIDs.isEmpty else { return }
        serverDeletions[sourceID] = Set(serverDeletions[sourceID] ?? []).union(trackIDs).sorted()
        persistServerDeletions()
        lastCatalogueKey = nil
        sync()
    }

    /// Re-imported files become available again only after a complete successful NAS listing.
    func reconcileServerDeletions(sourceID: String, presentTrackIDs: Set<String>) {
        guard let previous = serverDeletions[sourceID] else { return }
        let remaining = Set(previous).subtracting(presentTrackIDs).sorted()
        guard remaining != previous else { return }
        serverDeletions[sourceID] = remaining.isEmpty ? nil : remaining
        persistServerDeletions()
        lastCatalogueKey = nil
        sync()
    }

    private func persistServerDeletions() {
        deletionRevision += 1
        UserDefaults.standard.set(serverDeletions, forKey: Self.deletionKey)
        UserDefaults.standard.set(String(deletionRevision), forKey: Self.deletionKey + ".revision")
    }

    private func catalogueWithDeletions(_ original: WatchCatalogue, sourceID: String?, scope: String) -> WatchCatalogue {
        var catalogue = original
        let sourceIDs = Set(catalogue.playlists.compactMap(\.driveID)).union([sourceID, catalogue.serverSourceID].compactMap { $0 })
        catalogue.applyServerDeletions(serverDeletions.filter { sourceIDs.contains($0.key) })
        catalogue.serverDeletionRevision = deletionRevision
        let sources = artworkProvider?(catalogue) ?? []
        prepareArtwork(sources, scope: scope)
        let ready = Set(preparedArtworkSources).intersection(sources)
        catalogue.artwork = WatchArtwork.bounded(preparedArtwork, albumIDs: Set(ready.map(\.albumID)))
        catalogue.snapshotRevision = currentGrant.nextSnapshotRevision()
        persistGrant()
        return catalogue
    }

    private func prepareArtwork(_ sources: [WatchArtworkSource], scope: String) {
        guard artworkRequest != sources else { return }
        artworkTask?.cancel()
        artworkRequest = sources
        let requestID = UUID()
        artworkRequestID = requestID
        artworkTask = Task { [weak self, artworkBuilder] in
            let images = await artworkBuilder.thumbnails(for: sources, scope: scope)
            guard !Task.isCancelled, let self, self.artworkRequestID == requestID else { return }
            guard self.authorizationScope == scope, self.scopeProvider?() == scope else {
                // The library moved while these were drawn and nothing has replaced this batch yet:
                // the next sync prepares again rather than hold catalogues for a finished task.
                self.artworkTask = nil
                self.artworkRequest = nil
                return
            }
            self.preparedArtworkSources = sources
            self.preparedArtwork = images
            self.artworkTask = nil
            self.awaitsCoversSinceLaunch = false
            self.sync()
        }
    }

    private func clearArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = UUID()
        artworkRequest = nil
        preparedArtworkSources = []
        preparedArtwork = [:]
    }

    /// Tells the Watch to discard any cached credentials and catalogue. Called when the active
    /// profile is locked or switched, so another profile's data never leaks. The revocation is
    /// queued via `transferUserInfo` so a disconnected Watch receives it on next sync.
    func revoke() {
        currentGrant.revoke()
        grantChanged()
        sendRevocation()
    }

    private func persistGrant() {
        UserDefaults.standard.set(currentGrant.encoded, forKey: Self.grantKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyAuthorizationKey)
    }

    private func sendRevocation() {
        // Revision zero: nothing was ever granted from this install, and the Watch ignores it.
        guard authorization.revision > 0, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        _ = WCSession.default.transferUserInfo(["kind": "revoke", "authorization": authorization.encoded!])
    }

    /// Moves the grant with the library now open: kept for the same one, granted anew for any
    /// other, revoked when a library open in this process closes, another profile opens or the
    /// granted profile leaves the iPhone. A grant restored at launch is left alone until then, so
    /// a relaunch never makes the Watch clear its downloads.
    private func followLibrary() {
        guard currentGrant.update(scope: scopeProvider?(), profileID: profileProvider?(),
                                  knownProfileIDs: knownProfileIDsProvider?()) != .unchanged else { return }
        grantChanged()
    }

    /// Nothing prepared or sent under the previous revision may continue under the new one.
    private func grantChanged() {
        cancelAllRelay()
        clearArtwork()
        awaitsCoversSinceLaunch = false
        persistGrant()
        lastCatalogueKey = nil
        lastCredentials = nil
    }

    /// Sends whatever changed since the last time; nothing when no watch is paired.
    func sync() {
        guard WCSession.isSupported() else { return }
        followLibrary()
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            DiagnosticsLog.shared.record("Watch sync skipped: state \(session.activationState.rawValue), paired \(session.isPaired), app installed \(session.isWatchAppInstalled)")
            return
        }
        guard authorization.isGranted else { sendRevocation(); return }
        // A grant restored at launch waits for its library; the Watch keeps what it already has.
        guard let state = provider?(), state.scope == authorizationScope else { return }
        let catalogue = catalogueWithDeletions(state.catalogue, sourceID: state.credentials?.driveID, scope: state.scope)
        if !holdsCatalogueForCovers, let key = catalogue.contentKey, key != lastCatalogueKey, let data = try? JSONEncoder().encode(catalogue) {
            let url = FileManager.default.temporaryDirectory.appending(path: "watch-catalogue-\(UUID().uuidString).json")
            if (try? data.write(to: url)) != nil {
                _ = session.transferFile(url, metadata: ["kind": "catalogue", "authorization": authorization.encoded!])
                lastCatalogueKey = key
                DiagnosticsLog.shared.record("Watch sync: sent \(catalogue.playlists.count) playlists (\(data.count) bytes)")
            }
        }
        if let credentials = state.credentials, credentials != lastCredentials {
            var payload = credentialPayload(credentials)
            payload["kind"] = credentials.provider == nil ? "credentials" : "providerConnectionV2"
            payload["authorization"] = authorization.encoded!
            _ = session.transferUserInfo(payload)
            lastCredentials = credentials
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A new watch was paired; pick it up.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["kind"] as? String == "requestAudioV2" || message["kind"] as? String == "cancelAudioV2" {
            let data = message["request"] as? Data
            let grant = message["authorization"] as? Data
            let cancel = message["kind"] as? String == "cancelAudioV2"
            Task { @MainActor in self.receiveRelay(data, authorizationData: grant, cancel: cancel) }
            return
        }
        guard message["kind"] as? String == "requestSync" else { return }
        Task { @MainActor in
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    /// The watch app is open and asking: answer straight away with the catalogue and the sign-in.
    /// Live messages reach the watch everywhere, including the simulator, where queued transfers
    /// never arrive. Larger catalogues than a message can carry fall back to the queued file.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        if message["kind"] as? String == "requestAudioV2" {
            let data = message["request"] as? Data
            let grant = message["authorization"] as? Data
            Task { @MainActor in reply(["accepted": self.receiveRelay(data, authorizationData: grant, cancel: false)]) }
            return
        }
        guard message["kind"] as? String == "requestSync" else { reply([:]); return }
        Task { @MainActor in
            reply(self.syncReply())
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    private func syncReply() -> [String: Any] {
        followLibrary()
        guard authorization.isGranted else { return ["status": "revoked", "authorization": authorization.encoded!] }
        guard let state = provider?(), state.scope == authorizationScope else {
            // Relaunched before the granted library is open: the same revision tells the Watch to
            // keep everything; the catalogue follows once the library opens.
            return ["status": "waiting", "authorization": authorization.encoded!]
        }
        var reply: [String: Any] = ["status": "ok", "authorization": authorization.encoded!]
        let catalogue = catalogueWithDeletions(state.catalogue, sourceID: state.credentials?.driveID, scope: state.scope)
        if holdsCatalogueForCovers {
            // The Watch keeps its saved catalogue and covers; the queued file follows with thumbnails.
            reply["status"] = "waiting"
            DiagnosticsLog.shared.record("Watch sync: catalogue waits for covers after relaunch")
        } else if let data = try? JSONEncoder().encode(catalogue),
                  let packed = try? (data as NSData).compressed(using: .lzfse) as Data, packed.count <= 60_000 {
            reply["catalogue"] = packed
            DiagnosticsLog.shared.record("Watch sync: answered with \(state.catalogue.playlists.count) playlists (\(packed.count) bytes packed)")
        } else {
            reply["status"] = "tooLarge"
            DiagnosticsLog.shared.record("Watch sync: catalogue too large for a message; queued as a file")
        }
        if let credentials = state.credentials {
            reply.merge(credentialPayload(credentials), uniquingKeysWith: { _, new in new })
        }
        return reply
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if fileTransfer.file.metadata?["kind"] as? String == "audioV2" {
            if error != nil, let request = WatchAudioRelayRequest.decode(fileTransfer.file.metadata?["request"] as? Data) {
                let grant = WatchAuthorization.decode(fileTransfer.file.metadata?["authorization"] as? Data)
                Task { @MainActor in
                    guard grant == self.authorization, self.authorization.isGranted else { return }
                    _ = WCSession.default.transferUserInfo(["kind": "audioFailureV2", "request": request.encoded!,
                        "authorization": self.authorization.encoded!])
                }
            }
            return
        }
        let message = error.map { "Watch sync: catalogue transfer failed: \($0.localizedDescription)" } ?? "Watch sync: catalogue delivered"
        Task { @MainActor in DiagnosticsLog.shared.record(message) }
    }

    private func credentialPayload(_ credentials: WatchCredentials) -> [String: Any] {
        guard credentials.isUsable else { return [:] }
        if credentials.provider != nil {
            // Old Watch versions see no DSM keys and cannot send these credentials to File Station.
            return (try? JSONEncoder().encode(credentials)).map { ["providerConnectionV2": $0] } ?? [:]
        }
        return ["baseURL": credentials.baseURL.absoluteString, "account": credentials.account,
                "password": credentials.password, "driveID": credentials.driveID ?? ""]
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let kind = userInfo["kind"] as? String
        guard kind == "requestAudioV2" || kind == "cancelAudioV2" else { return }
        let data = userInfo["request"] as? Data
        let grant = userInfo["authorization"] as? Data
        Task { @MainActor in self.receiveRelay(data, authorizationData: grant, cancel: kind == "cancelAudioV2") }
    }

    @discardableResult private func receiveRelay(_ data: Data?, authorizationData: Data?, cancel: Bool) -> Bool {
        guard let request = WatchAudioRelayRequest.decode(data),
              WatchAuthorization.decode(authorizationData) == authorization, authorization.isGranted else { return false }
        if cancel {
            relayQueue.removeAll { $0.request == request }
            if activeRelay == request { relayTask?.cancel() }
            for transfer in WCSession.default.outstandingFileTransfers
            where WatchAudioRelayRequest.decode(transfer.file.metadata?["request"] as? Data) == request {
                transfer.cancel()
                try? FileManager.default.removeItem(at: transfer.file.fileURL)
            }
            return true
        }
        guard UIApplication.shared.applicationState == .active,
              let state = provider?(), state.scope == authorizationScope,
              state.credentials?.providerKind == .smb, request.resolve(in: state.catalogue) != nil,
              let resolved = request.resolve(in: state.catalogue),
              !Set(serverDeletions[resolved.playlist.driveID ?? ""] ?? []).contains(resolved.track.id) else { return false }
        if activeRelay == request || relayQueue.contains(where: { $0.request == request }) ||
            WCSession.default.outstandingFileTransfers.contains(where: { WatchAudioRelayRequest.decode($0.file.metadata?["request"] as? Data) == request }) { return true }
        guard relayQueue.count < WatchCatalogue.songLimit * 2 else { return false }
        relayQueue.append((request, authorization))
        startRelayIfNeeded()
        return true
    }

    private func startRelayIfNeeded() {
        guard relayTask == nil, !relayQueue.isEmpty else { return }
        let epoch = relayEpoch
        relayTask = Task { [weak self] in
            guard let self else { return }
            while !relayQueue.isEmpty, epoch == relayEpoch {
                let entry = relayQueue.removeFirst()
                let request = entry.request
                activeRelay = request
                do {
                    guard !Task.isCancelled, entry.authorization == authorization,
                          let state = provider?(), state.scope == authorizationScope,
                          state.credentials?.providerKind == .smb,
                          let resolved = request.resolve(in: state.catalogue), let audioFileProvider else { throw CancellationError() }
                    let file = try await audioFileProvider(resolved.playlist, resolved.track)
                    var transferred = false
                    defer { if !transferred { try? FileManager.default.removeItem(at: file) } }
                    try Task.checkCancellation()
                    guard epoch == relayEpoch, entry.authorization == authorization,
                          let current = provider?(), current.scope == state.scope,
                          let latest = request.resolve(in: current.catalogue), latest.track == resolved.track,
                          !Set(serverDeletions[latest.playlist.driveID ?? ""] ?? []).contains(latest.track.id),
                          WatchDownloadValidation.failure(for: file, expectedBytes: request.job.expectedBytes) == nil else { throw CancellationError() }
                    _ = WCSession.default.transferFile(file, metadata: ["kind": "audioV2", "request": request.encoded!, "authorization": authorization.encoded!])
                    transferred = true
                } catch {
                    if entry.authorization == authorization, epoch == relayEpoch {
                        _ = WCSession.default.transferUserInfo(["kind": "audioFailureV2", "request": request.encoded!,
                            "authorization": authorization.encoded!, "message": "Keep Gumbo open on your iPhone and try downloading again."])
                    }
                }
                activeRelay = nil
                if Task.isCancelled { break }
            }
            guard epoch == relayEpoch else { return }
            relayTask = nil
            startRelayIfNeeded()
        }
    }

    private func cancelAllRelay() {
        relayEpoch = UUID()
        relayTask?.cancel()
        relayTask = nil
        activeRelay = nil
        relayQueue.removeAll()
        guard WCSession.isSupported() else { return }
        for transfer in WCSession.default.outstandingFileTransfers where transfer.file.metadata?["kind"] as? String == "audioV2" {
            transfer.cancel()
            try? FileManager.default.removeItem(at: transfer.file.fileURL)
        }
    }

    private func suspendRelayPreparation() {
        let interrupted = relayQueue + (activeRelay.map { [($0, authorization)] } ?? [])
        relayQueue.removeAll()
        relayTask?.cancel()
        for (request, grant) in interrupted where grant == authorization {
            _ = WCSession.default.transferUserInfo(["kind": "audioFailureV2", "request": request.encoded!,
                "authorization": authorization.encoded!, "message": "Keep Gumbo open on your iPhone and try downloading again."])
        }
        // Already prepared WCSession file transfers remain queued and can finish in the background.
    }
}
#endif
