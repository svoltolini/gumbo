import Foundation
import Network

/// A DSM server the user can sign in to: found on the network or typed in.
public nonisolated struct DiscoveredServer: Identifiable, Hashable, Sendable {
    public let name: String
    public let baseURL: URL
    public let model: String?

    public init(name: String, baseURL: URL, model: String?) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }

    /// Discovery suggests HTTPS. A service advertisement never grants permission to use HTTP.
    public init(name: String, host: String, port: Int, model: String?) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port == 5000 ? 5001 : (port == 80 ? 443 : port)
        self.init(name: name, baseURL: components.url!, model: model)
    }

    public var id: String { baseURL.absoluteString }
    public var host: String { baseURL.host() ?? "" }
    public var address: String { NASOrigin(url: baseURL)?.identifier ?? baseURL.absoluteString }
}

/// Browses Bonjour for Synology devices and resolves them to host and port.
@Observable
public final class ServerDiscovery {
    public private(set) var servers: [DiscoveredServer] = []
    public private(set) var isBrowsing = false
    private var browsers: [NWBrowser] = []
    private var attempts = DiscoveryAttempts()
    private var resolutions: [String: NWConnection] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    private nonisolated struct Candidate: Sendable {
        let name: String
        let type: String
        let endpoint: NWEndpoint
        let txt: [String: String]
    }

    public func start() {
        stop()
        isBrowsing = true
        let generation = attempts.generation
        for type in ["_http._tcp", "_smb._tcp"] {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let candidates = results.compactMap { result -> Candidate? in
                    guard case let .service(name, type, _, _) = result.endpoint else { return nil }
                    var txt: [String: String] = [:]
                    if case let .bonjour(record) = result.metadata { txt = record.dictionary }
                    return Candidate(name: name, type: type, endpoint: result.endpoint, txt: txt)
                }
                Task { @MainActor [weak self] in
                    guard let self, self.isBrowsing, self.attempts.generation == generation else { return }
                    self.consider(candidates)
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    public func stop() {
        attempts.reset()
        for task in timeouts.values { task.cancel() }
        timeouts = [:]
        for connection in resolutions.values { connection.cancel() }
        resolutions = [:]
        servers = []
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        isBrowsing = false
    }

    private func consider(_ candidates: [Candidate]) {
        for candidate in candidates where looksLikeSynology(candidate) {
            let key = candidate.type + candidate.name
            guard let token = attempts.begin(key) else { continue }
            resolve(candidate, key: key, token: token)
        }
    }

    private func looksLikeSynology(_ candidate: Candidate) -> Bool {
        let vendor = (candidate.txt["vendor"] ?? candidate.txt["manufacturer"] ?? "").lowercased()
        let name = candidate.name.lowercased()
        return vendor.contains("synology")
            || name.contains("synology")
            || name.contains("diskstation")
            || name.range(of: #"\bds\d{3,4}"#, options: .regularExpression) != nil
    }

    /// Opens a short-lived connection to learn the numeric host and port behind a Bonjour name.
    private func resolve(_ candidate: Candidate, key: String, token: UUID) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: candidate.endpoint, using: parameters)
        resolutions[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                var resolved: (String, Int)?
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    let hostText: String = switch host {
                    case .ipv4(let address): "\(address)"
                    case .ipv6(let address): "[\(address)]"
                    case .name(let name, _): name
                    @unknown default: "\(host)"
                    }
                    resolved = (hostText, Int(port.rawValue))
                }
                let model = candidate.txt["model"]
                let name = candidate.name
                let type = candidate.type
                Task { @MainActor [weak self] in
                    guard let self, self.finish(key, token: token), let (host, port) = resolved else { return }
                    // SMB tells us the host only; DSM's web API lives on 5000.
                    let dsmPort = type.hasPrefix("_smb") ? 5000 : port
                    let server = DiscoveredServer(name: model.map { "\(name) (\($0))" } ?? name, host: host.replacingOccurrences(of: "%en0", with: ""), port: dsmPort, model: model)
                    if !servers.contains(where: { $0.host == server.host }) {
                        servers.append(server)
                    }
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in _ = self?.finish(key, token: token) }
            default:
                break
            }
        }
        timeouts[key] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            _ = self?.finish(key, token: token)
        }
        connection.start(queue: .main)
    }
    @discardableResult
    private func finish(_ key: String, token: UUID) -> Bool {
        guard attempts.finish(key, token: token) else { return false }
        timeouts.removeValue(forKey: key)?.cancel()
        resolutions.removeValue(forKey: key)?.cancel()
        return isBrowsing
    }
}

/// Failed, timed-out and cancelled resolutions must free their key without affecting a newer retry.
nonisolated struct DiscoveryAttempts {
    private(set) var generation = UUID()
    private var pending: [String: UUID] = [:]
    mutating func reset() { generation = UUID(); pending = [:] }
    mutating func begin(_ key: String) -> UUID? {
        guard pending[key] == nil else { return nil }
        let token = UUID()
        pending[key] = token
        return token
    }
    mutating func finish(_ key: String, token: UUID) -> Bool {
        guard pending[key] == token else { return false }
        pending[key] = nil
        return true
    }
}
