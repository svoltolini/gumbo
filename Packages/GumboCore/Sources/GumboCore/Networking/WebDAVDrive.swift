import Foundation

/// Read-only HTTPS WebDAV. Authentication belongs to requests, never URLs or catalogue records.
/// Paths are virtual absolute paths under baseURL; '/' denotes that configured endpoint.
public nonisolated final class WebDAVDrive: RemoteFileDrive {
    public let id: String
    public let displayName: String
    public var baseURL: URL { scope.baseURL }
    private let scope: WebDAVPathScope
    private let authorization: String
    private let session: URLSession
    static let maximumRangeBytes: Int64 = 32 * 1024 * 1024

    public convenience init(baseURL: URL, username: String, password: String, sourceID: String) throws {
        try self.init(baseURL: baseURL, username: username, password: password, sourceID: sourceID, configuration: .ephemeral)
    }

    /// The configuration is injectable only inside the module, for isolated URLProtocol fixtures.
    init(baseURL: URL, username: String, password: String, sourceID: String, configuration: URLSessionConfiguration) throws {
        scope = try WebDAVPathScope(baseURL: baseURL)
        guard !username.isEmpty, !password.isEmpty, !username.contains(":"),
              !username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !sourceID.isEmpty else {
            throw WebDAVError.invalidCredentials
        }
        id = sourceID
        displayName = baseURL.host ?? "WebDAV"
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: WebDAVRequestDelegate.shared, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func authenticatedRequest(for path: String) throws -> URLRequest {
        try request(for: path)
    }

    private func request(for path: String, directory: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: try scope.url(for: path, directory: directory))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// An authenticated resource cannot safely be represented by an AVPlayer URL alone.
    public func streamURL(for path: String) -> URL? { nil }

    public func roots() async throws -> [RemoteEntry] {
        let root = try await info("/")
        guard root.isDirectory else { throw WebDAVError.incompleteListing }
        return [root]
    }

    public func validateAccess() async throws { _ = try await roots() }

    public func info(_ path: String) async throws -> RemoteEntry {
        guard let entry = try await propfind(path, depth: 0).first else { throw WebDAVError.incompleteListing }
        return entry
    }

    public func list(_ path: String) async throws -> [RemoteEntry] { try await propfind(path, depth: 1) }

    @concurrent private func propfind(_ path: String, depth: Int) async throws -> [RemoteEntry] {
        var request = try request(for: path, directory: depth == 1)
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>
        """.utf8)
        let (data, _) = try await collect(request, maximum: WebDAVListing.maximumBytes, status: 207)
        try Task.checkCancellation()
        return try WebDAVListing.parse(data, scope: scope, requestURL: request.url!, path: path, depth: depth)
    }

    @concurrent public func read(_ path: String, range: Range<Int64>) async throws -> Data {
        try await readRange(path, range: range, version: nil)
    }

    @concurrent public func read(_ path: String, range: Range<Int64>, matching entry: RemoteEntry) async throws -> Data {
        guard entry.path == path else { throw ProviderError.changed }
        if let version = entry.version {
            guard Self.strongETag(version) == version else { throw ProviderError.invalidResponse }
            return try await readRange(path, range: range, version: version)
        }
        let before = try await info(path)
        guard before.sameVersion(as: entry) else { throw ProviderError.changed }
        let bytes = try await readRange(path, range: range, version: nil)
        let after = try await info(path)
        guard after.sameVersion(as: entry) else { throw ProviderError.changed }
        return bytes
    }

    @concurrent private func readRange(_ path: String, range: Range<Int64>, version: String?) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              range.upperBound - range.lowerBound <= Self.maximumRangeBytes else { throw RemoteDriveError.tooLarge }
        if range.isEmpty { return Data() }
        var request = try request(for: path)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        if let version { request.setValue(version, forHTTPHeaderField: "If-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let http = try validate(response, request: request)
        if http.statusCode == 412 { throw ProviderError.changed }
        if let version, (200..<300).contains(http.statusCode) || http.statusCode == 416 {
            guard Self.strongETag(http.value(forHTTPHeaderField: "ETag")) == version else { throw ProviderError.changed }
        }
        if http.statusCode == 416 {
            guard let length = WebDAVContentRange.unsatisfiedLength(http.value(forHTTPHeaderField: "Content-Range")),
                  range.lowerBound >= length else { throw WebDAVError.invalidRange }
            return Data()
        }
        if http.statusCode == 200 { throw WebDAVError.rangeNotSupported }
        try Self.requireStatus(http.statusCode, expected: 206)
        guard let returned = WebDAVContentRange(http.value(forHTTPHeaderField: "Content-Range")),
              returned.start == range.lowerBound, returned.end < range.upperBound,
              returned.end == range.upperBound - 1 || returned.total == returned.end + 1 else { throw WebDAVError.invalidRange }
        let expected = returned.end - returned.start + 1
        return try await withTaskCancellationHandler {
            let data = try await BoundedBytes.collect(bytes, maximum: expected, expectedLength: response.expectedContentLength)
            guard data.count == expected else { throw WebDAVError.invalidRange }
            return data
        } onCancel: { bytes.task.cancel() }
    }

    @concurrent public func download(_ path: String, maxBytes: Int64) async throws -> Data {
        try await collect(request(for: path), maximum: maxBytes, status: 200).0
    }

    /// URLSession streams to a temporary file. The task delegate cancels oversized transfers as
    /// bytes arrive; only a successful, length-checked file is copied to the caller's new path.
    @concurrent public func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws {
        guard maxBytes >= 0 else { throw RemoteDriveError.tooLarge }
        let request = try request(for: path)
        let guardDelegate = WebDAVDownloadDelegate(maximum: maxBytes)
        let result: (URL, URLResponse)
        do { result = try await session.download(for: request, delegate: guardDelegate) }
        catch {
            if guardDelegate.exceededLimit { throw RemoteDriveError.tooLarge }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: result.0) }
        try Task.checkCancellation()
        let http = try validate(result.1, request: request)
        try Self.requireStatus(http.statusCode, expected: 200)
        let size = (try FileManager.default.attributesOfItem(atPath: result.0.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= maxBytes, !guardDelegate.exceededLimit else { throw RemoteDriveError.tooLarge }
        guard result.1.expectedContentLength < 0 || size == result.1.expectedContentLength else { throw WebDAVError.invalidResponse }
        try FileManager.default.copyItem(at: result.0, to: destination)
    }

    @concurrent private func collect(_ request: URLRequest, maximum: Int64, status: Int) async throws -> (Data, HTTPURLResponse) {
        guard maximum >= 0 else { throw RemoteDriveError.tooLarge }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let http = try validate(response, request: request)
        try Self.requireStatus(http.statusCode, expected: status)
        return try await withTaskCancellationHandler {
            let data = try await BoundedBytes.collect(bytes, maximum: maximum, expectedLength: response.expectedContentLength)
            guard response.expectedContentLength < 0 || data.count == response.expectedContentLength else { throw WebDAVError.invalidResponse }
            return (data, http)
        } onCancel: { bytes.task.cancel() }
    }

    private func validate(_ response: URLResponse, request: URLRequest) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw WebDAVError.invalidResponse }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { throw WebDAVError.invalidResponse }
        return http
    }

    static func requireStatus(_ code: Int, expected: Int) throws {
        guard code != expected else { return }
        switch code {
        case 401: throw WebDAVError.authenticationRequired
        case 403: throw WebDAVError.forbidden
        case 404: throw WebDAVError.notFound
        case 300..<400: throw WebDAVError.redirectRefused
        default: throw RemoteDriveError.http(code)
        }
    }

    static func strongETag(_ value: String?) -> String? {
        guard let value, value.count >= 2, value.first == "\"", value.last == "\"",
              value.dropFirst().dropLast().utf8.allSatisfy({ $0 >= 33 && $0 != 34 && $0 != 127 }) else { return nil }
        return value
    }
}

nonisolated struct WebDAVContentRange: Equatable {
    let start: Int64, end: Int64
    let total: Int64?
    init?(_ value: String?) {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Self.number(bounds[0]), let end = Self.number(bounds[1]), end >= start, end < Int64.max else { return nil }
        let total = parts[1] == "*" ? nil : Self.number(parts[1])
        guard parts[1] == "*" || total.map({ $0 > end }) == true else { return nil }
        self.start = start; self.end = end; self.total = total
    }
    static func unsatisfiedLength(_ value: String?) -> Int64? {
        guard let value, value.hasPrefix("bytes */") else { return nil }
        return number(value.dropFirst(8))
    }
    private static func number(_ value: Substring) -> Int64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(value)
    }
}

/// Refuse redirects before any second request: even same-origin login redirects can turn a
/// successful response into HTML or move authentication outside the configured folder.
nonisolated class WebDAVRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = WebDAVRequestDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // HTTPS trust remains the operating system's decision. No credential cache, interactive
        // retries, client certificates or unrequested authentication methods are consulted.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }
}

private nonisolated final class WebDAVDownloadDelegate: WebDAVRequestDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.withLock { exceeded } }
    init(maximum: Int64) { self.maximum = maximum }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum {
            lock.withLock { exceeded = true }
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
