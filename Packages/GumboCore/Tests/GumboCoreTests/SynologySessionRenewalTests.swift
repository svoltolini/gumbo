import Foundation
import Testing
@testable import GumboCore

/// Records every request by the session it carried, and every sign-in.
private actor RenewalLedger {
    private(set) var sessions: [String] = []
    private(set) var logins = 0

    func request(_ url: URL) -> String {
        let sid = renewalSID(of: url) ?? ""
        sessions.append(sid)
        return sid
    }

    func login() -> Int {
        logins += 1
        return logins
    }
}

private nonisolated func renewalSID(of url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "_sid" }?.value
}

private nonisolated func renewalSession(_ sid: String, host: String = "renewal-test.invalid") -> DSMSession {
    let fileStation = SynologyAPIDescriptor(path: "entry.cgi", minVersion: 1, maxVersion: 2)
    return DSMSession(baseURL: URL(string: "https://\(host):5001")!, sid: sid,
                      apis: ["SYNO.FileStation.List": fileStation, "SYNO.FileStation.Download": fileStation], account: "listener")
}

private nonisolated func expiredListing(_ code: Int = 119) -> SynologyError {
    SynologyError.api(code: code, api: "SYNO.FileStation.List")
}

private nonisolated func renewalPage(_ names: [String]) -> SynologyFileList {
    SynologyFileList(files: names.map {
        SynologyFileEntry(isdir: false, name: $0, path: "/music/\($0)", additional: nil)
    }, offset: 0, total: names.count)
}

/// Serves File Station downloads per host, so the suites below can run in parallel.
private nonisolated final class DSMDownloadFixture: URLProtocol, @unchecked Sendable {
    nonisolated struct Reply: Sendable {
        let status: Int
        let type: String
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]

    static func respond(host: String, _ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock { handlers[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let handler = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.type, "Content-Length": "\(reply.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private nonisolated func refusal(_ code: Int) -> DSMDownloadFixture.Reply {
    DSMDownloadFixture.Reply(status: 200, type: "application/json; charset=utf-8",
                             body: Data("{\"error\":{\"code\":\(code)},\"success\":false}".utf8))
}

@Suite struct SynologySessionRenewalTests {
    @Test(arguments: [106, 107, 119])
    func endedSessionCodesAreRecognisedOnAnyAPI(_ code: Int) {
        #expect(SynologyError.api(code: code, api: "SYNO.FileStation.List").isSessionExpired)
        #expect(SynologyError.api(code: code, api: "SYNO.FileStation.Download").isSessionExpired)
        #expect(SynologyError.api(code: code, api: "SYNO.FileStation.List").errorDescription == "The session has expired. Sign in again.")
        #expect(!SynologyError.api(code: code, api: "SYNO.FileStation.List").requiresNewCredentials)
    }

    @Test func otherRefusalsAreNotEndedSessions() {
        #expect(!SynologyError.api(code: 105, api: "SYNO.FileStation.List").isSessionExpired)
        #expect(!SynologyError.api(code: 408, api: "SYNO.FileStation.List").isSessionExpired)
        #expect(!SynologyError.api(code: 400, api: "SYNO.API.Auth").isSessionExpired)
        #expect(!SynologyError.twoFactorRequired.isSessionExpired)
        #expect(!SynologyError.unreachable("offline").isSessionExpired)
    }

    @Test func signInRefusalsAreTheAuthAPIsOwnCodes() {
        for code in [400, 402, 406, 407, 408, 409, 410] {
            #expect(SynologyError.api(code: code, api: "SYNO.API.Auth").refusesSignIn)
        }
        #expect(!SynologyError.api(code: 119, api: "SYNO.API.Auth").refusesSignIn)
        #expect(!SynologyError.api(code: 407, api: "SYNO.FileStation.List").refusesSignIn)
        #expect(!SynologyError.unreachable("offline").refusesSignIn)
        #expect(SynologyError.api(code: 409, api: "SYNO.API.Auth").errorDescription?.contains("expired") == true)
    }

    @Test func endedSessionSignsInOnceAndRepeatsTheRequest() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: { expired in
            guard expired.sid == "expired" else { throw CancellationError() }
            _ = await ledger.login()
            return renewalSession("renewed")
        }) { url in
            guard await ledger.request(url) == "renewed" else { throw expiredListing() }
            return renewalPage(["a.flac"])
        }
        let staleAddress = try #require(drive.streamURL(for: "/music/a.flac"))
        let files = try await drive.list("/music")
        #expect(files.map(\.name) == ["a.flac"])
        #expect(await ledger.logins == 1)
        #expect(await ledger.sessions == ["expired", "renewed"])
        #expect(drive.session.sid == "renewed")
        // Addresses made from now on, such as the next song's, carry the new session.
        #expect(drive.streamURL(for: "/music/a.flac").flatMap(renewalSID) == "renewed")
        #expect(drive.sessionID(of: staleAddress) == "expired")
        #expect(drive.sessionID(of: try #require(URL(string: "https://elsewhere.invalid:5001/webapi/entry.cgi?_sid=expired"))) == nil)
        #expect(drive.id == NASSource.identifier(baseURL: renewalSession("x").baseURL, account: "listener"))
    }

    @Test func aSecondRefusalIsReportedWithoutAnotherSignIn() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: { _ in
            let attempt = await ledger.login()
            return renewalSession("renewed-\(attempt)")
        }) { url in
            _ = await ledger.request(url)
            throw expiredListing(106)
        }
        do {
            _ = try await drive.list("/music")
            Issue.record("A session refused twice must not be reported as a listing")
        } catch let error as SynologyError {
            #expect(error.isSessionExpired)
        }
        #expect(await ledger.logins == 1)
        // Neither weaker listing parameters nor another sign-in follow the repeated refusal.
        #expect(await ledger.sessions == ["expired", "renewed-1"])
        await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
        #expect(await ledger.logins == 1)
    }

    @Test func concurrentRefusalsShareASingleSignIn() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: { _ in
            _ = await ledger.login()
            try await Task.sleep(for: .milliseconds(80))
            return renewalSession("renewed")
        }) { url in
            let sid = await ledger.request(url)
            try await Task.sleep(for: .milliseconds(5))
            guard sid == "renewed" else { throw expiredListing() }
            return renewalPage(["\(sid).flac"])
        }
        let listings = try await withThrowingTaskGroup(of: [RemoteEntry].self) { group in
            for index in 0..<12 { group.addTask { try await drive.list("/music/\(index)") } }
            var all: [[RemoteEntry]] = []
            for try await listing in group { all.append(listing) }
            return all
        }
        #expect(listings.count == 12)
        #expect(listings.allSatisfy { $0.map(\.name) == ["renewed.flac"] })
        #expect(await ledger.logins == 1)
    }

    @Test func renewalThatNeedsAPersonIsNotRepeated() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: { _ in
            _ = await ledger.login()
            throw SynologyError.twoFactorRequired
        }) { url in
            _ = await ledger.request(url)
            throw expiredListing()
        }
        for _ in 0..<3 {
            await #expect(throws: SynologyError.self) { try await drive.list("/music") }
        }
        #expect(await ledger.logins == 1)
        #expect(drive.session.sid == "expired")
    }

    @Test func renewalIsTriedAgainOnceTheIntervalHasPassed() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: { _ in
            guard await ledger.login() > 1 else { throw SynologyError.unreachable("offline") }
            return renewalSession("renewed")
        }, renewalInterval: .milliseconds(200)) { url in
            guard await ledger.request(url) == "renewed" else { throw expiredListing() }
            return renewalPage([])
        }
        await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
        // Within the interval the failure stands without another sign-in.
        await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
        #expect(await ledger.logins == 1)
        try await Task.sleep(for: .milliseconds(300))
        try await drive.checkSession(folder: "/music")
        #expect(await ledger.logins == 2)
        #expect(drive.session.sid == "renewed")
    }

    @Test func aRenewalTheAppDeclinesDoesNotHoldOffTheNext() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: { _ in
            // The first time the app's connection is changing; the second time it signs in.
            guard await ledger.login() > 1 else { throw CancellationError() }
            return renewalSession("renewed")
        }) { url in
            guard await ledger.request(url) == "renewed" else { throw expiredListing() }
            return renewalPage([])
        }
        do {
            try await drive.checkSession(folder: "/music")
            Issue.record("A declined renewal leaves DSM's refusal standing")
        } catch let error as SynologyError {
            #expect(error.isSessionExpired)
        }
        try await drive.checkSession(folder: "/music")
        #expect(await ledger.logins == 2)
        #expect(drive.session.sid == "renewed")
    }

    @Test func withoutRenewalTheRefusalStands() async throws {
        let ledger = RenewalLedger()
        let drive = SynologyDrive(session: renewalSession("expired"), displayName: "NAS", renewal: nil) { url in
            _ = await ledger.request(url)
            throw expiredListing()
        }
        do {
            _ = try await drive.list("/music")
            Issue.record("The refusal should be reported")
        } catch let error as SynologyError {
            #expect(error.isSessionExpired)
        }
        #expect(await ledger.sessions == ["expired"])
    }

    @Test func refusedDownloadIsReadAsDSMErrorAndRepeatedWithTheRenewedSession() async throws {
        let host = "renewal-\(UUID().uuidString.lowercased()).invalid"
        let audio = Data("fLaC-audio".utf8)
        DSMDownloadFixture.respond(host: host) { request in
            // DSM refuses an ended session with HTTP 200 and JSON in place of the file.
            guard let url = request.url, renewalSID(of: url) == "renewed" else { return refusal(119) }
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-3" {
                return DSMDownloadFixture.Reply(status: 206, type: "audio/flac", body: audio.prefix(4))
            }
            return DSMDownloadFixture.Reply(status: 200, type: "image/jpeg", body: audio)
        }
        let ledger = RenewalLedger()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DSMDownloadFixture.self]
        let drive = SynologyDrive(session: renewalSession("expired", host: host), displayName: "NAS", renewal: { _ in
            _ = await ledger.login()
            return renewalSession("renewed", host: host)
        }, configuration: configuration) { _ in renewalPage([]) }
        #expect(try await drive.read("/music/a.flac", range: 0..<4) == Data("fLaC".utf8))
        #expect(try await drive.download("/music/cover.jpg", maxBytes: 1024) == audio)
        #expect(await ledger.logins == 1)
    }

    /// Tag write-back rewrites the song this saves; a refusal must never stand in for it on disk.
    @Test func fileDownloadWritesOnlyTheFileFromTheRenewedSession() async throws {
        let host = "renewal-file-\(UUID().uuidString.lowercased()).invalid"
        let audio = Data("fLaC-audio".utf8)
        DSMDownloadFixture.respond(host: host) { request in
            guard let url = request.url, url.lastPathComponent != "gone.flac" else { return refusal(408) }
            guard renewalSID(of: url) == "renewed" else { return refusal(119) }
            return DSMDownloadFixture.Reply(status: 200, type: "audio/flac", body: audio)
        }
        let ledger = RenewalLedger()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DSMDownloadFixture.self]
        let drive = SynologyDrive(session: renewalSession("expired", host: host), displayName: "NAS", renewal: { _ in
            _ = await ledger.login()
            return renewalSession("renewed", host: host)
        }, configuration: configuration) { _ in renewalPage([]) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "gumbo-renewal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let song = folder.appending(path: "a.flac")
        try await drive.downloadFile("/music/a.flac", to: song, maxBytes: 1024)
        #expect(try Data(contentsOf: song) == audio)
        #expect(await ledger.logins == 1)
        let gone = folder.appending(path: "gone.flac")
        do {
            try await drive.downloadFile("/music/gone.flac", to: gone, maxBytes: 1024)
            Issue.record("A refusal must not be saved as the file")
        } catch {
            #expect(error.isMissingPath)
        }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        #expect(await ledger.logins == 1)
    }

    @Test func refusedDownloadIsNeverTakenForTheFile() async throws {
        let host = "refusal-\(UUID().uuidString.lowercased()).invalid"
        DSMDownloadFixture.respond(host: host) { request in
            request.url?.lastPathComponent == "gone.flac" ? refusal(408)
                : DSMDownloadFixture.Reply(status: 200, type: "text/html", body: Data("<html>proxy</html>".utf8))
        }
        let ledger = RenewalLedger()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DSMDownloadFixture.self]
        let drive = SynologyDrive(session: renewalSession("current", host: host), displayName: "NAS", renewal: { _ in
            _ = await ledger.login()
            return renewalSession("renewed", host: host)
        }, configuration: configuration) { _ in renewalPage([]) }
        do {
            _ = try await drive.read("/music/gone.flac", range: 0..<4)
            Issue.record("A refusal must not be returned as the file's bytes")
        } catch {
            #expect(error.isMissingPath)
        }
        await #expect(throws: (any Error).self) { try await drive.download("/music/cover.jpg", maxBytes: 1024) }
        #expect(await ledger.logins == 0)
    }
}
