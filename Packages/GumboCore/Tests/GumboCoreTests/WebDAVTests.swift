import Foundation
import Testing
@testable import GumboCore

private nonisolated struct DAVFixtureResponse: Sendable {
    var status = 207
    var headers: [String: String] = [:]
    var body = Data()
}

private nonisolated final class DAVFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> DAVFixtureResponse)?
    static func respond(_ handler: @escaping @Sendable (URLRequest) throws -> DAVFixtureResponse) { lock.withLock { self.handler = handler } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let callback = Self.lock.withLock({ Self.handler }) else { throw URLError(.badServerResponse) }
            let value = try callback(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: value.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !value.body.isEmpty { client?.urlProtocol(self, didLoad: value.body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private nonisolated func davResponse(_ href: String, collection: Bool = false, size: String? = "5", status: Int = 200) -> String {
    let length = size.map { "<D:getcontentlength>\($0)</D:getcontentlength>" } ?? ""
    return """
    <D:response><D:href>\(href)</D:href><D:propstat><D:prop><D:resourcetype>\(collection ? "<D:collection/>" : "")</D:resourcetype>\(length)<D:getlastmodified>Mon, 21 Sep 2026 10:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 \(status) Fixture</D:status></D:propstat></D:response>
    """
}

private nonisolated func davXML(_ responses: String) -> Data {
    Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">\(responses)</D:multistatus>".utf8)
}

@Suite(.serialized) struct WebDAVTests {
    private func drive(_ callback: @escaping @Sendable (URLRequest) throws -> DAVFixtureResponse) throws -> WebDAVDrive {
        DAVFixtureProtocol.respond(callback)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DAVFixtureProtocol.self]
        return try WebDAVDrive(baseURL: URL(string: "https://nas.example:5006/dav/music/")!, username: "tester", password: "fixture-secret", sourceID: "webdav-fixture", configuration: configuration)
    }

    @Test func credentialsStayInHeadersAndPathsRoundTrip() throws {
        let provider = try drive { _ in DAVFixtureResponse() }
        let request = try provider.authenticatedRequest(for: "/Café & 100%/01 #Song?.flac")
        #expect(request.url?.absoluteString == "https://nas.example:5006/dav/music/Caf%C3%A9%20%26%20100%25/01%20%23Song%3F.flac")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("tester:fixture-secret".utf8).base64EncodedString())
        #expect(request.url?.user == nil && request.url?.password == nil && request.url?.query == nil)
        #expect(provider.streamURL(for: "/song.flac") == nil)
        #expect(provider.id == "webdav-fixture")
    }

    @Test(arguments: ["http://nas.example/dav", "https://user:pass@nas.example/dav", "https://nas.example/dav?token=secret", "https://nas.example/dav#fragment", "https://nas.example/a/../dav", "https://nas.example/a/%2e%2e/dav", "https://nas.example/a%2fb/"])
    func refusesUnsafeEndpoints(_ address: String) throws {
        #expect(throws: WebDAVError.invalidAddress) { try WebDAVDrive(baseURL: URL(string: address)!, username: "u", password: "p", sourceID: "fixture") }
    }

    @Test(arguments: ["relative.mp3", "//other/file.mp3", "/../file.mp3", "/x/./file.mp3", "/a//b", "/a\\b", "/x\0y"])
    func refusesUnsafeVirtualPaths(_ path: String) throws {
        let provider = try drive { _ in DAVFixtureResponse() }
        #expect(throws: WebDAVError.unsafePath) { try provider.authenticatedRequest(for: path) }
    }

    @Test func listsNamespaceAwareEntriesAndExcludesSelf() async throws {
        let provider = try drive { request in
            #expect(request.httpMethod == "PROPFIND")
            #expect(request.value(forHTTPHeaderField: "Depth") == "1")
            #expect(request.url?.path == "/dav/music/Album")
            return DAVFixtureResponse(body: davXML(davResponse("/dav/music/Album/", collection: true) + davResponse("https://nas.example:5006/dav/music/Album/01%20Caf%C3%A9%20%26%20Me.flac") + davResponse("cover.jpg")))
        }
        let entries = try await provider.list("/Album")
        #expect(entries.map(\.path) == ["/Album/01 Café & Me.flac", "/Album/cover.jpg"])
        #expect(entries.first?.name == "01 Café & Me.flac")
        #expect(entries.first?.size == 5)
        #expect(entries.first?.modified != nil)
    }

    @Test func rootIsConfiguredEndpointAndInfoUsesDepthZero() async throws {
        let provider = try drive { request in
            #expect(request.value(forHTTPHeaderField: "Depth") == "0")
            #expect(request.url?.absoluteString == "https://nas.example:5006/dav/music/")
            return DAVFixtureResponse(body: davXML(davResponse("/dav/music/", collection: true)))
        }
        let roots = try await provider.roots()
        #expect(roots.count == 1 && roots[0].path == "/" && roots[0].isDirectory)
    }

    @Test func unsupportedOptionalPropertiesDoNotDiscardValidEntries() async throws {
        let body = davXML("""
        <D:response><D:href>/dav/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:getlastmodified/><D:getcontentlength/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
        """)
        let provider = try drive { _ in DAVFixtureResponse(body: body) }
        #expect(try await provider.roots().count == 1)
    }

    @Test(arguments: [403, 404, 500, 507]) func failedChildInvalidatesWholeListing(_ status: Int) async throws {
        let provider = try drive { _ in DAVFixtureResponse(body: davXML(davResponse("/dav/music/", collection: true) + davResponse("/dav/music/blocked/", collection: true, status: status))) }
        await #expect(throws: WebDAVError.incompleteListing) { try await provider.list("/") }
    }

    @Test(arguments: ["https://evil.example/dav/music/song.mp3", "http://nas.example:5006/dav/music/song.mp3", "/dav/music-other/song.mp3", "/dav/music/%2e%2e/song.mp3", "/dav/music/a%2fb.mp3", "/dav/music/song.mp3?token=x", "https://u:p@nas.example:5006/dav/music/song.mp3"])
    func refusesEscapingResponseHrefs(_ href: String) async throws {
        let provider = try drive { _ in DAVFixtureResponse(body: davXML(davResponse("/dav/music/", collection: true) + davResponse(href))) }
        await #expect(throws: WebDAVError.unsafePath) { try await provider.list("/") }
    }

    @Test(arguments: ["duplicate", "missing-self", "nested-child", "truncated", "wrong-namespace", "entity", "missing-type"])
    func malformedListingsNeverBecomeAuthoritative(_ mode: String) async throws {
        var data = davXML(davResponse("/dav/music/", collection: true))
        switch mode {
        case "duplicate": data = davXML(davResponse("/dav/music/", collection: true) + davResponse("/dav/music/song.mp3") + davResponse("/dav/music/%73ong.mp3"))
        case "missing-self": data = davXML(davResponse("/dav/music/song.mp3"))
        case "nested-child": data = davXML(davResponse("/dav/music/", collection: true) + davResponse("/dav/music/a/song.mp3"))
        case "truncated": data = data.dropLast(10)
        case "wrong-namespace": data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "DAV:", with: "evil:").utf8)
        case "entity": data = Data("<!DOCTYPE foo [<!ENTITY xxe SYSTEM 'file:///etc/passwd'>]><D:multistatus xmlns:D=\"DAV:\">&xxe;</D:multistatus>".utf8)
        case "missing-type": data = davXML("<D:response><D:href>/dav/music/</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
        default: break
        }
        let body = data
        let provider = try drive { _ in DAVFixtureResponse(body: body) }
        await #expect(throws: (any Error).self) { try await provider.list("/") }
    }

    @Test func validRangesAndShortEOFReturnExactBytes() async throws {
        let provider = try drive { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=3-10")
            return DAVFixtureResponse(status: 206, headers: ["Content-Range": "bytes 3-5/6", "Content-Length": "3"], body: Data([3, 4, 5]))
        }
        #expect(try await provider.read("/song.flac", range: 3..<11) == Data([3, 4, 5]))
    }

    @Test(arguments: ["bytes 0-2/10", "bytes 3-4/10", "bytes 3-5/5", "bytes 5-3/10", "bytes 3-11/20", "bytes +3-5/10", "", "bytes 3-9223372036854775807/*"])
    func refusesMismatchedOrMalformedContentRanges(_ range: String) async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: 206, headers: ["Content-Range": range], body: Data([3, 4, 5])) }
        await #expect(throws: WebDAVError.invalidRange) { try await provider.read("/song.flac", range: 3..<11) }
    }

    @Test(arguments: [2, 4]) func refusesTruncatedOrOversizedRangeBodies(_ count: Int) async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: 206, headers: ["Content-Range": "bytes 3-5/6"], body: Data(repeating: 1, count: count)) }
        await #expect(throws: (any Error).self) { try await provider.read("/song.flac", range: 3..<11) }
    }

    @Test func serverIgnoringRangeDoesNotReturnWholeSong() async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: 200, body: Data(repeating: 1, count: 100)) }
        await #expect(throws: WebDAVError.rangeNotSupported) { try await provider.read("/song.flac", range: 3..<11) }
    }

    @Test func unsatisfiedRangeIsEOFOnlyWithVerifiedLength() async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: 416, headers: ["Content-Range": "bytes */6"]) }
        #expect(try await provider.read("/song.flac", range: 6..<10).isEmpty)
        await #expect(throws: WebDAVError.invalidRange) { try await provider.read("/song.flac", range: 3..<10) }
    }

    @Test func strongValidatorIsReadAndUsedAsACondition() async throws {
        let provider = try drive { request in
            if request.httpMethod == "PROPFIND" {
                let entry = davResponse("/dav/music/song.flac").replacingOccurrences(of: "</D:prop>", with: "<D:getetag>&quot;v1&quot;</D:getetag></D:prop>")
                return DAVFixtureResponse(body: davXML(entry))
            }
            #expect(request.value(forHTTPHeaderField: "If-Match") == "\"v1\"")
            return DAVFixtureResponse(status: 206, headers: ["Content-Range": "bytes 0-2/5", "ETag": "\"v1\""], body: Data([1, 2, 3]))
        }
        let entry = try await provider.info("/song.flac")
        #expect(entry.version == "\"v1\"")
        #expect(try await provider.read("/song.flac", range: 0..<3, matching: entry) == Data([1, 2, 3]))
        #expect(WebDAVDrive.strongETag("W/\"v1\"") == nil)
        #expect(WebDAVDrive.strongETag("\"bad\r\nheader\"") == nil)
    }

    @Test(arguments: ["\"v2\"", "W/\"v1\"", ""])
    func changedWeakOrMissingValidatorCannotMixSongVersions(_ returned: String) async throws {
        let provider = try drive { _ in
            DAVFixtureResponse(status: 206, headers: ["Content-Range": "bytes 0-2/5", "ETag": returned], body: Data([9, 9, 9]))
        }
        let entry = RemoteEntry(path: "/song.flac", name: "song.flac", isDirectory: false, size: 5, modified: nil, version: "\"v1\"")
        await #expect(throws: ProviderError.changed) { try await provider.read("/song.flac", range: 0..<3, matching: entry) }
    }

    @Test func serverRejectingReadConditionReportsConcurrentChange() async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: 412) }
        let entry = RemoteEntry(path: "/song.flac", name: "song.flac", isDirectory: false, size: 5, modified: nil, version: "\"v1\"")
        await #expect(throws: ProviderError.changed) { try await provider.read("/song.flac", range: 0..<3, matching: entry) }
    }

    @Test func boundsAreEnforcedBeforeAndDuringTransfer() async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: 200, body: Data(repeating: 42, count: 33)) }
        await #expect(throws: RemoteDriveError.tooLarge) { try await provider.download("/cover.jpg", maxBytes: 32) }
        await #expect(throws: RemoteDriveError.tooLarge) { try await provider.read("/song.flac", range: 0..<(WebDAVDrive.maximumRangeBytes + 1)) }
        #expect(try await provider.read("/song.flac", range: 0..<0).isEmpty)
    }

    @Test(arguments: [401, 403, 404, 302]) func userFacingHTTPFailures(_ status: Int) async throws {
        let provider = try drive { _ in DAVFixtureResponse(status: status) }
        let expected: WebDAVError = status == 401 ? .authenticationRequired : status == 403 ? .forbidden : status == 404 ? .notFound : .redirectRefused
        await #expect(throws: expected) { try await provider.roots() }
    }

    @Test(arguments: ["https://evil.example/file", "http://nas.example:5006/dav/music/song.flac", "https://nas.example:5006/login", "https://nas.example:5006/dav/music/song.flac/"])
    func redirectDelegateNeverForwardsAuthentication(_ destination: String) throws {
        let provider = try drive { _ in DAVFixtureResponse() }
        let original = try provider.authenticatedRequest(for: "/song.flac")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination])!
        WebDAVRequestDelegate.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                newRequest: URLRequest(url: URL(string: destination)!)) { redirected in
            #expect(redirected == nil)
        }
    }

    @Test func downloadFileUsesDiskAndRejectsOversizedFilesWithoutDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "webdav-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = try drive { _ in DAVFixtureResponse(status: 200, headers: ["Content-Length": "5"], body: Data([1, 2, 3, 4, 5])) }
        let destination = folder.appending(path: "song.flac")
        try await provider.downloadFile("/song.flac", to: destination, maxBytes: 5)
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3, 4, 5]))
        let refused = folder.appending(path: "refused.flac")
        await #expect(throws: RemoteDriveError.tooLarge) { try await provider.downloadFile("/song.flac", to: refused, maxBytes: 4) }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
    }
}
