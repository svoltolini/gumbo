import Foundation
import Network

/// Reports each move to another usable network, such as home Wi-Fi after cellular, so a library
/// that could not reach its server tries again without waiting to be reopened.
nonisolated final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    /// Used only on the monitor's queue.
    private var moves = NetworkMoveFilter<NWPath>()

    init(onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if moves.isMove(to: path, usable: path.status == .satisfied) { onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "one.gumbo.network-path"))
    }

    func cancel() { monitor.cancel() }

    deinit { monitor.cancel() }
}

/// Tells a move to another usable network from the reports around it. Kept apart from the
/// monitor, whose paths only the system can make, so tests can hold it to that.
nonisolated struct NetworkMoveFilter<Path: Equatable> {
    private var last: Path?

    /// The first report describes the network as it already was when observation began; an
    /// unusable or unchanged path gives the server no new chance to answer.
    mutating func isMove(to path: Path, usable: Bool) -> Bool {
        let previous = last
        last = path
        guard let previous else { return false }
        return usable && path != previous
    }
}
