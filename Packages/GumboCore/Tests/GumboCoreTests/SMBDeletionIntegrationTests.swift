#if canImport(CGumboSMB) && os(macOS)
import Foundation
import Testing
import CGumboSMB
import Darwin
@testable import GumboCore

/// Only UUID-named generated files on the disposable loopback Samba share are changed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GUMBO_SMB_LOCAL_FIXTURE"] == "1"))
struct SMBDeletionIntegrationTests {
    private func drive(share: String = "resume-tests") throws -> SMBDrive {
        try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:14450")!, share: share,
                     account: "gumbo-test", password: "fixture-only", sourceID: "deletion-fixture")
    }

    @Test func lostRealDeletionReplyIsUnconfirmedAndNeverReplayed() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "lost-reply-\(UUID()).flac"
        try fixture.write(path, bytes: Data([3, 4, 5]))
        defer { _ = smb2_unlink(fixture.context, path) }
        let proxy = try SMBDeleteReplyProxy()
        let port = try await proxy.start()
        let drive = try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:\(port)")!, share: "resume-tests",
                                 account: "gumbo-test", password: "fixture-only", sourceID: "lost-reply-fixture")
        do {
            let review = try await drive.reviewDeletion("/" + path)
            await #expect(throws: RemoteWriteError.deletionUnconfirmed) {
                try await drive.deleteReviewed(review) { proxy.arm(); return true }
            }
            #expect(proxy.didDropReply)
            // SET_INFO committed; closing the interrupted session removes the file. The API
            // must still report uncertainty rather than infer success from a later missing path.
            let verifier = try self.drive()
            for _ in 0..<100 {
                if (try? await verifier.info("/" + path)) == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await #expect(throws: SMBDriveError.missingPath) { try await verifier.info("/" + path) }
            await verifier.disconnect()
            await proxy.stop()
        } catch { await proxy.stop(); throw error }
        await drive.disconnect()
    }

    @Test func reviewChecksRightsWithoutMutationAndDeletePreservesOtherFiles() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "review-\(UUID()).flac", cover = "cover-\(UUID()).jpg"
        try fixture.write(path, bytes: Data(repeating: 17, count: 4097))
        try fixture.write(cover, bytes: Data([1, 2, 3]))
        defer { _ = smb2_unlink(fixture.context, path); _ = smb2_unlink(fixture.context, cover) }
        let drive = try drive()
        #expect(drive.capabilities.contains(.delete))
        #expect(!drive.capabilities.supportsTagReplacement)
        let review = try await drive.reviewDeletion("/" + path)
        #expect(review.version?.hasPrefix("smb-delete-v1:") == true)
        #expect(try await drive.info("/" + path).size == 4097)
        try await drive.deleteReviewed(review) { true }
        await #expect(throws: SMBDriveError.missingPath) { try await drive.info("/" + path) }
        #expect(try await drive.download("/" + cover, maxBytes: 3) == Data([1, 2, 3]))
        await drive.disconnect()
    }

    @Test func changedSameSizeFileIsKeptAndRequiresNewReview() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "changed-\(UUID()).flac"
        try fixture.write(path, bytes: Data(repeating: 9, count: 2048))
        defer { _ = smb2_unlink(fixture.context, path) }
        let drive = try drive()
        let review = try await drive.reviewDeletion("/" + path)
        try fixture.write(path, bytes: Data(repeating: 12, count: 2048))
        await #expect(throws: RemoteWriteError.changed) { try await drive.deleteReviewed(review) { true } }
        #expect(try await drive.read("/" + path, range: 0..<1) == Data([12]))
        let fresh = try await drive.reviewDeletion("/" + path)
        #expect(fresh.version != review.version)
        try await drive.deleteReviewed(fresh) { true }
        await drive.disconnect()
    }

    @Test func revocationAfterLockedVerificationKeepsFileAndReleasesHandle() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "revoked-\(UUID()).flac"
        try fixture.write(path, bytes: Data([4, 5, 6]))
        defer { _ = smb2_unlink(fixture.context, path) }
        let drive = try drive()
        let review = try await drive.reviewDeletion("/" + path)
        await #expect(throws: CancellationError.self) { try await drive.deleteReviewed(review) { false } }
        #expect(try await drive.download("/" + path, maxBytes: 3) == Data([4, 5, 6]))
        try fixture.write(path, bytes: Data([7, 8, 9]))
        await drive.disconnect()
    }

    @Test func protectedReviewRefusesExistingWriterAndDirectoryAndReadOnlyShare() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "busy-\(UUID()).flac"
        try fixture.write(path, bytes: Data([1, 2, 3]))
        defer { _ = smb2_unlink(fixture.context, path) }
        let drive = try drive()
        let writer = try #require(smb2_open(fixture.context, path, O_WRONLY))
        await #expect(throws: SMBDriveError.fileBusy) { try await drive.reviewDeletion("/" + path) }
        #expect(smb2_close(fixture.context, writer) == 0)
        let valid = try await drive.reviewDeletion("/" + path)
        #expect(valid.size == 3)
        await #expect(throws: (any Error).self) { try await drive.reviewDeletion("/") }
        let readOnly = try self.drive(share: "music")
        await #expect(throws: SMBDriveError.permissionDenied) { try await readOnly.reviewDeletion("/folder/音楽 & #.bin") }
        #expect(try await readOnly.info("/folder/音楽 & #.bin").size == 8193)
        await #expect(throws: (any Error).self) { try await readOnly.reviewDeletion("/folder") }
        await drive.disconnect(); await readOnly.disconnect()
    }

    @Test func finalAuthorityCheckHoldsHandleAgainstOtherWritersAndDeletion() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "lock-delete-\(UUID()).flac"
        try fixture.write(path, bytes: Data([1, 2, 3]))
        defer { _ = smb2_unlink(fixture.context, path) }
        let drive = try drive()
        let review = try await drive.reviewDeletion("/" + path)
        try await drive.deleteReviewed(review) {
            // Use a separate authenticated connection while production code holds its handle.
            do {
                let rival = try WritableSMBFixture(); defer { rival.close() }
                let writer = smb2_open(rival.context, path, O_WRONLY)
                if let writer { _ = smb2_close(rival.context, writer) }
                #expect(writer == nil)
                #expect(smb2_unlink(rival.context, path) < 0)
                #expect(smb2_rename(rival.context, path, path + ".moved") < 0)
            } catch { Issue.record("Could not open competing fixture connection: \(error)") }
            return true
        }
        await #expect(throws: SMBDriveError.missingPath) { try await drive.info("/" + path) }
        await drive.disconnect()
    }
}
#endif
