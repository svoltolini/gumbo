#if os(macOS)
import Foundation
import Network

/// A test-only loopback relay. After arming, discard a real Samba reply and close both sockets.
/// It never sees/decrypts credentials or SMB payloads; the destination is fixed to the fixture.
nonisolated final class SMBDeleteReplyProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GumboSMBDeleteReplyProxy")
    private let lock = NSLock()
    private let listener: NWListener
    private var dropReply = false
    private var pairs: [(NWConnection, NWConnection)] = []
    private var lost = false
    var didDropReply: Bool { lock.withLock { lost } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] incoming in self?.accept(incoming) }
            listener.start(queue: queue)
        }
    }

    func arm() { lock.withLock { dropReply = true } }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                listener.cancel()
                for (a, b) in pairs { a.cancel(); b.cancel() }
                pairs.removeAll()
                continuation.resume()
            }
        }
    }

    private func accept(_ incoming: NWConnection) {
        let server = NWConnection(host: "127.0.0.1", port: 14450, using: .tcp)
        pairs.append((incoming, server))
        incoming.start(queue: queue); server.start(queue: queue)
        relay(incoming, to: server, reply: false)
        relay(server, to: incoming, reply: true)
    }

    private func relay(_ source: NWConnection, to target: NWConnection, reply: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            let discard = lock.withLock {
                if reply && dropReply && bytes?.isEmpty == false { dropReply = false; lost = true; return true }
                return false
            }
            if discard { source.cancel(); target.cancel(); return }
            guard error == nil, let bytes, !bytes.isEmpty else { source.cancel(); target.cancel(); return }
            target.send(content: bytes, completion: .contentProcessed { [weak self] error in
                if error != nil || complete { source.cancel(); target.cancel() }
                else { self?.relay(source, to: target, reply: reply) }
            })
        }
    }
}
#endif
