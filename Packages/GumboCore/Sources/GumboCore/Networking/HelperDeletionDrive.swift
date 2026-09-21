import CryptoKit
import Foundation

nonisolated protocol ReviewedDeletionService: Sendable {
    func reviewDeletion(path: String) async throws -> RemoteTagService.DeletionReview
    func inspectionRead(path: String, expected: RemoteTagService.Expected, range: Range<Int64>) async throws -> Data
    func submitDeletion(jobID: UUID, files: [RemoteTagService.Deletion]) async throws -> RemoteTagService.Job
    func status(jobID: UUID) async throws -> RemoteTagService.Job
    func cancel(jobID: UUID) async throws -> RemoteTagService.Job
}

extension RemoteTagService: ReviewedDeletionService {}

/// An explicitly enabled helper adds reviewed album deletion to a read-only provider.
/// The original drive remains responsible for playback, inspection and ordinary reads.
nonisolated struct HelperDeletionDrive: RemoteDeletionDrive {
    let base: any RemoteFileDrive
    let configuration: TagServiceConfiguration
    let service: any ReviewedDeletionService
    var id: String { base.id }
    var displayName: String { base.displayName }
    var capabilities: RemoteCapabilities { [.read, .ranges, .delete] }

    private struct Witness: Codable {
        let mapping: String
        let expected: RemoteTagService.Expected
    }

    func roots() async throws -> [RemoteEntry] { try await base.roots() }
    func list(_ path: String) async throws -> [RemoteEntry] { try await base.list(path) }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { try await base.read(path, range: range) }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { try await base.download(path, maxBytes: maxBytes) }
    func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws {
        try await base.downloadFile(path, to: destination, maxBytes: maxBytes)
    }
    func streamURL(for path: String) -> URL? { base.streamURL(for: path) }
    func info(_ path: String) async throws -> RemoteEntry { try await base.info(path) }

    func inspectionSnapshot(_ path: String) async throws -> any RemoteInspectionSnapshot {
        let entry = try await reviewDeletion(path)
        let expected = try decodedWitness(entry).expected
        return HelperInspectionSnapshot(entry: entry, path: try configuration.relativePath(path), expected: expected, service: service)
    }

    private func decodedWitness(_ entry: RemoteEntry) throws -> Witness {
        guard let version = entry.version, version.hasPrefix("helper-delete-v1:"),
              let data = Data(base64Encoded: String(version.dropFirst("helper-delete-v1:".count))),
              let witness = try? JSONDecoder().decode(Witness.self, from: data),
              witness.mapping == configuration.keychainAccount else { throw RemoteWriteError.changed }
        return witness
    }

    func reviewDeletion(_ path: String) async throws -> RemoteEntry {
        guard configuration.allowsReviewedDeletion == true, configuration.sourceID == base.id else { throw RemoteWriteError.unsupported }
        let relative = try configuration.relativePath(path)
        let review = try await service.reviewDeletion(path: relative)
        let before = try await base.info(path)
        guard review.path == relative, !before.isDirectory, let size = before.size,
              size == review.expected.size, before.modified != nil else { throw RemoteWriteError.changed }
        // Cross-check the explicitly mapped file's contents through both connections.
        // Names and sizes alone can miss a wrong mount; the owner still configures the mapping.
        var hash = SHA256()
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let end = min(size, offset + 1024 * 1024)
            let data = try await base.read(path, range: offset..<end, matching: before)
            guard data.count == Int(end - offset) else { throw RemoteWriteError.changed }
            hash.update(data: data)
            offset = end
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == review.expected.sha256, try await base.info(path).sameVersion(as: before),
              try await service.reviewDeletion(path: relative).expected == review.expected else { throw RemoteWriteError.changed }
        let witness = Witness(mapping: configuration.keychainAccount, expected: review.expected)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return RemoteEntry(path: path, name: before.name, isDirectory: false, size: size, modified: before.modified,
                           version: "helper-delete-v1:" + (try encoder.encode(witness)).base64EncodedString())
    }

    func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws {
        let witness = try decodedWitness(entry)
        guard try await reviewDeletion(entry.path) == entry else { throw RemoteWriteError.changed }
        try Task.checkCancellation()
        guard await authorized() else { throw CancellationError() }
        let path = try configuration.relativePath(entry.path)
        let identifier = UUID()
        // Never replay a lost submission under a new identifier or fall back to raw DELETE.
        // Once submitted, cancellation asks the helper to stop; keep reading its original result.
        var job: RemoteTagService.Job?
        do { job = try await service.submitDeletion(jobID: identifier, files: [.init(path: path, expected: witness.expected)]) }
        catch let error as RemoteTagService.Error {
            switch error {
            case .unauthorized, .invalidEndpoint, .invalidToken, .invalidPath, .invalidRequest: throw error
            default: job = try? await service.status(jobID: identifier)
            }
        } catch { job = try? await service.status(jobID: identifier) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var requestedCancellation = false
        while true {
            if let result = job {
                guard result.jobID == identifier, result.operation == "delete", !result.dryRun,
                      result.files.count == 1, result.files[0].path == path else { throw RemoteWriteError.helperDeletionUnconfirmed(identifier) }
                let file = result.files[0]
                if file.status == .deleted {
                    guard file.before == witness.expected, file.after == nil else { throw RemoteWriteError.helperDeletionUnconfirmed(identifier) }
                    return
                }
                if result.status.isTerminal {
                    if file.status == .cancelled { throw CancellationError() }
                    if file.status == .failed, let error = file.error {
                        throw RemoteTagService.Error.service(code: error.code, message: error.message)
                    }
                    throw RemoteWriteError.helperDeletionUnconfirmed(identifier)
                }
            }
            guard ContinuousClock.now < deadline else {
                // A queued job must not be silently left to start after the UI reports uncertainty.
                // Cancellation is best effort; only the durable original result can prove success.
                if let final = try? await service.cancel(jobID: identifier), final.jobID == identifier,
                   final.operation == "delete", !final.dryRun, final.files.count == 1,
                   final.files[0].path == path, final.files[0].status == .deleted,
                   final.files[0].before == witness.expected, final.files[0].after == nil { return }
                throw RemoteWriteError.helperDeletionUnconfirmed(identifier)
            }
            let stillAuthorized = await authorized()
            if !requestedCancellation && (Task.isCancelled || !stillAuthorized) {
                requestedCancellation = true
                job = try? await service.cancel(jobID: identifier)
            } else {
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { throw RemoteWriteError.helperDeletionUnconfirmed(identifier) }
                job = try? await service.status(jobID: identifier)
            }
        }
    }
}

/// Every returned range is captured during a full-file hash pass on the helper, so
/// the parser never combines bytes from different versions or a separate read path.
private actor HelperInspectionSnapshot: RemoteInspectionSnapshot {
    nonisolated let entry: RemoteEntry
    let path: String
    let expected: RemoteTagService.Expected
    let service: any ReviewedDeletionService
    var closed = false
    init(entry: RemoteEntry, path: String, expected: RemoteTagService.Expected, service: any ReviewedDeletionService) {
        self.entry = entry; self.path = path; self.expected = expected; self.service = service
    }
    func read(_ range: Range<Int64>) async throws -> Data {
        guard !closed else { throw RemoteWriteError.changed }
        let data = try await service.inspectionRead(path: path, expected: expected, range: range)
        guard !closed else { throw RemoteWriteError.changed }
        return data
    }
    func validate() async throws {
        guard !closed, Date().timeIntervalSince1970 - Double(expected.mtimeNs) / 1_000_000_000 >= 3600,
              try await service.reviewDeletion(path: path).expected == expected, !closed else { throw RemoteWriteError.changed }
    }
    func close() { closed = true }
}
