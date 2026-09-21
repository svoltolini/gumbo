#if canImport(CGumboSMB) && os(macOS)
import Foundation
import Testing
import CGumboSMB
import Darwin
@testable import GumboCore

/// Mutation is limited to generated UUID files in the disposable container's resume-tests share.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GUMBO_SMB_LOCAL_FIXTURE"] == "1"))
struct SMBResumeIntegrationTests {
    @Test func protectedHandleExcludesWriterAndDeleteButAllowsOtherReaders() throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "lock-\(UUID()).bin"
        let bytes = Data(repeating: 7, count: 4096)
        try fixture.write(path, bytes: bytes); defer { _ = smb2_unlink(fixture.context, path) }
        let reader = try WritableSMBFixture(); defer { reader.close() }
        let existingWriter = try #require(smb2_open(fixture.context, path, O_WRONLY))
        let excluded = gumbo_smb2_open_read_snapshot(reader.context, path)
        if let excluded { _ = smb2_close(reader.context, excluded); Issue.record("Protected open admitted an existing writer") }
        #expect(excluded == nil)
        #expect(smb2_close(fixture.context, existingWriter) == 0)
        let handle = try #require(gumbo_smb2_open_read_snapshot(reader.context, path))
        var data = [UInt8](repeating: 0, count: bytes.count)
        #expect(smb2_pread(reader.context, handle, &data, UInt32(data.count), 0) == Int32(bytes.count))
        #expect(Data(data) == bytes)
        // Positive control: the account could create/write this file before the protected open.
        let denied = smb2_open(fixture.context, path, O_WRONLY)
        if let denied { _ = smb2_close(fixture.context, denied); Issue.record("Protected read admitted another writer") }
        #expect(denied == nil)
        #expect(smb2_unlink(fixture.context, path) < 0)
        let second = try #require(smb2_open(fixture.context, path, O_RDONLY))
        #expect(smb2_close(fixture.context, second) == 0)
        #expect(smb2_close(reader.context, handle) == 0)
        // Releasing the lock permits replacement; no access-denied false positive.
        try fixture.write(path, bytes: Data(repeating: 9, count: 4096))
    }

    @Test func cancelledRealTransferReopensAndVerifiesSavedBytesAgainstChangedFile() async throws {
        let fixture = try WritableSMBFixture(); defer { fixture.close() }
        let path = "resume-\(UUID()).bin"
        let original = Data(repeating: 3, count: 3 * 1024 * 1024 + 19)
        try fixture.write(path, bytes: original); defer { _ = smb2_unlink(fixture.context, path) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboSMBWireResume-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "payload.partial")
        let settings = try SMBConnectionSettings(endpoint: URL(string: "smb://127.0.0.1:14450")!, share: "resume-tests", account: "gumbo-test", security: .encrypted)
        let session = SMBCSession(settings: settings, password: "fixture-only")
        let gate = SMBProgressGate()
        let task = Task { try await session.copyVerified(path, to: file, expectedBytes: Int64(original.count)) { fraction in gate.reached(fraction) } }
        for _ in 0..<500 {
            if gate.hasReached { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasReached)
        let playbackResult = SMBReadResult()
        let playback = Task {
            let bytes = try await session.read(path, range: 0..<10)
            playbackResult.record(bytes)
        }
        // The transfer's progress callback still holds its protected handle and queue. A seek
        // on the ordinary session must complete before that transfer is released or cancelled.
        for _ in 0..<300 {
            if playbackResult.bytes != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(playbackResult.bytes == original.prefix(10))
        task.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await playback.value
        let count = try Data(contentsOf: file).count
        #expect(count > 0 && count < original.count)
        await session.disconnect()
        // Same path/size but different bytes. A new authenticated session must never mix them.
        let changed = Data(repeating: 11, count: original.count)
        try fixture.write(path, bytes: changed)
        let drive = try SMBDrive(endpoint: settings.endpoint, share: "resume-tests", account: "gumbo-test", password: "fixture-only", sourceID: "fixture-resume")
        #expect(try await drive.copyVerified("/" + path, to: file, expectedBytes: Int64(changed.count)) { _ in } == Int64(changed.count))
        #expect(try Data(contentsOf: file) == changed)
        await drive.disconnect()
    }
}

private nonisolated final class SMBReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    var bytes: Data? { lock.withLock { value } }
    func record(_ data: Data) { lock.withLock { value = data } }
}

private nonisolated final class SMBProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reachedFirst = false
    var hasReached: Bool { lock.withLock { reachedFirst } }
    func reached(_ fraction: Double) {
        let first = lock.withLock { if reachedFirst { return false }; reachedFirst = true; return true }
        if first { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
}

nonisolated final class WritableSMBFixture {
    let context: OpaquePointer
    init() throws {
        context = try #require(smb2_init_context())
        smb2_set_timeout(context, 5)
        smb2_set_authentication(context, Int32(SMB2_SEC_NTLMSSP.rawValue))
        smb2_set_user(context, "gumbo-test")
        smb2_set_password(context, "fixture-only")
        gumbo_smb2_require_secure_session(context, 1)
        guard smb2_connect_share(context, "127.0.0.1:14450", "resume-tests", "gumbo-test") == 0 else {
            smb2_destroy_context(context)
            throw SMBDriveError.disconnected
        }
    }
    func close() { smb2_destroy_context(context) }
    func write(_ path: String, bytes: Data) throws {
        let file = try #require(smb2_open(context, path, O_WRONLY | O_CREAT | O_TRUNC))
        defer { _ = smb2_close(context, file) }
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 64 * 1024)
            let count = bytes.subdata(in: offset..<end).withUnsafeBytes { pointer in
                smb2_pwrite(context, file, pointer.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(end - offset), UInt64(offset))
            }
            guard count > 0 else { throw SMBDriveError.invalidResponse }
            offset += Int(count)
        }
    }
}
#endif
