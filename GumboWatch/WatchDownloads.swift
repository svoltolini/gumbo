import Foundation
import Observation
import GumboCore

/// Background downloads scoped to the NAS, profile and playlist that requested them.
@Observable
@MainActor
final class WatchDownloads: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case none
        case downloading(done: Int, total: Int)
        case downloaded
        case failed(String)
    }

    static let shared = WatchDownloads()
    nonisolated static let sessionIdentifier = "com.samuelvoltolini.gumbo.watch.downloads"
    private var manifests: [String: WatchDownloadManifest] = [:]
    private var expected: [String: Set<String>] = [:]
    private var errors: [String: String] = [:]
    private var currentCatalogue: WatchCatalogue?
    private var backgroundCompletion: (() -> Void)?
    var credentialsProvider: (() -> WatchCredentials?)?
    var relayRequest: ((WatchAudioRelayRequest) -> Void)?
    var relayCancellation: ((WatchAudioRelayRequest) -> Void)?
    private var relayJobs: [String: [WatchAudioRelayRequest]] = [:]

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

    func state(of playlist: WatchPlaylist) -> State {
        guard let key = playlist.cacheID else { return .none }
        guard let manifest = manifests[key] else {
            return .none
        }

        let validatedFiles = manifest.validatedFileIDs(for: playlist, root: Self.root)
        let desiredTracks = Set(playlist.tracks.map(\.id))
        let relevantValidated = validatedFiles.intersection(desiredTracks)
        let done = relevantValidated.count
        let total = desiredTracks.count

        if !playlist.tracks.isEmpty, done == total { return .downloaded }

        if let pending = expected[key], !pending.isEmpty {
            return .downloading(done: done, total: total)
        }

        if let error = errors[key] { return .failed(error) }

        if done > 0 {
            return .failed("\(done) of \(total) songs are available. Download again to finish.")
        }

        if manifest.hasStoredFiles, !manifest.desired.isEmpty {
            let outstanding = manifest.outstandingTrackIDs(for: playlist, root: Self.root)
            if !outstanding.isEmpty {
                return .failed("Download again to finish.")
            }
        }

        return .none
    }

    func isDownloaded(_ playlist: WatchPlaylist) -> Bool { state(of: playlist) == .downloaded }

    func hasSavedFiles(for playlist: WatchPlaylist) -> Bool {
        guard let key = playlist.cacheID else { return false }
        return manifests[key]?.hasStoredFiles == true
    }

    /// Only verified files from this source and profile are handed to the player, in playlist order.
    func files(for playlist: WatchPlaylist) -> [(track: WatchTrack, url: URL)] {
        guard let key = playlist.cacheID, let manifest = manifests[key] else { return [] }
        return manifest.availableFiles(for: playlist, root: Self.root)
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
            if credentials.providerKind == .smb {
                guard let relayRequest else { throw ProviderError.unavailableOnDevice }
                for track in missing {
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
            for track in missing {
                guard let job = WatchDownloadJob(playlist: playlist, track: track, generation: generation) else { continue }
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
        } catch {
            guard manifests[key]?.generation == generation else { return }
            errors[key] = error.localizedDescription
            expected[key] = nil
            manifests[key]?.generation = nil
            saveManifests()
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
        currentCatalogue = nil
        try? FileManager.default.removeItem(at: Self.root)
        try? FileManager.default.removeItem(at: Self.manifestURL)
        DiagnosticsLog.shared.record("Watch downloads: cleared all downloads and manifests")
    }

    func reconnect(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completion(); return }
        backgroundCompletion = completion
        _ = session
    }

    /// An edited smart playlist must finish against its new membership, even during a transfer.
    /// Also validates that manifest entries correspond to actual files on disk and prunes stale entries.
    func reconcile(_ catalogue: WatchCatalogue) {
        let previous = currentCatalogue
        currentCatalogue = catalogue
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
                let pruned = saved.pruneInvalidFiles(for: playlist, root: Self.root)
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
                    cancel(playlist)
                    manifests[key]?.desired = desired
                    errors[key] = nil
                } else if saved.generation == nil, !saved.desired.isEmpty {
                    let outstanding = saved.outstandingTrackIDs(for: playlist, root: Self.root)
                    if !outstanding.isEmpty, expected[key] == nil {
                        let validated = saved.validatedFileIDs(for: playlist, root: Self.root)
                        if validated.count < desired.count, validated.count > 0 {
                            errors[key] = "\(validated.count) of \(desired.count) songs are available. Download again to finish."
                        }
                    }
                }
            }
        }
        saveManifests()
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
        guard currentCatalogue?.deletedCacheKeys.contains((job.fileName as NSString).deletingPathExtension) != true,
              manifests[job.playlistKey]?.generation == job.generation,
              manifests[job.playlistKey]?.desired.contains(job.trackID) == true else {
            try? FileManager.default.removeItem(at: job.destination(in: Self.root))
            return
        }
        guard let currentTrack = currentCatalogue?.playlists.first(where: { $0.cacheID == job.playlistKey })?.tracks.first(where: { $0.id == job.trackID }) else {
            try? FileManager.default.removeItem(at: job.destination(in: Self.root)); return
        }
        guard job.fileRevision == currentTrack.fileRevision else {
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
        guard manifests[job.playlistKey]?.generation == job.generation else { return }
        expected[job.playlistKey]?.remove(job.trackID)
        if expected[job.playlistKey]?.isEmpty == true { expected[job.playlistKey] = nil }
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
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
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
