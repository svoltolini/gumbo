import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A playable resource retains the authenticated session; it never puts a password in a URL.
public nonisolated enum RemoteMediaSource: Sendable {
    case url(URL)
    case file(drive: any RemoteFileDrive, path: String)

    public static func resolve(drive: any RemoteDrive, path: String) -> Self? {
        // Preserve the existing DSM transport, including its session lifecycle.
        if let url = drive.streamURL(for: path) { return .url(url) }
        #if !os(watchOS)
        if let drive = drive as? any RemoteFileDrive { return .file(drive: drive, path: path) }
        #endif
        return nil
    }
}

/// Retain this wrapper for as long as AVFoundation uses its asset (resourceLoader's delegate is weak).
nonisolated final class RemoteMediaAsset: @unchecked Sendable {
    let asset: AVURLAsset
    #if !os(watchOS)
    private let loader: RemoteAssetLoader?
    #endif

    init(_ source: RemoteMediaSource) {
        switch source {
        case .url(let url):
            #if !os(watchOS)
            loader = nil
            #endif
            // Let AVFoundation choose duration handling; forcing imprecise timing can reject PCM/WAV.
            asset = AVURLAsset(url: url)
        case .file(let drive, let path):
            #if os(watchOS)
            // Watch playback uses completed downloads; AVFoundation has no resource-loader API there.
            _ = drive; _ = path
            asset = AVURLAsset(url: URL(fileURLWithPath: "/gumbo-streaming-unavailable-on-watch"))
            #else
            let loader = RemoteAssetLoader(drive: drive, path: path)
            self.loader = loader
            // Unique opaque URL: no host, source credentials or NAS path reaches AVFoundation logs.
            var components = URLComponents()
            components.scheme = "gumbo-media"
            components.host = UUID().uuidString
            components.path = "/audio." + (path as NSString).pathExtension
            asset = AVURLAsset(url: components.url!)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            #endif
        }
    }

    func cancel() {
        asset.cancelLoading()
        #if !os(watchOS)
        loader?.cancel()
        #endif
    }
    deinit {
        #if !os(watchOS)
        loader?.cancel()
        #endif
    }
}

/// Delegate state and AVAssetResourceLoadingRequest access stay on `queue`. Network operations use
/// detached tasks; only bounded chunks cross back to the delegate queue. Each cancelled AV request
/// cancels its own read task, so an old seek cannot feed bytes to a replacement request.
#if !os(watchOS)
nonisolated private final class RemoteAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "one.gumbo.media-loader")
    private let drive: any RemoteFileDrive
    private let path: String
    private let snapshot: RemoteAssetSnapshot
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(drive: any RemoteFileDrive, path: String) {
        self.drive = drive; self.path = path
        snapshot = RemoteAssetSnapshot(drive: drive, path: path)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let box = RequestBox(request)
        let key = ObjectIdentifier(request)
        let requestedOffset = request.dataRequest?.requestedOffset ?? 0
        let offset = request.dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        let length = request.dataRequest?.requestedLength ?? 0
        let throughEnd = request.dataRequest?.requestsAllDataToEndOfResource == true
        let hasDataRequest = request.dataRequest != nil
        tasks[key] = Task.detached { [self] in
            do {
                let entry = try await snapshot.entry()
                guard entry.path == path, !entry.isDirectory, let size = entry.size, size >= 0,
                      requestedOffset >= 0, offset >= 0, offset <= size else { throw ProviderError.invalidResponse }
                let type = UTType(filenameExtension: (path as NSString).pathExtension)?.identifier ?? UTType.audio.identifier
                await onQueue {
                    guard !box.request.isCancelled else { return }
                    box.request.contentInformationRequest?.contentType = type
                    box.request.contentInformationRequest?.contentLength = size
                    box.request.contentInformationRequest?.isByteRangeAccessSupported = true
                }
                var cursor = offset
                let end = throughEnd ? size : min(size, requestedOffset + min(Int64(max(0, length)), Int64.max - requestedOffset))
                while hasDataRequest && cursor < end {
                    try Task.checkCancellation()
                    let upper = min(end, cursor + min(1024 * 1024, Int64.max - cursor))
                    let bytes = try await drive.read(path, range: cursor..<upper, matching: entry)
                    guard !bytes.isEmpty, Int64(bytes.count) <= upper - cursor else { throw ProviderError.invalidResponse }
                    try Task.checkCancellation()
                    await onQueue { if !box.request.isCancelled { box.request.dataRequest?.respond(with: bytes) } }
                    cursor += Int64(bytes.count)
                }
                try Task.checkCancellation()
                await onQueue {
                    if !box.request.isCancelled { box.request.finishLoading() }
                    self.tasks.removeValue(forKey: key)
                }
            } catch {
                await onQueue {
                    if !box.request.isCancelled { box.request.finishLoading(with: error) }
                    self.tasks.removeValue(forKey: key)
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    func cancel() {
        queue.async { [self] in
            tasks.values.forEach { $0.cancel() }; tasks.removeAll()
            Task { await snapshot.cancel() }
        }
    }

    private func onQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in queue.async { operation(); continuation.resume() } }
    }

    private final class RequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
    }
}

/// One immutable file identity spans content-info reads, decoder requests and later seeks.
/// Sharing the in-flight task prevents concurrent AV requests from choosing different versions.
private actor RemoteAssetSnapshot {
    let drive: any RemoteFileDrive
    let path: String
    var task: Task<RemoteEntry, any Error>?
    var cancelled = false
    init(drive: any RemoteFileDrive, path: String) { self.drive = drive; self.path = path }
    func entry() async throws -> RemoteEntry {
        guard !cancelled else { throw CancellationError() }
        if task == nil { task = Task { try await drive.info(path) } }
        let entry = try await task!.value
        guard !cancelled else { throw CancellationError() }
        return entry
    }
    func cancel() { cancelled = true; task?.cancel() }
}

#endif
