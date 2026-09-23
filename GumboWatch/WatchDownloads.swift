import Foundation
import Observation
import GumboCore

/// Background downloads scoped to the NAS, profile and playlist that requested them.
@Observable
@MainActor
final class WatchDownloads: NSObject, URLSessionDownloadDelegate {
    typealias State = WatchDownloadStatus

    static let shared = WatchDownloads()
    nonisolated static let sessionIdentifier = "com.samuelvoltolini.gumbo.watch.downloads"
    private var manifests: [String: WatchDownloadManifest] = [:]
    private var expected: [String: Set<String>] = [:]
    private var errors: [String: String] = [:]
    private var currentCatalogue: WatchCatalogue?
    /// Every refresh task the system handed over for the download session, all completed together.
    @ObservationIgnored private var backgroundCompletions: [() -> Void] = []
    /// The session is created at launch, so its events can finish before the refresh task arrives.
    @ObservationIgnored private var backgroundEventsFinished = false
    var credentialsProvider: (() -> WatchCredentials?)?
    var relayRequest: ((WatchAudioRelayRequest) -> Void)?
    var relayCancellation: ((WatchAudioRelayRequest) -> Void)?
    private var relayJobs: [String: [WatchAudioRelayRequest]] = [:]
    /// Views ask for state on every draw; reopening each saved song there made scrolling hitch.
    @ObservationIgnored private var validation = WatchFileValidationCache()

    private nonisolated static let root = AppDirectories.support.appending(path: "Gumbo/watch-playlists", directoryHint: .isDirectory)
    // The old manifest had no source identity. Keep its files untouched, but require a fresh download.
    private nonisolated static let manifestURL = root.appending(path: "manifests-v2.json")

    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.manifestURL), let saved = try? JSONDecoder().decode([String: WatchDownloadManifest].self, from: data) {
            manifests = saved
        }
        restoreTasks()
    }

    /// A partly saved playlist still plays its saved songs; only the rest need downloading.
    func state(of playlist: WatchPlaylist) -> State {
        guard let key = playlist.cacheID, let manifest = manifests[key] else { return .none }
        let validated = manifest.validatedFileIDs(for: playlist, root: Self.root) { self.validation.isValid($0, expectedBytes: $1) }
        return .resolve(trackIDs: Set(playlist.tracks.map(\.id)), manifest: manifest, validated: validated,
                        pending: expected[key], error: errors[key])
    }

    func isDownloaded(_ playlist: WatchPlaylist) -> Bool { state(of: playlist) == .downloaded }

    func hasSavedFiles(for playlist: WatchPlaylist) -> Bool {
        guard let key = playlist.cacheID else { return false }
        return manifests[key]?.hasStoredFiles == true
    }

    /// Only verified files from this source and profile are handed to the player, in playlist order.
    func files(for playlist: WatchPlaylist) -> [(track: WatchTrack, url: URL)] {
        guard let key = playlist.cacheID, let manifest = manifests[key] else { return [] }
        return manifest.availableFiles(for: playlist, root: Self.root) { self.validation.isValid($0, expectedBytes: $1) }
    }

    func allowsPlayback(_ files: [(track: WatchTrack, url: URL)]) -> Bool {
        guard let currentCatalogue else { return false }
        let allowed = Set(currentCatalogue.playlists.flatMap { self.files(for: $0).map(\.url) })
        return !files.isEmpty && files.allSatisfy { allowed.contains($0.url) }
    }

    var bytesOnWatch: Int64 {
        guard let items = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func download(_ snapshot: WatchPlaylist, credentials: WatchCredentials) async {
        guard let playlist = currentCatalogue?.playlist(matching: snapshot) else {
            if let key = snapshot.cacheID { errors[key] = "This playlist is no longer available. Open the current playlist on your iPhone and sync again." }
            return
        }
        guard let key = playlist.cacheID else { return }
        guard credentials.matches(playlist) else {
            errors[key] = "Open Gumbo on your iPhone to sync the sign-in for this playlist’s NAS."
            return
        }
        guard expected[key]?.isEmpty != false else { return }
        let have = Set(files(for: playlist).map { $0.track.id })
        let missing = playlist.uniqueTracks.filter { !have.contains($0.id) }
        guard !missing.isEmpty else { return }
        let generation = UUID()
        var manifest = manifests[key] ?? WatchDownloadManifest()
        manifest.desired = Set(playlist.tracks.map(\.id))
        // Keep saved-file ownership while retrying, including entries no longer in a smart playlist.
        // They cannot be played through current membership, and Remove can still reclaim them.
        manifest.generation = generation
        manifests[key] = manifest
        expected[key] = Set(missing.map(\.id))
        errors[key] = nil
        saveManifests()
        do {
            try await startTransfers(missing, in: playlist, key: key, generation: generation, credentials: credentials)
        } catch {
            guard manifests[key]?.generation == generation else { return }
            errors[key] = error.localizedDescription
            expected[key] = nil
            manifests[key]?.generation = nil
            saveManifests()
        }
    }

    /// Starts transfers for songs already listed as expected under this generation. A song that
    /// left the playlist or changed while signing in is skipped; the edit stopped counting it.
    private func startTransfers(_ tracks: [WatchTrack], in playlist: WatchPlaylist, key: String, generation: UUID,
                                credentials: WatchCredentials) async throws {
        if credentials.providerKind == .smb {
            guard let relayRequest else { throw ProviderError.unavailableOnDevice }
            for track in tracks {
                guard let job = WatchDownloadJob(playlist: playlist, track: track, generation: generation) else { continue }
                let request = WatchAudioRelayRequest(playlist: playlist, job: job)
                relayJobs[key, default: []].append(request)
                relayRequest(request)
            }
            return
        }
        let synology: SynologyDrive?
        let webDAV: WebDAVDrive?
        switch credentials.providerKind {
        case .synology:
            let dsm = try await SynologyClient.login(baseURL: credentials.baseURL, account: credentials.account, password: credentials.password, otpCode: nil)
            synology = SynologyDrive(session: dsm, displayName: "NAS")
            webDAV = nil
        case .webDAV:
            synology = nil
            webDAV = try WebDAVDrive(baseURL: credentials.baseURL, username: credentials.account,
                                    password: credentials.password, sourceID: credentials.driveID!)
        default: throw ProviderError.unsupportedVersion
        }
        guard manifests[key]?.generation == generation else { return }
        for track in tracks {
            guard let job = WatchDownloadJob(playlist: playlist, track: track, generation: generation),
                  expected[key]?.contains(track.id) == true else { continue }
            guard currentCatalogue?.isCurrent(job) == true else {
                expected[key]?.remove(track.id)
                if expected[key]?.isEmpty == true { expected[key] = nil }
                continue
            }
            let request: URLRequest
            if let webDAV {
                var authenticated = try webDAV.authenticatedRequest(for: track.path)
                // Background redirects are controlled by the OS. Supply the password only
                // for an exact-origin challenge instead of a replayable Authorization header.
                authenticated.setValue(nil, forHTTPHeaderField: "Authorization")
                request = authenticated
            } else if let url = synology?.streamURL(for: track.path) {
                request = URLRequest(url: url)
            } else {
                fail(job: job, message: "The server could not provide “\(track.title)”. Try again after reconnecting.")
                continue
            }
            let task = session.downloadTask(with: request)
            task.taskDescription = job.encoded
            task.resume()
        }
    }

    func cancel(_ playlist: WatchPlaylist) {
        guard let key = playlist.cacheID else { return }
        let generation = manifests[key]?.generation
        for request in relayJobs.removeValue(forKey: key) ?? [] where request.job.generation == generation { relayCancellation?(request) }
        manifests[key]?.generation = nil
        expected[key] = nil
        errors[key] = "Download cancelled. Download again to finish; saved songs are kept."
        saveManifests()
        session.getAllTasks { @Sendable tasks in
            for task in tasks {
                guard let job = WatchDownloadJob.decode(task.taskDescription), job.playlistKey == key, job.generation == generation else { continue }
                task.cancel()
            }
        }
    }

    func remove(_ playlist: WatchPlaylist) {
        guard let key = playlist.cacheID else { return }
        cancel(playlist)
        try? FileManager.default.removeItem(at: Self.root.appending(path: key))
        validation.removeAll()
        manifests[key] = nil
        errors[key] = nil
        saveManifests()
    }

    /// Clears all downloads and manifests. Called when the phone revokes access due to profile
    /// lock or switch — cached audio for another profile must not remain on the Watch.
    func clearAll() {
        for request in relayJobs.values.flatMap({ $0 }) { relayCancellation?(request) }
        relayJobs.removeAll()
        session.getAllTasks { @Sendable tasks in
            for task in tasks { task.cancel() }
        }
        expected.removeAll()
        errors.removeAll()
        manifests.removeAll()
        validation.removeAll()
        currentCatalogue = nil
        try? FileManager.default.removeItem(at: Self.root)
        try? FileManager.default.removeItem(at: Self.manifestURL)
        DiagnosticsLog.shared.record("Watch downloads: cleared all downloads and manifests")
    }

    func reconnect(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completion(); return }
        guard !backgroundEventsFinished else {
            backgroundEventsFinished = false
            completion()
            return
        }
        backgroundCompletions.append(completion)
        _ = session
    }

    /// An edited smart playlist must finish against its new membership, even during a transfer.
    /// Also validates that manifest entries correspond to actual files on disk and prunes stale entries.
    func reconcile(_ catalogue: WatchCatalogue) {
        let previous = currentCatalogue
        currentCatalogue = catalogue
        // Each sync checks every saved file on disk once again; views then reuse the results.
        validation.removeAll()
        removeConfirmedServerFiles(catalogue, previous: previous)
        for playlist in previous?.playlists ?? [] where catalogue.playlist(matching: playlist) == nil {
            cancel(playlist)
        }
        for playlist in catalogue.playlists {
            guard let key = playlist.cacheID else { continue }
            let desired = Set(playlist.tracks.map(\.id))
            let previousTracks = previous?.playlist(matching: playlist)?.tracks

            if var saved = manifests[key] {
                saved.adoptFileRevisions(from: previous?.playlist(matching: playlist) ?? playlist)
                let previousFiles = saved.files
                let pruned = saved.pruneInvalidFiles(for: playlist, root: Self.root) { self.validation.isValid($0, expectedBytes: $1) }
                manifests[key] = saved
                if !pruned.isEmpty {
                    for id in pruned {
                        if let path = previousFiles[id] {
                            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
                                  parts[1] != ".", parts[1] != "..", !parts[1].isEmpty else { continue }
                            try? FileManager.default.removeItem(at: Self.root.appending(path: key).appending(path: path))
                        }
                    }
                    DiagnosticsLog.shared.record("Watch downloads: pruned \(pruned.count) invalid files for \(playlist.name)")
                }

                if saved.desired != desired || (previousTracks != nil && previousTracks != playlist.tracks) {
                    if saved.generation != nil, expected[key]?.isEmpty == false {
                        retarget(playlist, previous: previous?.playlist(matching: playlist), key: key)
                    } else {
                        cancel(playlist)
                        manifests[key]?.desired = desired
                        errors[key] = nil
                    }
                }
            }
        }
        saveManifests()
    }

    /// Keeps a running download going against the playlist's new membership. Transfers for songs
    /// that left or changed stop; songs that joined are requested in the same generation.
    private func retarget(_ playlist: WatchPlaylist, previous: WatchPlaylist?, key: String) {
        guard let generation = manifests[key]?.generation, let catalogue = currentCatalogue else { return }
        manifests[key]?.desired = Set(playlist.tracks.map(\.id))
        let plan = WatchDownloadRetarget(previous: previous, current: playlist, pending: expected[key] ?? [],
                                         available: Set(files(for: playlist).map(\.track.id)), generation: generation)
        let added = Set(plan.added.map(\.id))
        expected[key] = plan.kept.union(added)
        if expected[key]?.isEmpty == true { expected[key] = nil }

        let relay = relayJobs[key] ?? []
        relayJobs[key] = relay.filter { $0.isCurrent(in: catalogue, manifest: manifests[key]) }
        for request in relay where request.job.generation == generation && !request.isCurrent(in: catalogue, manifest: manifests[key]) {
            relayCancellation?(request)
        }
        session.getAllTasks { @Sendable [weak self] tasks in
            Task { @MainActor in
                // Decide against the catalogue current when the tasks arrive, not when they were requested.
                guard let self else { return }
                for task in tasks {
                    guard let job = WatchDownloadJob.decode(task.taskDescription), job.playlistKey == key,
                          job.generation == generation, self.currentCatalogue?.isCurrent(job) != true else { continue }
                    task.cancel()
                }
            }
        }

        guard !plan.added.isEmpty else { return }
        guard let credentials = credentialsProvider?(), credentials.matches(playlist) else {
            expected[key]?.subtract(added)
            if expected[key]?.isEmpty == true { expected[key] = nil }
            errors[key] = "Open Gumbo on your iPhone to sync the sign-in for this playlist’s NAS."
            return
        }
        Task {
            do {
                try await startTransfers(plan.added, in: playlist, key: key, generation: generation, credentials: credentials)
            } catch {
                guard manifests[key]?.generation == generation else { return }
                expected[key]?.subtract(added)
                if expected[key]?.isEmpty == true { expected[key] = nil }
                errors[key] = error.localizedDescription
            }
        }
    }

    /// A missing playlist is not evidence of deleted audio. Only explicit source-scoped NAS
    /// deletions remove saved files, including copies in an older playlist/profile manifest.
    private func removeConfirmedServerFiles(_ catalogue: WatchCatalogue, previous: WatchCatalogue?) {
        let deletedKeys = catalogue.deletedCacheKeys
        guard !deletedKeys.isEmpty else { return }
        let knownPlaylists = catalogue.playlists + (previous?.playlists ?? [])
        for key in Array(manifests.keys) {
            guard key.count == 64, key.allSatisfy(\.isHexDigit), var manifest = manifests[key] else { continue }
            let source = knownPlaylists.first(where: { $0.cacheID == key })?.driveID
            let removedIDs = Set(source.flatMap { catalogue.serverDeletedTrackIDs[$0] } ?? [])
            let removal = manifest.removeServerFiles(deletedCacheKeys: deletedKeys, removedTrackIDs: removedIDs)
            for path in removal.paths {
                try? FileManager.default.removeItem(at: Self.root.appending(path: key).appending(path: path))
            }
            if removal.affected {
                manifests[key] = manifest
                expected[key] = nil
                errors[key] = nil
            }
        }
        saveManifests()
        session.getAllTasks { @Sendable [weak self] tasks in
            Task { @MainActor in
                // A verified re-import may have arrived while URLSession enumerated tasks.
                // Only the current deletion ledger can cancel a newly requested generation.
                guard let activeKeys = self?.currentCatalogue?.deletedCacheKeys else { return }
                for task in tasks {
                    guard let job = WatchDownloadJob.decode(task.taskDescription),
                          activeKeys.contains((job.fileName as NSString).deletingPathExtension) else { continue }
                    task.cancel()
                }
            }
        }
    }

    private func restoreTasks() {
        session.getAllTasks { @Sendable tasks in
            let restored = tasks.compactMap { task in WatchDownloadJob.decode(task.taskDescription).map { ($0, task) } }
            // Legacy tasks cannot be attributed to a source safely.
            for task in tasks where WatchDownloadJob.decode(task.taskDescription) == nil { task.cancel() }
            Task { @MainActor in
                for (job, task) in restored where self.manifests[job.playlistKey]?.generation == job.generation {
                    if self.currentCatalogue?.deletedCacheKeys.contains((job.fileName as NSString).deletingPathExtension) == true {
                        task.cancel()
                        continue
                    }
                    // A transfer for a song that has since left the playlist or changed could never complete it.
                    if let catalogue = self.currentCatalogue, !catalogue.isCurrent(job) {
                        task.cancel()
                        continue
                    }
                    guard let original = task.originalRequest?.url, let current = task.currentRequest?.url,
                          NASTransportSecurity.permitsRedirect(from: original, to: current) else {
                        task.cancel()
                        self.fail(job: job, message: "Review the connection when you tap Download again. HTTP needs permission on this Watch; use HTTPS on your iPhone and sync again to change the address.")
                        continue
                    }
                    guard task.state == .running || task.state == .suspended else { continue }
                    if self.manifests[job.playlistKey]?.files[job.trackID] == job.generation.uuidString + "/" + job.fileName,
                       WatchDownloadValidation.failure(for: job.destination(in: Self.root), expectedBytes: job.expectedBytes) == nil { continue }
                    self.expected[job.playlistKey, default: []].insert(job.trackID)
                }
            }
        }
    }

    private func record(job: WatchDownloadJob) {
        validation.forget(job.destination(in: Self.root))
        guard currentCatalogue?.deletedCacheKeys.contains((job.fileName as NSString).deletingPathExtension) != true,
              manifests[job.playlistKey]?.generation == job.generation,
              manifests[job.playlistKey]?.desired.contains(job.trackID) == true else {
            try? FileManager.default.removeItem(at: job.destination(in: Self.root))
            return
        }
        guard let currentTrack = currentCatalogue?.playlists.first(where: { $0.cacheID == job.playlistKey })?.tracks.first(where: { $0.id == job.trackID }) else {
            try? FileManager.default.removeItem(at: job.destination(in: Self.root)); return
        }
        // A transfer for an older copy of this song must not stand in for the current one.
        guard job.fileRevision == currentTrack.fileRevision, currentCatalogue?.isCurrent(job) == true else {
            try? FileManager.default.removeItem(at: job.destination(in: Self.root))
            fail(job: job, message: "This song changed on your server. Download it again to update your saved copy.")
            return
        }
        if let failure = WatchDownloadValidation.failure(for: job.destination(in: Self.root), expectedBytes: currentTrack.fileSize) {
            try? FileManager.default.removeItem(at: job.destination(in: Self.root))
            fail(job: job, message: failure.localizedDescription)
            return
        }
        manifests[job.playlistKey]?.files[job.trackID] = job.generation.uuidString + "/" + job.fileName
        manifests[job.playlistKey]?.fileRevisions[job.trackID] = job.fileRevision
        expected[job.playlistKey]?.remove(job.trackID)
        if expected[job.playlistKey]?.isEmpty == true { expected[job.playlistKey] = nil }
        saveManifests()
    }

    func receiveRelay(_ request: WatchAudioRelayRequest, file: URL) {
        let job = request.job
        guard let currentCatalogue, request.isCurrent(in: currentCatalogue, manifest: manifests[job.playlistKey]) else { return }
        if let failure = WatchDownloadValidation.failure(for: file, expectedBytes: job.expectedBytes) {
            fail(job: job, message: failure.localizedDescription); return
        }
        let destination = job.destination(in: Self.root)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: file, to: destination)
            record(job: job)
            relayJobs[job.playlistKey]?.removeAll { $0 == request }
        } catch { fail(job: job, message: "This song could not be saved. Try again.") }
    }

    func failRelay(_ request: WatchAudioRelayRequest) {
        guard expected[request.job.playlistKey]?.contains(request.job.trackID) == true else { return }
        relayJobs[request.job.playlistKey]?.removeAll { $0 == request }
        fail(job: request.job, message: "Keep Gumbo open on your iPhone and try downloading again.")
    }

    private func fail(job: WatchDownloadJob, message: String) {
        validation.forget(job.destination(in: Self.root))
        guard manifests[job.playlistKey]?.generation == job.generation else { return }
        expected[job.playlistKey]?.remove(job.trackID)
        if expected[job.playlistKey]?.isEmpty == true { expected[job.playlistKey] = nil }
        // A song that left the playlist or changed since this transfer began only stops counting;
        // cancelling its transfer after a playlist edit is not a failure the listener must act on.
        guard currentCatalogue?.isCurrent(job) == true else { return }
        errors[job.playlistKey] = message
    }

    private func saveManifests() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifests) { try? data.write(to: Self.manifestURL, options: .atomic) }
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = WatchDownloadJob.decode(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard response?.url == downloadTask.originalRequest?.url else {
            Task { @MainActor in self.fail(job: job, message: "The server redirected this download. Check its address on your iPhone.") }
            return
        }
        if let failure = WatchDownloadValidation.failure(for: location, expectedBytes: job.expectedBytes, statusCode: response?.statusCode ?? 200,
                                                        contentType: response?.mimeType) {
            Task { @MainActor in self.fail(job: job, message: failure.localizedDescription) }
            return
        }
        let destination = job.destination(in: Self.root)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in self.fail(job: job, message: error.localizedDescription) }
            return
        }
        Task { @MainActor in self.record(job: job) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let job = WatchDownloadJob.decode(task.taskDescription) else { return }
        Task { @MainActor in self.fail(job: job, message: error.localizedDescription) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let completions = self.backgroundCompletions
            self.backgroundCompletions = []
            self.backgroundEventsFinished = completions.isEmpty
            for completion in completions { completion() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil); return
        }
        nonisolated(unsafe) let complete = completionHandler
        let job = WatchDownloadJob.decode(task.taskDescription)
        let original = task.originalRequest?.url
        let current = task.currentRequest?.url
        Task { @MainActor in
            guard let job, let credentials = self.credentialsProvider?(), credentials.providerKind == .webDAV,
                  let playlist = self.currentCatalogue?.playlists.first(where: { $0.cacheID == job.playlistKey }),
                  credentials.matches(playlist), credentials.permitsWebDAVDownload(original: original, current: current),
                  self.manifests[job.playlistKey]?.generation == job.generation,
                  let origin = NASOrigin(url: credentials.baseURL) else { complete(.cancelAuthenticationChallenge, nil); return }
            let scope = DownloadAuthentication(origin: origin, account: credentials.account, keychainAccount: "")
            guard scope.permits(challenge.protectionSpace, original: original, current: current,
                                failures: challenge.previousFailureCount) else { complete(.cancelAuthenticationChallenge, nil); return }
            complete(.useCredential, URLCredential(user: credentials.account, password: credentials.password, persistence: .none))
        }
    }
}
