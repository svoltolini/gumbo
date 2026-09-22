import Foundation
import Network

/// Reports each move to another usable network, such as home Wi-Fi after cellular, so a library
/// that could not reach its server tries again without waiting to be reopened.
nonisolated final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    /// Read and written only on the monitor's queue.
    private var lastPath: NWPath?

    init(onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // The first report describes the network as it already was when observation began.
            let previous = lastPath
            lastPath = path
            guard let previous, path.status == .satisfied, path != previous else { return }
            onChange()
        }
        monitor.start(queue: DispatchQueue(label: "one.gumbo.network-path"))
    }

    func cancel() { monitor.cancel() }

    deinit { monitor.cancel() }
}
