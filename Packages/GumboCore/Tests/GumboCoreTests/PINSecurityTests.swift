import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import GumboCore

/// A PIN record exactly as earlier versions made it: one salted SHA-256 in hex.
func legacyPINRecord(_ pin: String, salt: String = "c2FsdHNhbHRzYWx0c2FsdA==") -> PINRecord {
    PINRecord(salt: salt, hash: SHA256.hash(data: Data((salt + ":" + pin).utf8)).map { String(format: "%02x", $0) }.joined())
}

@Test func newPINsUseASlowSelfDescribingDerivation() {
    let record = PINRecord.make("2468")
    #expect(record.hash.hasPrefix("pbkdf2-sha256$\(PINRecord.iterations)$"))
    #expect(!record.isLegacy)
    #expect(record.matches("2468"))
    #expect(!record.matches("2469"))
    #expect(!record.matches(""))
    #expect(PINRecord.make("2468") != record, "Every PIN gets its own salt")
}

@Test func legacyPINsStillOpenAndUpgradeUnderTheSameSalt() throws {
    let legacy = legacyPINRecord("1234")
    #expect(legacy.isLegacy)
    #expect(legacy.matches("1234"))
    #expect(!legacy.matches("4321"))
    #expect(legacy.upgraded(with: "4321") == nil)
    let upgraded = try #require(legacy.upgraded(with: "1234"))
    #expect(upgraded.salt == legacy.salt)
    #expect(!upgraded.isLegacy)
    #expect(upgraded.matches("1234"))
    #expect(!upgraded.matches("4321"))
    #expect(upgraded.isUpgrade(of: legacy))
    #expect(upgraded.upgraded(with: "1234") == nil, "Already derived the slow way")
    #expect(!PINRecord.make("1234").isUpgrade(of: legacy), "A new salt is a new PIN")
    #expect(!legacy.isUpgrade(of: upgraded))
}

@Test func damagedOrHostilePINRecordsOpenNothing() {
    for hash in ["pbkdf2-sha256$999999999$AAAA", "pbkdf2-sha256$1$AAAA", "pbkdf2-sha256$200000$", "pbkdf2-md5$200000$AAAA",
                 "", CloudSync.encryptedPINMarker, String(repeating: "g", count: 64)] {
        let record = PINRecord(salt: "salt", hash: hash)
        #expect(!record.matches("1234"))
        #expect(!record.isLegacy)
        #expect(record.upgraded(with: "1234") == nil)
    }
}

@Test func wrongPINsWaitLongerAndLongerAfterAFewFreeOnes() throws {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var attempts = PINAttempts()
    for _ in 0..<PINAttempts.freeFailures {
        attempts.recordFailure(now: start)
        #expect(attempts.retryDate(now: start) == nil)
    }
    var previous: TimeInterval = 0
    for _ in 0..<6 {
        attempts.recordFailure(now: start)
        let wait = try #require(attempts.retryDate(now: start)).timeIntervalSince(start)
        #expect(wait >= previous)
        #expect(wait > 0 && wait <= 60 * 60)
        previous = wait
    }
    #expect(previous == 60 * 60)
    #expect(attempts.retryDate(now: start.addingTimeInterval(60 * 60)) == nil)
    // A clock set back does not stretch the wait beyond the policy's own.
    let earlier = start.addingTimeInterval(-24 * 60 * 60)
    #expect(attempts.retryDate(now: earlier) == earlier.addingTimeInterval(60 * 60))
}

@Test func encryptedPINVerifierRoundTripsAndEarlierVersionsSeeOnlyALockedProfile() throws {
    let zone = CKRecordZone.ID(zoneName: "Family", ownerName: CKCurrentUserDefaultName)
    let pin = PINRecord.make("2468")
    let record = CKRecord(recordType: "Profile", recordID: .init(recordName: "p", zoneID: zone))
    CloudSync.writePIN(pin, to: record)
    #expect(record["pinSalt"] as? String == CloudSync.encryptedPINMarker)
    #expect(record["pinHash"] as? String == CloudSync.encryptedPINMarker)
    #expect(record.encryptedValues["pinVerifierSalt"] as? String == pin.salt)
    #expect(record.encryptedValues["pinVerifierHash"] as? String == pin.hash)
    #expect(CloudSync.pin(from: record) == pin)
    // What an earlier version builds from the plain fields: locked, and no PIN opens it.
    let seenByEarlierVersion = PINRecord(salt: try #require(record["pinSalt"] as? String), hash: try #require(record["pinHash"] as? String))
    #expect(!seenByEarlierVersion.matches("2468"))

    CloudSync.writePIN(nil, to: record)
    #expect(record["pinSalt"] as? String == nil && record["pinHash"] as? String == nil)
    #expect(record.encryptedValues["pinVerifierHash"] as? String == nil)
    #expect(CloudSync.pin(from: record) == nil)
}

@Test func profileRecordsFromEarlierVersionsKeepTheirPINs() {
    let zone = CKRecordZone.ID(zoneName: "Family", ownerName: CKCurrentUserDefaultName)
    let legacy = legacyPINRecord("1357")
    let record = CKRecord(recordType: "Profile", recordID: .init(recordName: "p", zoneID: zone))
    record["pinSalt"] = legacy.salt
    record["pinHash"] = legacy.hash
    #expect(CloudSync.pin(from: record) == legacy)

    // An earlier version set a new PIN over a record that also holds an encrypted verifier: its PIN wins.
    record.encryptedValues["pinVerifierSalt"] = "stale"
    record.encryptedValues["pinVerifierHash"] = PINRecord.make("0000").hash
    #expect(CloudSync.pin(from: record) == legacy)
    // ...or removed the PIN.
    record["pinSalt"] = nil
    record["pinHash"] = nil
    #expect(CloudSync.pin(from: record) == nil)

    // Marked as encrypted but unreadable here: locked, never open.
    let marked = CKRecord(recordType: "Profile", recordID: .init(recordName: "q", zoneID: zone))
    marked["pinSalt"] = CloudSync.encryptedPINMarker
    marked["pinHash"] = CloudSync.encryptedPINMarker
    let unreadable = CloudSync.pin(from: marked)
    #expect(unreadable != nil)
    #expect(unreadable?.matches("0000") == false)
}
