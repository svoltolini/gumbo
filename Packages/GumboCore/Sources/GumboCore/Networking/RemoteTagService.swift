import Foundation

/// Optional, separately installed tag helper. Its token is distinct from NAS credentials.
/// All paths are relative to the explicitly configured helper music-root mapping.
public actor RemoteTagService {
    public nonisolated struct Capabilities: Decodable, Sendable {
        public let version: Int
        public let service: String
        public let fields: [String]
        public let formats: [String]
        public let maxFiles: Int
        public let maxFileBytes: Int64
        public let requiresSHA256: Bool
        public let supportsDryRun: Bool
        public let supportsReviewedDeletion: Bool?
        public let supportsVerifiedInspection: Bool?
    }

    public nonisolated struct Expected: Codable, Equatable, Sendable {
        public let size: Int64
        public let mtimeNs: Int64
        public let sha256: String
        public init(size: Int64, mtimeNs: Int64, sha256: String) {
            self.size = size; self.mtimeNs = mtimeNs; self.sha256 = sha256
        }
    }

    public nonisolated struct FileState: Decodable, Sendable {
        public let version: Int
        public let path: String
        public let expected: Expected
        public let fields: Fields
    }

    public nonisolated struct DeletionReview: Decodable, Sendable {
        public let version: Int
        public let path: String
        public let expected: Expected
    }

    public nonisolated struct InspectionRead: Decodable, Sendable {
        public let version: Int
        public let path: String
        public let expected: Expected
        public let offset: Int64
        public let data: Data
    }
    private nonisolated struct InspectionRequest: Encodable {
        let path: String
        let expected: Expected
        let offset: Int64
        let count: Int64
    }

    public nonisolated struct Deletion: Codable, Sendable {
        public let path: String
        public let expected: Expected
        public init(path: String, expected: Expected) { self.path = path; self.expected = expected }
    }

    public nonisolated struct Fields: Decodable, Sendable {
        public let album: String?
        public let albumArtist: String?
        public let genre: String?
    }

    public nonisolated struct Snapshot: Decodable, Sendable {
        public let size: Int64
        public let mtimeNs: Int64
        public let sha256: String
        public let fields: Fields
        public var expected: Expected { Expected(size: size, mtimeNs: mtimeNs, sha256: sha256) }
    }

    public nonisolated struct Changes: Codable, Sendable {
        public let album: String?
        public let albumArtist: String?
        public let genre: String?
        public init(album: String? = nil, albumArtist: String? = nil, genre: String? = nil) {
            self.album = album; self.albumArtist = albumArtist; self.genre = genre
        }
    }

    public nonisolated struct Edit: Codable, Sendable {
        public let path: String
        public let expected: Expected
        public let changes: Changes
        public let onlyIfGenreMissing: Bool
        public init(path: String, expected: Expected, changes: Changes, onlyIfGenreMissing: Bool = false) {
            self.path = path; self.expected = expected; self.changes = changes; self.onlyIfGenreMissing = onlyIfGenreMissing
        }
    }

    public nonisolated enum JobStatus: String, Decodable, Sendable {
        case queued, running, completed, cancelled, partial, interrupted
        public var isTerminal: Bool { self != .queued && self != .running }
    }

    public nonisolated enum FileStatus: String, Decodable, Sendable {
        case pending, running, succeeded, unchanged, validated, deleted, failed, cancelled, unconfirmed
    }

    public nonisolated struct Failure: Decodable, Sendable {
        public let code: String
        public let message: String
    }

    public nonisolated struct FileOutcome: Decodable, Sendable {
        public let path: String
        public let status: FileStatus
        public let before: Expected?
        public let after: Snapshot?
        public let error: Failure?
    }

    public nonisolated struct Job: Decodable, Sendable {
        public let version: Int
        public let jobID: UUID
        public let operation: String?
        public let status: JobStatus
        public let dryRun: Bool
        public let files: [FileOutcome]
    }

    public nonisolated enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case invalidEndpoint, invalidToken, invalidPath, invalidRequest, unauthorized, unavailable, invalidResponse
        case service(code: String, message: String)
        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Use the helper’s full HTTPS address, with no path, account or password in the address."
            case .invalidToken: "Enter a valid private token for the metadata helper."
            case .invalidPath: "This music file is outside the metadata helper’s configured folder."
            case .invalidRequest: "The tag edit is incomplete or exceeds the helper’s limits."
            case .unauthorized: "The metadata helper rejected its token. Check Advanced Settings."
            case .unavailable: "The metadata helper could not be reached. Check its address and trusted HTTPS certificate."
            case .invalidResponse: "The metadata helper returned an incompatible or incomplete response."
            case .service(_, let message): message
            }
        }
    }

    private nonisolated struct VersionEnvelope: Decodable { let version: Int }
    private nonisolated struct ErrorEnvelope: Decodable { let version: Int; let error: Failure }
    private nonisolated struct StatRequest: Encodable { let path: String }
    private nonisolated struct SubmitRequest: Encodable { let version = 1; let files: [Edit]; let dryRun: Bool }

    private nonisolated struct DeleteRequest: Encodable {
        let version = 1
        let operation = "delete"
        let files: [Deletion]
        let dryRun = false
    }

    private let endpoint: URL
    private let token: String
    private let session: URLSession

    public init(endpoint: URL, token: String) throws {
        try self.init(endpoint: endpoint, token: token, configuration: .ephemeral)
    }

    /// Test injection stays internal; production always starts from an ephemeral configuration.
    init(endpoint: URL, token: String, configuration: URLSessionConfiguration) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else { throw Error.invalidEndpoint }
        guard (43...256).contains(token.utf8.count), token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw Error.invalidToken }
        self.endpoint = endpoint
        self.token = token
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: RemoteTagRedirectDelegate.shared, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func capabilities() async throws -> Capabilities {
        let value: Capabilities = try await request("GET", path: "v1/capabilities")
        guard value.service == "GumboTagService", value.requiresSHA256, value.maxFiles > 0,
              value.maxFiles <= 128, value.maxFileBytes > 0,
              Set(value.fields).isSubset(of: ["album", "albumArtist", "genre"]),
              Set(value.formats).isSubset(of: ["mp3", "flac", "m4a"]),
              !value.fields.isEmpty, !value.formats.isEmpty else { throw Error.invalidResponse }
        return value
    }

    public func stat(path: String) async throws -> FileState {
        try Self.validate(path: path)
        let value: FileState = try await request("POST", path: "v1/files/stat", body: JSONEncoder().encode(StatRequest(path: path)))
        guard value.path == path, Self.valid(value.expected) else { throw Error.invalidResponse }
        return value
    }

    public func submit(jobID: UUID, files: [Edit], dryRun: Bool = false) async throws -> Job {
        guard (1...128).contains(files.count), Set(files.map(\.path)).count == files.count else { throw Error.invalidRequest }
        for file in files {
            try Self.validate(path: file.path)
            guard Self.valid(file.expected) else { throw Error.invalidRequest }
            let values = [file.changes.album, file.changes.albumArtist, file.changes.genre].compactMap { $0 }
            if file.onlyIfGenreMissing, file.changes.album != nil || file.changes.albumArtist != nil || file.changes.genre == nil {
                throw Error.invalidRequest
            }
            guard !values.isEmpty, values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw Error.invalidRequest }
        }
        let value: Job = try await request("PUT", path: "v1/jobs/" + jobID.uuidString.lowercased(),
                                           body: JSONEncoder().encode(SubmitRequest(files: files, dryRun: dryRun)))
        try validate(value, jobID: jobID)
        guard value.operation == nil || value.operation == "tags" else { throw Error.invalidResponse }
        guard value.dryRun == dryRun, value.files.map(\.path) == files.map(\.path) else { throw Error.invalidResponse }
        return value
    }

    public func reviewDeletion(path: String) async throws -> DeletionReview {
        try Self.validate(path: path, deletion: true)
        let value: DeletionReview = try await request("POST", path: "v1/files/review-delete", body: JSONEncoder().encode(StatRequest(path: path)))
        guard value.path == path, Self.valid(value.expected, allowEmpty: true) else { throw Error.invalidResponse }
        return value
    }

    public func inspectionRead(path: String, expected: Expected, range: Range<Int64>) async throws -> Data {
        try Self.validate(path: path, deletion: true)
        guard Self.valid(expected, allowEmpty: true), range.lowerBound >= 0,
              range.upperBound <= expected.size, range.count <= 1024 * 1024 else { throw Error.invalidRequest }
        let body = InspectionRequest(path: path, expected: expected, offset: range.lowerBound, count: Int64(range.count))
        let value: InspectionRead = try await request("POST", path: "v1/files/inspect-range", body: JSONEncoder().encode(body))
        guard value.path == path, value.expected == expected, value.offset == range.lowerBound,
              value.data.count == range.count else { throw Error.invalidResponse }
        return value.data
    }

    public func submitDeletion(jobID: UUID, files: [Deletion]) async throws -> Job {
        guard (1...128).contains(files.count), Set(files.map(\.path)).count == files.count else { throw Error.invalidRequest }
        for file in files {
            try Self.validate(path: file.path, deletion: true)
            guard Self.valid(file.expected, allowEmpty: true) else { throw Error.invalidRequest }
        }
        let value: Job = try await request("PUT", path: "v1/jobs/" + jobID.uuidString.lowercased(),
                                           body: JSONEncoder().encode(DeleteRequest(files: files)))
        try validate(value, jobID: jobID)
        guard value.operation == "delete", !value.dryRun, value.files.map(\.path) == files.map(\.path) else { throw Error.invalidResponse }
        return value
    }

    public func status(jobID: UUID) async throws -> Job {
        let value: Job = try await request("GET", path: "v1/jobs/" + jobID.uuidString.lowercased())
        try validate(value, jobID: jobID)
        return value
    }

    /// Cancellation is acknowledged separately; keep polling to learn which files finished their commit.
    public func cancel(jobID: UUID) async throws -> Job {
        let value: Job = try await request("POST", path: "v1/jobs/" + jobID.uuidString.lowercased() + "/cancel", body: Data("{}".utf8))
        try validate(value, jobID: jobID)
        return value
    }

    private func validate(_ job: Job, jobID: UUID) throws {
        guard job.jobID == jobID, (1...128).contains(job.files.count),
              Set(job.files.map(\.path)).count == job.files.count else { throw Error.invalidResponse }
        guard job.operation == nil || job.operation == "tags" || job.operation == "delete" else { throw Error.invalidResponse }
        let deletion = job.operation == "delete"
        for file in job.files {
            try Self.validate(path: file.path, deletion: deletion)
            if let before = file.before, !Self.valid(before, allowEmpty: deletion) { throw Error.invalidResponse }
            if deletion {
                guard file.after == nil, file.status != .succeeded, file.status != .unchanged,
                      file.status != .deleted || (!job.dryRun && file.before != nil),
                      file.status != .validated || (job.dryRun && file.before != nil) else { throw Error.invalidResponse }
                continue
            }
            guard file.status != .deleted else { throw Error.invalidResponse }
            if let after = file.after, !Self.valid(after.expected) { throw Error.invalidResponse }
            if file.status == .succeeded || file.status == .unchanged || file.status == .validated {
                guard file.after != nil, file.before != nil else { throw Error.invalidResponse }
            }
        }
    }

    private nonisolated static func valid(_ value: Expected, allowEmpty: Bool = false) -> Bool {
        value.size >= (allowEmpty ? 0 : 1) && value.size <= 2 * 1024 * 1024 * 1024 && value.mtimeNs >= 0
            && value.sha256.utf8.count == 64 && value.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private nonisolated static func validate(path: String, deletion: Bool = false) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".gumbo-tag-") }),
              (deletion ? RemoteDriveSupport.audioExtensions : ["mp3", "flac", "m4a"]).contains((path as NSString).pathExtension.lowercased()) else { throw Error.invalidPath }
    }

    private func request<Response: Decodable & Sendable>(_ method: String, path: String, body: Data? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard body == nil || body!.count <= 256 * 1024 else { throw Error.invalidRequest }
        let url = endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url,
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
                bytes.task.cancel(); throw Error.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 { bytes.task.cancel(); throw Error.unauthorized }
            guard !(300...399).contains(http.statusCode), http.expectedContentLength <= 2 * 1024 * 1024 else {
                bytes.task.cancel(); throw Error.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2 * 1024 * 1024 else { bytes.task.cancel(); throw Error.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            let decoder = JSONDecoder()
            guard (try? decoder.decode(VersionEnvelope.self, from: data).version) == 1 else { throw Error.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                if let value = try? decoder.decode(ErrorEnvelope.self, from: data), value.error.message.utf8.count <= 1024 {
                    throw Error.service(code: value.error.code, message: value.error.message)
                }
                throw Error.unavailable
            }
            guard let value = try? decoder.decode(Response.self, from: data) else { throw Error.invalidResponse }
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as Error {
            throw error
        } catch {
            throw Error.unavailable
        }
    }
}

/// No redirects are followed, including same-origin ones; a token is sent only to the configured endpoint.
nonisolated final class RemoteTagRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RemoteTagRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
