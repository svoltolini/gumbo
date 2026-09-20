#if os(iOS)
import GumboCore
import WatchConnectivity

/// Keeps a paired Apple Watch supplied with the playlists it may download and the sign-in it needs
/// to fetch them from the server itself. The catalogue travels as a file, the credentials as a
/// queued user-info payload; both are delivered even while the watch app is closed.
///
/// When a profile is locked or switched, `revoke()` queues a revocation message that tells the
/// Watch to clear its cached credentials, catalogue, and downloads. This message is delivered
/// even when the Watch is disconnected — WatchConnectivity queues `transferUserInfo` payloads
/// and delivers them when the Watch becomes reachable again.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    /// Asked for the current state whenever a sync is due.
    var provider: (() -> (catalogue: WatchCatalogue, credentials: WatchCredentials?, scope: String)?)?
    private var lastCatalogueKey: Data?
    private var lastCredentials: WatchCredentials?

    private static let authorizationKey = "watch.authorization"
    private var authorization: WatchAuthorization
    private var authorizationScope: String?

    override init() {
        let saved = WatchAuthorization.decode(UserDefaults.standard.data(forKey: Self.authorizationKey))
            ?? WatchAuthorization(revision: 0, isGranted: false)
        authorization = saved.successor(granted: false)
        UserDefaults.standard.set(authorization.encoded, forKey: Self.authorizationKey)
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Tells the Watch to discard any cached credentials and catalogue. Called when the active
    /// profile is locked or switched, so another profile's data never leaks. The revocation is
    /// queued via `transferUserInfo` so a disconnected Watch receives it on next sync.
    func revoke() {
        authorization = authorization.successor(granted: false)
        authorizationScope = nil
        persistAuthorization()
        lastCatalogueKey = nil
        lastCredentials = nil
        sendRevocation()
    }

    private func persistAuthorization() {
        UserDefaults.standard.set(authorization.encoded, forKey: Self.authorizationKey)
    }

    private func sendRevocation() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        _ = WCSession.default.transferUserInfo(["kind": "revoke", "authorization": authorization.encoded!])
    }

    private func authorize(scope: String) {
        guard !authorization.isGranted || authorizationScope != scope else { return }
        authorization = authorization.successor(granted: true)
        authorizationScope = scope
        persistAuthorization()
        lastCatalogueKey = nil
        lastCredentials = nil
    }

    /// Sends whatever changed since the last time; nothing when no watch is paired.
    func sync() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            DiagnosticsLog.shared.record("Watch sync skipped: state \(session.activationState.rawValue), paired \(session.isPaired), app installed \(session.isWatchAppInstalled)")
            return
        }
        guard let state = provider?() else {
            if authorization.isGranted { revoke() } else { sendRevocation() }
            return
        }
        authorize(scope: state.scope)
        let catalogue = state.catalogue
        if let key = catalogue.contentKey, key != lastCatalogueKey, let data = try? JSONEncoder().encode(catalogue) {
            let url = FileManager.default.temporaryDirectory.appending(path: "watch-catalogue-\(UUID().uuidString).json")
            if (try? data.write(to: url)) != nil {
                _ = session.transferFile(url, metadata: ["kind": "catalogue", "authorization": authorization.encoded!])
                lastCatalogueKey = key
                DiagnosticsLog.shared.record("Watch sync: sent \(catalogue.playlists.count) playlists (\(data.count) bytes)")
            }
        }
        if let credentials = state.credentials, credentials != lastCredentials {
            var payload: [String: Any] = [
                "kind": "credentials",
                "authorization": authorization.encoded!,
                "baseURL": credentials.baseURL.absoluteString,
                "account": credentials.account,
                "password": credentials.password,
            ]
            if let driveID = credentials.driveID { payload["driveID"] = driveID }
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
        guard message["kind"] as? String == "requestSync" else { reply([:]); return }
        Task { @MainActor in
            reply(self.syncReply())
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    private func syncReply() -> [String: Any] {
        guard let state = provider?() else {
            if authorization.isGranted { revoke() }
            return ["status": "revoked", "authorization": authorization.encoded!]
        }
        authorize(scope: state.scope)
        var reply: [String: Any] = ["status": "ok", "authorization": authorization.encoded!]
        if let data = try? JSONEncoder().encode(state.catalogue),
           let packed = try? (data as NSData).compressed(using: .lzfse) as Data, packed.count <= 60_000 {
            reply["catalogue"] = packed
            DiagnosticsLog.shared.record("Watch sync: answered with \(state.catalogue.playlists.count) playlists (\(packed.count) bytes packed)")
        } else {
            reply["status"] = "tooLarge"
            DiagnosticsLog.shared.record("Watch sync: catalogue too large for a message; queued as a file")
        }
        if let credentials = state.credentials {
            reply["baseURL"] = credentials.baseURL.absoluteString
            reply["account"] = credentials.account
            reply["password"] = credentials.password
            reply["driveID"] = credentials.driveID
        }
        return reply
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        let message = error.map { "Watch sync: catalogue transfer failed: \($0.localizedDescription)" } ?? "Watch sync: catalogue delivered"
        Task { @MainActor in DiagnosticsLog.shared.record(message) }
    }
}
#endif
