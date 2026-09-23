import Foundation
import Testing
@testable import GumboCore

private nonisolated final class TagFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    static func respond(_ block: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.withLock { handler = block } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.lock.withLock({ Self.handler }) else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RemoteTagServiceTests {
    private let token = String(repeating: "t", count: 43)
    private let digest = String(repeating: "a", count: 64)

    private func client(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) throws -> RemoteTagService {
        TagFixtureProtocol.respond(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TagFixtureProtocol.self]
        return try RemoteTagService(endpoint: URL(string: "https://helper.example:8443")!, token: token, configuration: configuration)
    }

    @Test(arguments: ["http://helper.example", "https://user:secret@helper.example", "https://helper.example/api", "https://helper.example?token=x", "https://helper.example#x"])
    func unsafeEndpointsAreRejected(_ value: String) {
        #expect(throws: RemoteTagService.Error.invalidEndpoint) {
            try RemoteTagService(endpoint: URL(string: value)!, token: token)
        }
    }

    @Test func validatesCapabilitiesAndNeverPlacesTokenInURL() async throws {
        let client = try client { request in
            #expect(request.url?.absoluteString == "https://helper.example:8443/v1/capabilities")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "t", count: 43))
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return (200, Data(#"{"version":1,"service":"GumboTagService","fields":["album","albumArtist","genre"],"formats":["mp3","flac","m4a"],"maxFiles":128,"maxFileBytes":2147483648,"requiresSHA256":true,"supportsDryRun":true}"#.utf8))
        }
        #expect(try await client.capabilities().version == 1)
    }

    @Test func unknownProtocolVersionAndAuthenticationFailureAreNormalized() async throws {
        let unauthorized = try client { _ in (401, Data(#"{"version":1,"error":{"code":"unauthorized","message":"No"}}"#.utf8)) }
        await #expect(throws: RemoteTagService.Error.unauthorized) { _ = try await unauthorized.capabilities() }
        let changed = try client { _ in (200, Data(#"{"version":2}"#.utf8)) }
        await #expect(throws: RemoteTagService.Error.invalidResponse) { _ = try await changed.capabilities() }
    }

    @Test func deletionDisabledIsReportedAsTheHelpersReasonNotABadToken() async throws {
        let client = try client { _ in
            (403, Data(#"{"version":1,"error":{"code":"deletion_disabled","message":"Reviewed deletion is not enabled by this server's owner."}}"#.utf8))
        }
        await #expect(throws: RemoteTagService.Error.service(code: "deletion_disabled", message: "Reviewed deletion is not enabled by this server's owner.")) {
            _ = try await client.reviewDeletion(path: "song.wav")
        }
        let bare = try self.client { _ in (403, Data(#"{"version":1}"#.utf8)) }
        await #expect(throws: RemoteTagService.Error.unauthorized) { _ = try await bare.capabilities() }
    }

    @Test(arguments: ["/absolute.mp3", "../outside.mp3", "folder/../outside.mp3", "folder//song.mp3", "folder\\song.mp3", ".gumbo-tag-secret.mp3",
                      "folder/so\u{1}ng.mp3", "folder/so\u{7F}ng.mp3"])
    func rejectsPathsBeforeSendingRequest(_ path: String) async throws {
        let client = try client { _ in Issue.record("Unsafe request reached the network"); return (500, Data()) }
        await #expect(throws: RemoteTagService.Error.invalidPath) { _ = try await client.stat(path: path) }
    }

    @Test func formatCharactersInPathsAndTagsMatchTheHelpersRule() async throws {
        // ZWNJ, ZWJ, LRM, soft hyphen and BOM are ordinary text; only ASCII controls are refused.
        for text in ["دلتنگ\u{200C}ی", "👩\u{200D}🎤", "a\u{200E}b", "soft\u{00AD}hyphen", "\u{FEFF}BOM"] {
            #expect(!RemoteTagService.containsControl(text))
        }
        #expect(RemoteTagService.containsControl("tab\there"))
        #expect(RemoteTagService.containsControl("delete\u{7F}"))
        let path = "دلتنگ\u{200C}ی/song.mp3"
        let client = try client { request in
            if request.httpMethod == "PUT" { return (409, Data(#"{"version":1,"error":{"code":"conflict","message":"Changed"}}"#.utf8)) }
            return (200, Data("""
            {"version":1,"path":"\(path)","expected":{"size":500,"mtimeNs":1,"sha256":"\(String(repeating: "a", count: 64))"},"fields":{}}
            """.utf8))
        }
        #expect(try await client.stat(path: path).path == path)
        let edit = RemoteTagService.Edit(path: path, expected: .init(size: 500, mtimeNs: 1, sha256: digest), changes: .init(album: "👩\u{200D}🎤"))
        await #expect(throws: RemoteTagService.Error.service(code: "conflict", message: "Changed")) { _ = try await client.submit(jobID: UUID(), files: [edit]) }
    }

    @Test func statMustMatchRequestedPathAndIncludesActualFields() async throws {
        let client = try client { request in
            #expect(request.httpMethod == "POST")
            return (200, Data("""
            {"version":1,"path":"Artist/Album/Song.flac","expected":{"size":500,"mtimeNs":1000000000,"sha256":"\(String(repeating: "a", count: 64))"},"fields":{"album":"Album","albumArtist":"Artist","genre":"Jazz"}}
            """.utf8))
        }
        let file = try await client.stat(path: "Artist/Album/Song.flac")
        #expect(file.fields.genre == "Jazz")
        await #expect(throws: RemoteTagService.Error.invalidResponse) { _ = try await client.stat(path: "Other.flac") }
    }

    @Test func unchangedGenreOutcomeCarriesActualFieldsAndStableJobIdentity() async throws {
        let identifier = UUID()
        let client = try client { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.lastPathComponent == identifier.uuidString.lowercased())
            let snapshot = "\"size\":500,\"mtimeNs\":1000000000,\"sha256\":\"\(String(repeating: "a", count: 64))\""
            return (200, Data("""
            {"version":1,"jobID":"\(identifier.uuidString)","status":"completed","dryRun":false,"files":[{"path":"song.mp3","status":"unchanged","before":{\(snapshot)},"after":{\(snapshot),"fields":{"album":"Album","albumArtist":"Artist","genre":"Jazz"}}}]}
            """.utf8))
        }
        let edit = RemoteTagService.Edit(path: "song.mp3", expected: .init(size: 500, mtimeNs: 1000000000, sha256: digest),
                                         changes: .init(genre: "Rock"), onlyIfGenreMissing: true)
        let job = try await client.submit(jobID: identifier, files: [edit])
        #expect(job.status.isTerminal)
        #expect(job.files.first?.status == .unchanged)
        #expect(job.files.first?.after?.fields.genre == "Jazz")
    }

    @Test func deletionReviewAcceptsEmptyAudioAndRequiresAnExactPath() async throws {
        let client = try client { request in
            #expect(request.url?.path == "/v1/files/review-delete")
            #expect(request.httpMethod == "POST")
            return (200, Data("""
            {"version":1,"path":"empty.wav","expected":{"size":0,"mtimeNs":1,"sha256":"\(String(repeating: "a", count: 64))"}}
            """.utf8))
        }
        #expect(try await client.reviewDeletion(path: "empty.wav").expected.size == 0)
        await #expect(throws: RemoteTagService.Error.invalidResponse) { _ = try await client.reviewDeletion(path: "other.wav") }
        await #expect(throws: RemoteTagService.Error.invalidPath) { _ = try await client.reviewDeletion(path: "cover.jpg") }
    }

    @Test func deletionResponseRequiresItsOperationAndConfirmedFingerprint() async throws {
        let identifier = UUID()
        let expected = RemoteTagService.Expected(size: 0, mtimeNs: 1, sha256: digest)
        let client = try client { request in
            #expect(request.httpMethod == "PUT")
            return (200, Data("""
            {"version":1,"jobID":"\(identifier)","operation":"delete","status":"completed","dryRun":false,"files":[{"path":"empty.wav","status":"deleted","before":{"size":0,"mtimeNs":1,"sha256":"\(String(repeating: "a", count: 64))"}}]}
            """.utf8))
        }
        #expect(try await client.submitDeletion(jobID: identifier, files: [.init(path: "empty.wav", expected: expected)]).files[0].status == .deleted)
        let malformed = try self.client { _ in
            (200, Data("""
            {"version":1,"jobID":"\(identifier)","operation":"delete","status":"completed","dryRun":false,"files":[{"path":"empty.wav","status":"deleted"}]}
            """.utf8))
        }
        await #expect(throws: RemoteTagService.Error.invalidResponse) { _ = try await malformed.status(jobID: identifier) }
    }

    @Test func helperInspectionValidatesPathFingerprintOffsetAndLength() async throws {
        let client = try client { request in
            #expect(request.url?.path == "/v1/files/inspect-range")
            return (200, Data("""
            {"version":1,"path":"song.wav","expected":{"size":4,"mtimeNs":1,"sha256":"\(String(repeating: "a", count: 64))"},"offset":0,"data":"dGVzdA=="}
            """.utf8))
        }
        let expected = RemoteTagService.Expected(size: 4, mtimeNs: 1, sha256: digest)
        #expect(try await client.inspectionRead(path: "song.wav", expected: expected, range: 0..<4) == Data("test".utf8))
        await #expect(throws: RemoteTagService.Error.invalidResponse) { _ = try await client.inspectionRead(path: "other.wav", expected: expected, range: 0..<4) }
        await #expect(throws: RemoteTagService.Error.invalidResponse) { _ = try await client.inspectionRead(path: "song.wav", expected: expected, range: 1..<4) }
        await #expect(throws: RemoteTagService.Error.invalidRequest) { _ = try await client.inspectionRead(path: "song.wav", expected: expected, range: 0..<5) }
    }

    @Test func redirectsAreNeverFollowedEvenWhenSameOrigin() {
        let session = URLSession(configuration: .ephemeral)
        let original = URL(string: "https://helper.example:8443/v1/capabilities")!
        let task = session.dataTask(with: original)
        for target in [original, URL(string: "https://other.example/steal")!] {
            var followed = true
            RemoteTagRedirectDelegate.shared.urlSession(session, task: task,
                willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: target)) { followed = $0 != nil }
            #expect(!followed)
        }
        session.invalidateAndCancel()
    }

    @Test func cancelledTaskCannotStartAHelperRequest() async throws {
        let client = try client { _ in Issue.record("Cancelled request reached the network"); return (500, Data()) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.capabilities()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func metadataWriterRecoversLostSubmitAcknowledgementWithoutUploadingAudio() async throws {
        let fixture = TagMetadataFixture(mode: .lostAcknowledgement)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3")], drive: drive, helper: configuration)
        #expect(report.written.count == 1)
        #expect(report.failures.isEmpty)
        #expect(fixture.calls.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(fixture.calls.contains { $0.hasPrefix("GET /v1/jobs/") })
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterUsesUnchangedActualGenreAndDoesNotWriteCachedSuggestion() async throws {
        let fixture = TagMetadataFixture(mode: .unchanged)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3")], drive: drive,
                                        onlyIfGenreMissing: true, helper: configuration)
        #expect(report.written.isEmpty)
        #expect(report.unchanged.first?.genreTag == "Jazz")
        #expect(report.unchanged.first?.sourceModifiedAt == 2)
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterNeverSubmitsForAnUnauthorizedProfileOrFallsBackAfterHelperFailure() async throws {
        let blockedFixture = TagMetadataFixture(mode: .success)
        let (blockedWriter, blockedDrive, configuration) = try metadataFixture(blockedFixture)
        let blocked = await blockedWriter.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3")], drive: blockedDrive,
                                                helper: configuration, authorized: { false })
        #expect(blocked.written.isEmpty)
        #expect(!blockedFixture.calls.contains { $0.hasPrefix("PUT ") })
        let failedFixture = TagMetadataFixture(mode: .unauthorized)
        let (failedWriter, failedDrive, failedConfig) = try metadataFixture(failedFixture)
        let failed = await failedWriter.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3")], drive: failedDrive, helper: failedConfig)
        #expect(failed.written.isEmpty)
        #expect(failed.failures.count == 1)
        #expect(await failedDrive.transfers == 0)
        #expect(await blockedDrive.transfers == 0)
    }

    @Test func metadataWriterAccountsForCommitAfterCancellationAndStopsBeforeNextFile() async throws {
        let fixture = TagMetadataFixture(mode: .cancelAfterSubmit)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        fixture.setOnSubmit { Task { @MainActor in writer.cancel() } }
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3"), metadataTrack("next.mp3")],
                                        drive: drive, helper: configuration)
        #expect(report.wasCancelled)
        #expect(report.written.map(\.id) == ["song.mp3"])
        #expect(fixture.calls.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(fixture.calls.contains { $0.hasSuffix("/cancel") })
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterStopsOnUnconfirmedPollAndAttemptsCancellation() async throws {
        let fixture = TagMetadataFixture(mode: .pollFailure)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3"), metadataTrack("next.mp3")],
                                        drive: drive, helper: configuration)
        #expect(report.written.isEmpty)
        #expect(!report.failures.isEmpty)
        #expect(fixture.calls.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(fixture.calls.contains { $0.hasSuffix("/cancel") })
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterRecoversCommittedOutcomeFromCancellationAfterPollFailure() async throws {
        let fixture = TagMetadataFixture(mode: .pollRecoveredByCancellation)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3")], drive: drive, helper: configuration)
        #expect(report.written.map(\.id) == ["song.mp3"])
        #expect(report.written.first?.genreTag == "Rock")
        #expect(report.failures.isEmpty)
        #expect(fixture.calls.contains { $0.hasSuffix("/cancel") })
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterFailedCancellationReportsUnconfirmedAndNeverStartsNextFile() async throws {
        let fixture = TagMetadataFixture(mode: .cancellationFailure)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        fixture.setOnSubmit { Task { @MainActor in writer.cancel() } }
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3"), metadataTrack("next.mp3")],
                                        drive: drive, helper: configuration)
        #expect(report.wasCancelled)
        #expect(report.written.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.message.contains("couldn't confirm") == true)
        #expect(fixture.calls.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterStopsAfterAnInterruptedFile() async throws {
        let fixture = TagMetadataFixture(mode: .interrupted)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        let report = await writer.write(.init(genre: "Rock"), to: [metadataTrack("song.mp3"), metadataTrack("next.mp3")],
                                        drive: drive, helper: configuration)
        #expect(report.written.isEmpty)
        #expect(report.failures.count == 1)
        #expect(fixture.calls.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(await drive.transfers == 0)
    }

    @Test func metadataWriterPreservesDiscMarkerFromActualHelperTags() async throws {
        let fixture = TagMetadataFixture(mode: .renameAlbum)
        let (writer, drive, configuration) = try metadataFixture(fixture)
        let report = await writer.write(.init(album: "New Album"), to: [metadataTrack("song.mp3")], drive: drive, helper: configuration)
        #expect(report.failures.isEmpty)
        #expect(report.written.count == 1)
        #expect(report.written.first?.disc == 2)
        #expect(fixture.calls.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(await drive.transfers == 0)
    }

    private func metadataFixture(_ fixture: TagMetadataFixture) throws -> (MetadataWriter, TagMetadataDrive, TagServiceConfiguration) {
        let client = try client { try fixture.respond($0) }
        let writer = MetadataWriter(helperClientFactory: { _ in client })
        let configuration = TagServiceConfiguration(endpoint: URL(string: "https://helper.example:8443")!, sourceID: "tag-fixture", libraryRoot: "/music")
        return (writer, TagMetadataDrive(), configuration)
    }

    private func metadataTrack(_ name: String) -> Track {
        var track = Track(id: name, albumID: "album", title: name, index: 0, number: 1, disc: 1, duration: 120,
                          codec: "mp3", fileSize: 500, path: "/music/" + name, format: "MP3", genreTag: nil, isEnriched: true)
        track.sourceModifiedAt = 1
        return track
    }
}

private nonisolated final class TagMetadataFixture: @unchecked Sendable {
    enum Mode { case success, lostAcknowledgement, unchanged, unauthorized, cancelAfterSubmit, pollFailure, pollRecoveredByCancellation, cancellationFailure, renameAlbum, interrupted }
    private let lock = NSLock()
    private let mode: Mode
    private var recorded: [String] = []
    private var didSubmit: (@Sendable () -> Void)?
    private var jobID: String?
    private var cancelled = false
    init(mode: Mode) { self.mode = mode }
    var calls: [String] { lock.withLock { recorded } }
    func setOnSubmit(_ callback: @escaping @Sendable () -> Void) { lock.withLock { didSubmit = callback } }

    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        lock.withLock { recorded.append(method + " " + path) }
        if path == "/v1/capabilities" {
            return (200, Data(#"{"version":1,"service":"GumboTagService","fields":["album","albumArtist","genre"],"formats":["mp3","flac","m4a"],"maxFiles":128,"maxFileBytes":2147483648,"requiresSHA256":true,"supportsDryRun":true}"#.utf8))
        }
        let digest = String(repeating: "a", count: 64)
        if path == "/v1/files/stat" {
            let album = mode == .renameAlbum ? "Old Album (Disc 2)" : "Album"
            return (200, Data("""
            {"version":1,"path":"song.mp3","expected":{"size":500,"mtimeNs":1000000000,"sha256":"\(digest)"},"fields":{"album":"\(album)","albumArtist":"Artist","genre":"Jazz"}}
            """.utf8))
        }
        if method == "PUT" {
            let callback = lock.withLock { jobID = request.url!.lastPathComponent; return didSubmit }
            callback?()
            if mode == .renameAlbum {
                let stream = request.httpBodyStream
                var bytes = request.httpBody ?? Data()
                if let stream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        bytes.append(contentsOf: buffer.prefix(count))
                    }
                }
                let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let edits = try #require(object["files"] as? [[String: Any]])
                let changes = try #require(edits.first?["changes"] as? [String: String])
                #expect(changes["album"] == "New Album (Disc 2)")
            }
            if mode == .lostAcknowledgement { throw URLError(.networkConnectionLost) }
            if mode == .unauthorized { return (401, Data(#"{"version":1,"error":{"code":"unauthorized","message":"Token rejected"}}"#.utf8)) }
            if mode == .interrupted {
                // A helper restart marks the file that was running as unconfirmed with code "interrupted".
                return (200, Data("""
                {"version":1,"jobID":"\(request.url!.lastPathComponent)","status":"interrupted","dryRun":false,"files":[{"path":"song.mp3","status":"unconfirmed","error":{"code":"interrupted","message":"The service stopped during this file."}}]}
                """.utf8))
            }
        }
        if path.hasSuffix("/cancel") { lock.withLock { cancelled = true } }
        if ((mode == .pollFailure || mode == .pollRecoveredByCancellation) && method == "GET")
            || ((mode == .pollFailure || mode == .cancellationFailure) && path.hasSuffix("/cancel")) {
            throw URLError(.networkConnectionLost)
        }
        let id = lock.withLock { jobID } ?? request.url!.lastPathComponent
        let pending = mode == .cancellationFailure || ((mode == .cancelAfterSubmit || mode == .pollFailure || mode == .pollRecoveredByCancellation) && method == "PUT")
        let status = pending ? "running" : "completed"
        let fileStatus = pending ? "running" : mode == .unchanged ? "unchanged" : "succeeded"
        let genre = mode == .unchanged ? "Jazz" : "Rock"
        let album = mode == .renameAlbum ? "New Album (Disc 2)" : "Actual album"
        let snapshot = "\"size\":500,\"mtimeNs\":2000000000,\"sha256\":\"\(digest)\""
        return (200, Data("""
        {"version":1,"jobID":"\(id)","status":"\(status)","dryRun":false,"files":[{"path":"song.mp3","status":"\(fileStatus)","before":{\(snapshot)},"after":{\(snapshot),"fields":{"album":"\(album)","albumArtist":"Actual artist","genre":"\(genre)"}}}]}
        """.utf8))
    }
}

private actor TagMetadataDrive: WritableRemoteDrive {
    let id = "tag-fixture"
    let displayName = "Tag fixture"
    var transfers = 0
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { transfers += 1; throw RemoteWriteError.unsupported }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { transfers += 1; throw RemoteWriteError.unsupported }
    func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws { transfers += 1; throw RemoteWriteError.unsupported }
    func info(_ path: String) async throws -> RemoteEntry { RemoteEntry(path: path, name: "song.mp3", isDirectory: false, size: 500, modified: Date(timeIntervalSince1970: 1)) }
    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws { transfers += 1; throw RemoteWriteError.unsupported }
    func rename(_ path: String, to name: String) async throws { transfers += 1; throw RemoteWriteError.unsupported }
    func delete(_ path: String) async throws { transfers += 1; throw RemoteWriteError.unsupported }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}
