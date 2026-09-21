import Foundation
import Testing
@testable import GumboCore

/// Opt-in loopback Samba fixture only. No saved account, Keychain item or real NAS is consulted.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GUMBO_SMB_LOCAL_FIXTURE"] == "1"))
struct SMBLocalIntegrationTests {
    @Test(arguments: [SMBSecurityPolicy.encrypted, .signed])
    func authenticatedReadOnlyOperations(_ security: SMBSecurityPolicy) async throws {
        let drive = try fixture(security: security)
        try await drive.connect()
        #expect(try await drive.roots().map(\.path) == ["/"])
        #expect(try await drive.list("/").contains { $0.name == "folder" && $0.isDirectory })
        let path = "/folder/音楽 & #.bin"
        #expect(try await drive.info(path).size == 8193)
        #expect(try await drive.read(path, range: 17..<4099) == Data((17..<4099).map { UInt8($0 % 251) }))
        #expect(try await drive.read(path, range: 8190..<8290) == Data((8190..<8193).map { UInt8($0 % 251) }))
        #expect(try await drive.download(path, maxBytes: 9000).count == 8193)
        await #expect(throws: RemoteDriveError.tooLarge) { try await drive.download(path, maxBytes: 4) }
        #expect(try await drive.download("/empty.bin", maxBytes: 0).isEmpty)
        await withTaskGroup(of: Bool.self) { group in
            for offset in 0..<8 {
                group.addTask { (try? await drive.read(path, range: Int64(offset)..<Int64(offset + 20)).count) == 20 }
            }
            for await success in group { #expect(success) }
        }
        await drive.disconnect()
        #expect(try await drive.read(path, range: 0..<4) == Data([0, 1, 2, 3]))
        await drive.disconnect()
    }

    @Test func wrongPasswordCannotBecomeGuest() async throws {
        let drive = try fixture(password: "wrong-password")
        await #expect(throws: SMBDriveError.authenticationRequired) { try await drive.connect() }
        await drive.disconnect()
    }

    @Test func missingPathMapsToMissingFile() async throws {
        let drive = try fixture()
        await #expect(throws: SMBDriveError.missingPath) { try await drive.info("/not-present") }
        await drive.disconnect()
    }

    @Test func signedSMB2WorksButEncryptionNeverDowngrades() async throws {
        let signed = try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:14451")!, share: "music", account: "gumbo-test",
                                  password: "fixture-only", sourceID: "isolated-smb2", security: .signed)
        try await signed.connect()
        #expect(try await signed.read("/folder/音楽 & #.bin", range: 0..<4) == Data([0, 1, 2, 3]))
        await signed.disconnect()
        let encrypted = try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:14451")!, share: "music", account: "gumbo-test",
                                     password: "fixture-only", sourceID: "isolated-smb2", security: .encrypted)
        await #expect(throws: (any Error).self) { try await encrypted.connect() }
        await encrypted.disconnect()
    }

    @Test func serverGuestMappingIsRejected() async throws {
        let drive = try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:14452")!, share: "music", account: "does-not-exist",
                                 password: "fixture-only", sourceID: "isolated-guest", security: .signed)
        do {
            try await drive.connect()
            Issue.record("A server guest mapping must never grant access")
        } catch let error as SMBDriveError {
            // Samba may itself refuse guest when mandatory signing is negotiated, before the
            // client receives a successful guest session. Both routes must fail closed.
            #expect(error == .securityPolicy || error == .permissionDenied)
        }
        await drive.disconnect()
    }

    private func fixture(password: String = "fixture-only", security: SMBSecurityPolicy = .encrypted) throws -> SMBDrive {
        // Hard-coded loopback prevents these opt-in tests being redirected to a person's NAS.
        try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:14450")!, share: "music", account: "gumbo-test",
                     password: password, sourceID: "isolated-local-smb-fixture", security: security)
    }
}
