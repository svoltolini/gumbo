import CloudKit
import Foundation
import Testing
@testable import GumboCore

@Test func liveCloudWritesRequireMatchingServerRevision() {
    #expect(CloudServices.recordSavePolicy == .ifServerRecordUnchanged)
}

@MainActor
private final class CloudFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-cloud-\(UUID().uuidString)")
    let suite = "gumbo.cloud.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var profiles: ProfileStore
    let persistence: CloudPersistence
    var account: String? = "A"
    /// CloudKit cannot tell which account is signed in (temporarily unavailable or undetermined).
    var identityUnavailable = false
    var suspendIdentity = false
    var heldIdentity: CheckedContinuation<Void, Never>?
    var owners: [String] = []
    var pages: [CloudChangePage] = []
    var requests: [(CloudScope, Data?)] = []
    var modifications: [(CloudScope, [String], [String])] = []
    var savedRecordBatches: [[CKRecord]] = []
    var saveOutcomes: (([CKRecord]) throws -> [CKRecord.ID: Result<CKRecord, any Error>])?
    var duringChanges: (() -> Void)?
    var subscriptions = 0
    var failZoneDiscovery = false
    var pageError: CKError?
    var deletionResults: [String: Result<Void, any Error>] = [:]
    var holdPage: CheckedContinuation<CloudChangePage, any Error>?
    var didRequestHeldPage: CheckedContinuation<Void, Never>?
    var shouldHoldPage = false
    var shouldHoldSave = false
    var heldSave: CheckedContinuation<CloudModifyResult, any Error>?
    var heldSaveResult: CloudModifyResult?
    var didRequestHeldSave: CheckedContinuation<Void, Never>?
    var shouldHoldDecode = false
    var heldDecode: CheckedContinuation<(state: ProfileState, digest: String), any Error>?
    var didRequestHeldDecode: CheckedContinuation<Void, Never>?
    var sync: CloudSync!

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let localPersistence = CloudPersistence(directory: directory.appending(path: "cloud"))
        persistence = localPersistence
        profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults,
            retirementIntentProvider: { try localPersistence.pendingFamilyRetirements() })
        sync = makeSync()
        sync.profiles = profiles
        profiles.sync = sync
    }

    func makeSync() -> CloudSync {
        CloudSync(services: CloudServices(
            identity: {
                if self.suspendIdentity { await withCheckedContinuation { self.heldIdentity = $0 } }
                if self.identityUnavailable { return .unavailable }
                return self.account.map(CloudIdentity.available) ?? .noAccount
            },
            sharedZones: {
                if self.failZoneDiscovery { throw CKError(.networkUnavailable) }
                return self.owners
            },
            createZone: { _ in },
            subscribe: { self.subscriptions += 1 },
            changes: { scope, token in
                self.requests.append((scope, token))
                self.duringChanges?()
                if let error = self.pageError { throw error }
                if self.shouldHoldPage {
                    return try await withCheckedThrowingContinuation { continuation in
                        self.holdPage = continuation
                        self.didRequestHeldPage?.resume()
                        self.didRequestHeldPage = nil
                    }
                }
                return self.pages.isEmpty ? CloudChangePage(records: [], token: token) : self.pages.removeFirst()
            },
            modify: { scope, records, ids in
                self.modifications.append((scope, records.map(\.recordID.recordName), ids.map(\.recordName)))
                self.savedRecordBatches.append(records)
                let result = CloudModifyResult(saved: try self.saveOutcomes?(records) ?? Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success($0)) }),
                                               deleted: Dictionary(uniqueKeysWithValues: ids.map { ($0, self.deletionResults[$0.recordName] ?? .success(())) }))
                if self.shouldHoldSave, !records.isEmpty {
                    return try await withCheckedThrowingContinuation { continuation in
                        self.heldSave = continuation
                        self.heldSaveResult = result
                        self.didRequestHeldSave?.resume()
                        self.didRequestHeldSave = nil
                    }
                }
                return result
            }
        ), persistence: persistence, decodeProfileDocument: { data in
            if self.shouldHoldDecode {
                return try await withCheckedThrowingContinuation { continuation in
                    self.heldDecode = continuation
                    self.didRequestHeldDecode?.resume()
                    self.didRequestHeldDecode = nil
                }
            }
            return try await ProfileCloudPreparation.decode(data)
        })
    }

    func relaunch(restoreProfiles: Bool = false) {
        if restoreProfiles {
            profiles.sync = nil
            profiles.lock()
            let localPersistence = persistence
            profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults,
                retirementIntentProvider: { try localPersistence.pendingFamilyRetirements() })
        }
        sync = makeSync()
        sync.profiles = profiles
        profiles.sync = sync
    }

    func ownerAndMember() throws -> (Profile, Profile) {
        let owner = try #require(profiles.owner)
        #expect(profiles.activate(owner))
        let member = try #require(profiles.create(name: "Member", avatar: .random(), pin: nil))
        return (owner, member)
    }

    func profileRecord(_ id: String, name: String = "Remote", owner: String = CKCurrentUserDefaultName) -> CKRecord {
        let record = CKRecord(recordType: "Profile", recordID: .init(recordName: id, zoneID: .init(zoneName: "Family", ownerName: owner)))
        record["name"] = name
        record["createdAt"] = Date(timeIntervalSince1970: 10)
        record["updatedAt"] = Date(timeIntervalSince1970: 20)
        return record
    }

    /// The Family record as another of the owner's devices would have saved it.
    func familyRecord(_ info: FamilyInfo, updatedAt: Date) -> CKRecord {
        let record = CKRecord(recordType: "Family", recordID: .init(recordName: "family", zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)))
        record["name"] = info.name
        record["serverName"] = info.serverName
        record["serverAccount"] = info.serverAccount
        record["musicPath"] = info.musicPath
        record["address"] = info.address
        record["updatedAt"] = updatedAt
        record["familyAccount"] = info.familyAccount
        record.encryptedValues["familyPassword"] = info.familyPassword
        return record
    }

    var familyUploads: [CKRecord] { savedRecordBatches.flatMap { $0 }.filter { $0.recordType == "Family" } }

    func cleanUp() {
        profiles.sync = nil
        profiles.onDeactivate = nil
        profiles.lock()
        sync.accountChanged()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor func cloudAccountSnapshotsSeparateOwnerMemberCursorsAndSubscriptionsAcrossRelaunch() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.sync.profiles = nil
    fixture.owners = ["family-A"]
    let family = CKRecord(recordType: "Family", recordID: .init(recordName: "family", zoneID: .init(zoneName: "Family", ownerName: "family-A")))
    family["name"] = "Family A"
    family["updatedAt"] = Date(timeIntervalSince1970: 20)
    fixture.pages = [.init(records: [.success(family)], token: Data("cursor-A".utf8))]
    await fixture.sync.refresh(reason: "A")
    #expect(fixture.sync.currentUserRecordName == "A")
    #expect(fixture.sync.membership == .member)
    #expect(fixture.subscriptions == 1)

    fixture.account = nil
    fixture.sync.accountChanged()
    await fixture.sync.refresh(reason: "signed out")
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.sync.status == .noAccount)

    fixture.account = "B"
    fixture.owners = []
    fixture.pages = [.init(records: [], token: Data("cursor-B".utf8))]
    await fixture.sync.refresh(reason: "B")
    #expect(fixture.sync.membership == .owner)
    #expect(fixture.subscriptions == 2)
    #expect(fixture.requests.last?.0.account == "B")
    #expect(fixture.requests.last?.1 == nil)
    let stateB = try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName)
    #expect(stateB.zones[CKCurrentUserDefaultName]?.changeToken == Data("cursor-B".utf8))
    #expect(stateB.zones["family-A"] == nil)
    #expect(stateB.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(stateB.zones[CKCurrentUserDefaultName]?.remoteStamps.isEmpty == true)

    fixture.account = "A"
    fixture.relaunch()
    fixture.sync.profiles = nil
    await fixture.sync.refresh(reason: "A relaunched")
    #expect(fixture.sync.membership == .member)
    #expect(fixture.requests.last?.1 == Data("cursor-A".utf8))
    #expect(fixture.subscriptions == 2)
    let stateA = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(stateA.zones["family-A"]?.systemFields["family"] != nil)
    #expect(stateA.zones["family-A"]?.remoteStamps["family"] == Date(timeIntervalSince1970: 20))
}

@Test @MainActor func cloudDirectAccountChangeDoesNotUploadOrRebindAnotherAccountsProfiles() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    await fixture.sync.refresh(reason: "A")
    #expect(fixture.profiles.active?.userRecordName == "A")
    fixture.modifications = []
    fixture.account = "B" // Deliberately no notification: identity refresh must catch this too.
    await fixture.sync.refresh(reason: "B")
    #expect(fixture.sync.currentUserRecordName == "B")
    #expect(fixture.profiles.isLocked)
    #expect(fixture.modifications.allSatisfy { $0.1.isEmpty })
    #expect(fixture.profiles.profiles.first { $0.id == owner.id }?.userRecordName == "A")
    #expect(try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.isEmpty)
}

/// Without iCloud, every launch and return to the foreground finds no account. That is not an account
/// change: locking would close the profile opened at launch and make the Watch clear its downloads (#219).
@Test @MainActor func cloudRefreshWithoutAnAccountKeepsTheOpenProfileUntilAVerifiedAccountLeaves() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    var deactivations = 0
    fixture.profiles.onDeactivate = { deactivations += 1 }
    fixture.account = nil
    fixture.profiles.openAutomaticallyIfPossible()
    let session = try #require(fixture.profiles.sessionID)
    await fixture.sync.refresh(reason: "launch")
    await fixture.sync.refresh(reason: "foreground")
    #expect(fixture.sync.status == .noAccount)
    #expect(fixture.profiles.sessionID == session)
    #expect(deactivations == 0)

    fixture.account = "A"
    await fixture.sync.refresh(reason: "signed in")
    #expect(fixture.sync.currentUserRecordName == "A")
    #expect(!fixture.profiles.isLocked)
    fixture.account = nil // Deliberately no notification: a verified account that leaves still locks.
    await fixture.sync.refresh(reason: "signed out")
    #expect(fixture.sync.status == .noAccount)
    #expect(fixture.profiles.isLocked)
    #expect(deactivations == 1)
}

@Test @MainActor func cloudAccountChangeDiscardsASuspendedPageBeforeAnyApplication() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.shouldHoldPage = true
    let started = Task { await fixture.sync.refresh(reason: "old account") }
    await withCheckedContinuation { continuation in
        if fixture.holdPage != nil { continuation.resume() }
        else { fixture.didRequestHeldPage = continuation }
    }
    let record = fixture.profileRecord("old-account-profile")
    fixture.sync.accountChanged()
    fixture.account = "B"
    fixture.shouldHoldPage = false
    fixture.holdPage?.resume(returning: .init(records: [.success(record)], token: Data("stale".utf8)))
    fixture.holdPage = nil
    await started.value
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != "old-account-profile" })
    #expect(fixture.sync.currentUserRecordName == nil)
    await fixture.sync.refresh(reason: "new account")
    #expect(fixture.sync.currentUserRecordName == "B")
    #expect(fixture.requests.last?.1 == nil)
}

@Test @MainActor func cloudAccountChangeDuringFailingDecodeDiscardsRemainingRecordsAndDeletions() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (owner, member) = try fixture.ownerAndMember()
    fixture.pages = [.init(records: [], token: Data("before".utf8))]
    await fixture.sync.refresh(reason: "A baseline")
    let zone = CKRecordZone.ID(zoneName: "Family", ownerName: CKCurrentUserDefaultName)
    let stateRecord = CKRecord(recordType: "ProfileState", recordID: .init(recordName: "state-\(owner.id)", zoneID: zone))
    stateRecord["profileID"] = owner.id
    stateRecord["document"] = try ProfileCloudDocument.encode(fixture.profiles.storedState(id: owner.id))
    let oldProfile = fixture.profileRecord("old-page-profile")
    let deletion = CloudChangePage.Deletion(id: .init(recordName: member.id, zoneID: zone), type: "Profile")
    fixture.pages = [.init(records: [.success(stateRecord), .success(oldProfile)], deletions: [deletion], token: Data("stale".utf8))]
    fixture.shouldHoldDecode = true
    let started = Task { await fixture.sync.refresh(reason: "A decoding") }
    await withCheckedContinuation { continuation in
        if fixture.heldDecode != nil { continuation.resume() }
        else { fixture.didRequestHeldDecode = continuation }
    }
    fixture.sync.accountChanged()
    fixture.account = "B"
    fixture.shouldHoldDecode = false
    // Inject an ordinary worker failure after suspension; the document itself is valid.
    fixture.heldDecode?.resume(throwing: CocoaError(.fileReadUnknown))
    fixture.heldDecode = nil
    await started.value
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != oldProfile.recordID.recordName })
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("before".utf8))
    await fixture.sync.refresh(reason: "B after old decode failed")
    let current = try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName)
    #expect(fixture.sync.currentUserRecordName == "B")
    #expect(current.profileIDs.isEmpty)
    #expect(current.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(fixture.requests.last?.1 == nil)
    await fixture.profiles.drainPersistence()
}

@Test @MainActor func cloudOfflineDeletionIsDurableBeforeLocalRemovalAndRetriesBothRecordsAfterRelaunch() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline")
    #expect(!fixture.sync.isActive)
    #expect(fixture.profiles.delete(member))
    #expect(fixture.sync.pendingDeletionCount == 1)
    let snapshot = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == [member.id, "state-\(member.id)"])
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })

    fixture.relaunch(restoreProfiles: true)
    fixture.failZoneDiscovery = false
    await fixture.sync.refresh(reason: "retry")
    #expect(fixture.modifications.contains { Set($0.2) == [member.id, "state-\(member.id)"] })
    #expect(fixture.sync.pendingDeletionCount == 0)
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[member.id] == [])
}

@Test @MainActor func cloudPartialDeletionKeepsOnlyUnacknowledgedWorkAndSuppressesReturnedRecords() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline")
    #expect(fixture.profiles.delete(member))
    fixture.failZoneDiscovery = false
    fixture.deletionResults["state-\(member.id)"] = .failure(CKError(.networkFailure))
    await fixture.sync.refresh(reason: "partial")
    #expect(fixture.sync.pendingDeletionCount == 1)
    var snapshot = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == ["state-\(member.id)"])
    fixture.relaunch()
    fixture.deletionResults = [:]
    fixture.pages = [.init(records: [.success(fixture.profileRecord(member.id))], token: Data("replayed".utf8))]
    await fixture.sync.refresh(reason: "eventual retry")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    snapshot = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == [])
    #expect(fixture.sync.pendingDeletionCount == 0)
}

@Test @MainActor func cloudDeletionIsRefusedWhenItsIntentCannotBeSaved() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline")
    let cloudDirectory = fixture.persistence.directory
    try FileManager.default.removeItem(at: cloudDirectory)
    try Data("storage unavailable".utf8).write(to: cloudDirectory)
    #expect(!fixture.profiles.delete(member))
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    #expect(fixture.sync.pendingDeletionCount == 0)
}

@Test @MainActor func cloudMixedPageKeepsItsOldCursorAndRetriesWithoutANewServerMutation() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, removed) = try fixture.ownerAndMember()
    fixture.pages = [.init(records: [], token: Data("before".utf8))]
    await fixture.sync.refresh(reason: "baseline")
    let first = fixture.profileRecord("first")
    let second = fixture.profileRecord("second")
    let deletion = CloudChangePage.Deletion(id: .init(recordName: removed.id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")
    fixture.pages = [.init(records: [.success(first), .failure(CKError(.networkFailure))], deletions: [deletion], token: Data("after".utf8), moreComing: true)]
    let requestCount = fixture.requests.count
    await fixture.sync.refresh(reason: "mixed page")
    #expect(fixture.requests.count == requestCount + 1) // Does not request moreComing after a failed entry.
    #expect(fixture.profiles.profiles.contains { $0.id == "first" })
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != removed.id })
    #expect(!fixture.sync.isActive)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("before".utf8))
    fixture.relaunch()
    fixture.pages = [
        .init(records: [.success(first), .success(second)], deletions: [deletion], token: Data("after".utf8), moreComing: true),
        .init(records: [], token: Data("end".utf8))
    ]
    await fixture.sync.refresh(reason: "same changes replayed")
    #expect(fixture.requests[fixture.requests.count - 2].1 == Data("before".utf8))
    #expect(fixture.profiles.profiles.filter { $0.id == "first" }.count == 1)
    #expect(fixture.profiles.profiles.contains { $0.id == "second" })
    #expect(fixture.sync.isActive)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("end".utf8))
}

@Test @MainActor func cloudApplicationFailuresDoNotAcknowledgeAPage() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let invalid = CKRecord(recordType: "Profile", recordID: .init(recordName: "incomplete", zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)))
    fixture.pages = [.init(records: [.success(invalid)], token: Data("must-not-ack".utf8))]
    await fixture.sync.refresh(reason: "incomplete record")
    #expect(!fixture.sync.isActive)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == nil)
    let profileURL = fixture.directory.appending(path: "profiles/profiles.json")
    try FileManager.default.removeItem(at: profileURL)
    try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
    fixture.pages = [.init(records: [.success(fixture.profileRecord("valid"))], token: Data("also-not-ack".utf8))]
    await fixture.sync.refresh(reason: "local write failed")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != "valid" })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == nil)
    try FileManager.default.removeItem(at: profileURL)
    fixture.pages = [.init(records: [.success(fixture.profileRecord("valid"))], token: Data("saved".utf8))]
    await fixture.sync.refresh(reason: "storage recovered")
    #expect(fixture.profiles.profiles.contains { $0.id == "valid" })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("saved".utf8))
}

@Test @MainActor func cloudOfflineRelaunchCanQueueDeletionWithoutAssumingASignedInIdentity() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (owner, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "first verified account, offline sync")
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.activate(owner))
    #expect(fixture.profiles.delete(member))
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[member.id] == [member.id, "state-\(member.id)"])
    fixture.account = "B"
    fixture.failZoneDiscovery = false
    await fixture.sync.refresh(reason: "different account")
    #expect(fixture.modifications.allSatisfy { $0.2.isEmpty })
    fixture.account = "A"
    await fixture.sync.refresh(reason: "original account returns")
    #expect(fixture.modifications.contains { $0.0.account == "A" && Set($0.2) == [member.id, "state-\(member.id)"] })
}

@Test @MainActor func cloudUnverifiedDeletionRefusesAmbiguousAccountOwnership() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (owner, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "initial account")
    var other = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    other.account = "B"
    try fixture.persistence.save(other)
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.activate(owner))
    #expect(!fixture.profiles.delete(member))
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
}

@Test @MainActor func cloudUnassociatedLocalProfilesCanStillBeDeletedWithoutICloud() throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.delete(member))
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(!FileManager.default.fileExists(atPath: fixture.persistence.directory.path))
}

@Test @MainActor func cloudAccountChangeDiscardsASuspendedSaveAndItsSystemFields() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.shouldHoldSave = true
    let started = Task { await fixture.sync.refresh(reason: "A upload") }
    await withCheckedContinuation { continuation in
        if fixture.heldSave != nil { continuation.resume() }
        else { fixture.didRequestHeldSave = continuation }
    }
    fixture.sync.accountChanged()
    fixture.account = "B"
    fixture.shouldHoldSave = false
    fixture.heldSave?.resume(returning: try #require(fixture.heldSaveResult))
    fixture.heldSave = nil
    await started.value
    let old = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(old.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(old.zones[CKCurrentUserDefaultName]?.remoteStamps.isEmpty == true)
    await fixture.sync.refresh(reason: "B after old upload")
    let current = try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName)
    #expect(current.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(current.zones[CKCurrentUserDefaultName]?.remoteStamps.isEmpty == true)
}

@Test @MainActor func cloudRemoteLastProfileDeletionCreatesADifferentUsableProfileOnlyAfterAPullCompletes() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let old = try #require(fixture.profiles.owner)
    let deletion = CloudChangePage.Deletion(id: .init(recordName: old.id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")
    fixture.pages = [.init(records: [], deletions: [deletion], token: Data("deleted".utf8))]
    await fixture.sync.refresh(reason: "removed elsewhere")
    #expect(fixture.profiles.profiles.count == 1)
    #expect(fixture.profiles.active?.id != old.id)
    #expect(!fixture.profiles.isLocked)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[old.id] == [])
}

@Test @MainActor func cloudProfileCreatedAfterOfflineRelaunchRetainsItsAccountAndUploadsThenDeletes() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    await fixture.sync.refresh(reason: "verified account")
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.activate(owner))
    let created = try #require(fixture.profiles.create(name: "Offline member", avatar: .random(), pin: nil))
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(created.id))
    fixture.relaunch(restoreProfiles: true)
    fixture.modifications = []
    await fixture.sync.refresh(reason: "reconnected")
    #expect(fixture.modifications.contains { $0.0.account == "A" && $0.1.contains(created.id) })
    #expect(fixture.profiles.profiles.contains { $0.id == created.id }) // Survives stand-in cleanup.
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline again")
    #expect(fixture.profiles.activate(owner))
    #expect(fixture.profiles.delete(created))
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[created.id] == [created.id, "state-\(created.id)"])
}

@Test @MainActor func cloudLocalFirstLaunchProfilesAreAdoptedAndIntentionalMembersSurviveCleanup() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    #expect(!FileManager.default.fileExists(atPath: fixture.persistence.directory.path))
    await fixture.sync.refresh(reason: "first account")
    await fixture.sync.refresh(reason: "subsequent cleanup")
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(member.id))
    #expect(fixture.modifications.contains { $0.1.contains(member.id) })
}

@Test @MainActor func cloudOfflineCreationRefusesAnUnwritableAssociationBeforeAddingAProfile() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "known account")
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.activate(owner))
    try FileManager.default.removeItem(at: fixture.persistence.directory)
    try Data("unavailable".utf8).write(to: fixture.persistence.directory)
    #expect(fixture.profiles.create(name: "Cannot save", avatar: .random(), pin: nil) == nil)
    #expect(fixture.profiles.profiles.count == 1)
}

@Test @MainActor func cloudJoiningAnotherAccountsFamilyDoesNotChangeTheFirstAccountsRolesOrRevisions() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    await fixture.sync.refresh(reason: "A owner")
    let original = try #require(fixture.profiles.profiles.first { $0.id == owner.id })
    fixture.account = "B"
    fixture.owners = ["B-shared-family"]
    await fixture.sync.refresh(reason: "B joins shared family")
    #expect(fixture.sync.membership == .member)
    #expect(fixture.profiles.profiles.first { $0.id == original.id } == original)
    fixture.account = "A"
    fixture.owners = []
    await fixture.sync.refresh(reason: "A returns")
    #expect(fixture.sync.membership == .owner)
    #expect(fixture.profiles.profiles.first { $0.id == original.id } == original)
}

@Test @MainActor func cloudDurableTombstonesReconcileLocalFailuresAndAlreadyAcknowledgedDeletionAfterRelaunch() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "known account")
    let url = fixture.directory.appending(path: "profiles/profiles.json")
    let before = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    #expect(!fixture.profiles.delete(member))
    #expect(fixture.sync.pendingDeletionCount == 1)
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    try FileManager.default.removeItem(at: url)
    try before.write(to: url, options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    fixture.failZoneDiscovery = false
    fixture.deletionResults[member.id] = .failure(CKError(.unknownItem))
    fixture.deletionResults["state-\(member.id)"] = .failure(CKError(.unknownItem))
    await fixture.sync.refresh(reason: "resume intent")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(fixture.sync.pendingDeletionCount == 0)
    // A saved local list from before the deletion must converge even after both remote acknowledgements.
    try before.write(to: url, options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    fixture.modifications = []
    await fixture.sync.refresh(reason: "acknowledged deletion, stale local list")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(fixture.modifications.allSatisfy { $0.2.isEmpty })
}

@Test @MainActor func cloudLastProfileRecoverySurvivesAnIncompletePageAndRelaunchWithoutLegacyData() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let old = try #require(fixture.profiles.owner)
    fixture.defaults.set(["old-legacy-song"], forKey: "favourites.legacy-drive")
    let deletion = CloudChangePage.Deletion(id: .init(recordName: old.id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")
    fixture.pages = [.init(records: [.failure(CKError(.networkFailure))], deletions: [deletion], token: Data("not-acknowledged".utf8), moreComing: true)]
    await fixture.sync.refresh(reason: "incomplete deletion page")
    let replacement = try #require(fixture.profiles.owner)
    #expect(replacement.id != old.id)
    #expect(replacement.localOrigin == .recovery(account: "A"))
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.owner?.id == replacement.id)
    #expect(fixture.profiles.storedState(id: replacement.id).libraries.isEmpty)
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "identity verified, still offline")
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    fixture.account = "B"
    fixture.failZoneDiscovery = false
    await fixture.sync.refresh(reason: "another account")
    #expect(try !fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
}

@Test @MainActor func cloudInitializedEmptyProfileFileDoesNotRunLegacyMigrationAgain() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.defaults.set(["old-legacy-song"], forKey: "favourites.legacy-drive")
    try Data("[]".utf8).write(to: fixture.directory.appending(path: "profiles/profiles.json"), options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    #expect(replacement.localOrigin == .recovery(account: nil))
    #expect(fixture.profiles.storedState(id: replacement.id).libraries.isEmpty)
    await fixture.sync.refresh(reason: "verify recovery account")
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
}

@Test @MainActor func cloudMissingSharedZoneExposesInvitationRecoveryWithoutChangingMembership() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.owners = ["shared-family"]
    fixture.pageError = CKError(.zoneNotFound)
    await fixture.sync.refresh(reason: "missing family")
    #expect(fixture.sync.needsFamilyInvitation)
    #expect(!fixture.sync.isActive)
    #expect(fixture.sync.membership == .member)
    fixture.pageError = nil
    await fixture.sync.refresh(reason: "family restored")
    #expect(!fixture.sync.needsFamilyInvitation)
    #expect(fixture.sync.membership == .member)
}

@Test @MainActor func cloudMemberLastProfileRecoveryRetainsTheMemberRole() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let old = try #require(fixture.profiles.owner)
    fixture.owners = ["shared-family"]
    let deletion = CloudChangePage.Deletion(id: .init(recordName: old.id, zoneID: .init(zoneName: "Family", ownerName: "shared-family")), type: "Profile")
    fixture.pages = [.init(records: [], deletions: [deletion], token: Data("member-deleted".utf8))]
    await fixture.sync.refresh(reason: "member recovery")
    let replacement = try #require(fixture.profiles.profiles.first)
    #expect(replacement.id != old.id)
    #expect(replacement.role == .member)
    #expect(!fixture.profiles.canManageProfiles)
}

@Test @MainActor func cloudProfileRoundTripPreservesLocalOriginAndProtectsImportedRealProfiles() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    await fixture.sync.refresh(reason: "initial upload")
    fixture.relaunch(restoreProfiles: true)
    let returned = fixture.profileRecord(member.id, name: member.name)
    returned["createdAt"] = member.createdAt
    returned["updatedAt"] = member.updatedAt.addingTimeInterval(0.1)
    let imported = fixture.profileRecord("real-member-from-another-device")
    imported["createdAt"] = Date(timeIntervalSince1970: 20)
    fixture.pages = [.init(records: [.success(returned), .success(imported)], token: Data("round-trip".utf8))]
    await fixture.sync.refresh(reason: "ordinary newer server copies")
    #expect(fixture.profiles.profiles.first { $0.id == member.id }?.localOrigin == .created)
    #expect(fixture.profiles.profiles.first { $0.id == imported.recordID.recordName }?.localOrigin == .created)
    #expect(fixture.sync.pendingDeletionCount == 0)
}

@Test @MainActor func cloudInitiallyUnassignedRecoveryBindsOnceAndCannotUploadAnotherAccountsEdits() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    try Data("[]".utf8).write(to: fixture.directory.appending(path: "profiles/profiles.json"), options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    #expect(replacement.localOrigin == .recovery(account: nil))
    await fixture.sync.refresh(reason: "A adopts the fresh recovery")
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
    #expect(fixture.profiles.activate(replacement))
    fixture.profiles.updateLibrary("A-library") { $0.favourites = ["A-song"] }
    fixture.profiles.flushSave()
    fixture.sync.accountChanged() // End the old process's queued work before the relaunch fixture.
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
    fixture.account = "B"
    fixture.modifications = []
    await fixture.sync.refresh(reason: "B must not adopt A's recovery")
    #expect(try !fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    #expect(fixture.modifications.allSatisfy { !$0.1.contains(replacement.id) && !$0.1.contains("state-\(replacement.id)") })
    #expect(fixture.profiles.storedState(id: replacement.id).libraries["A-library"]?.favourites == ["A-song"])
}

@Test @MainActor func cloudRecoveryAssociationWaitsForItsLocalAccountBindingToPersist() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let url = fixture.directory.appending(path: "profiles/profiles.json")
    try Data("[]".utf8).write(to: url, options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    let before = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    await fixture.sync.refresh(reason: "local recovery binding cannot persist")
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: nil))
    #expect(try !fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    #expect(fixture.modifications.isEmpty)
    try FileManager.default.removeItem(at: url)
    try before.write(to: url, options: .atomic)
    await fixture.sync.refresh(reason: "binding storage recovered")
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
}

@Test @MainActor func cloudExistingRecoveryAssociationPreventsAdoptionByAnotherAccountWhileStillUnbound() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    try Data("[]".utf8).write(to: fixture.directory.appending(path: "profiles/profiles.json"), options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    var prior = CloudAccountState(account: "A", zoneOwner: CKCurrentUserDefaultName)
    prior.profileIDs.insert(replacement.id)
    try fixture.persistence.save(prior)
    fixture.account = "B"
    await fixture.sync.refresh(reason: "existing association belongs to A")
    #expect(try !fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    #expect(fixture.modifications.isEmpty)
    fixture.account = "A"
    await fixture.sync.refresh(reason: "A completes the durable local binding")
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
}

@Test @MainActor func leavingFamilyRetiresPeerProfilesBeforePrivateUploadsAndAcrossRelaunch() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.owners = ["family-owner"]
    let mine = f.profileRecord("mine", owner: "family-owner"); mine["userRecordName"] = "A"
    let peer = f.profileRecord("peer", owner: "family-owner"); peer["userRecordName"] = "someone-else"
    f.pages = [.init(records: [.success(mine), .success(peer)], token: nil)]
    await f.sync.refresh(reason: "joined family")
    #expect(f.profiles.profiles.contains { $0.id == "peer" })
    f.owners = []
    f.modifications = []
    try await f.sync.stopSharing()
    #expect(f.sync.membership == .owner)
    #expect(f.profiles.profiles.first { $0.id == "mine" }?.role == .owner)
    #expect(f.profiles.profiles.contains { $0.id == "mine" })
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    #expect(!f.modifications.contains { $0.1.contains("peer") || $0.1.contains("state-peer") })
    f.relaunch(restoreProfiles: true)
    await f.sync.refresh(reason: "relaunch")
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    #expect(!f.modifications.contains { $0.0.isMember == false && ($0.1.contains("peer") || $0.1.contains("state-peer")) })
}

@Test @MainActor func replacingFamilyRetiresOldPeersWithoutChangingOtherAccountProfiles() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    await f.sync.refresh(reason: "account A")
    let accountA = try #require(f.profiles.active)
    f.profiles.updateSettings { $0.shuffle = true }
    f.profiles.lock()
    await f.profiles.drainPersistence()
    let stateA = f.profiles.storedState(id: accountA.id)
    let photoA = f.directory.appending(path: "profiles/\(accountA.id)-photo.jpg")
    try Data("account A photo".utf8).write(to: photoA)
    f.account = "B"
    f.sync.accountChanged()
    f.owners = ["family-one"]
    let mine = f.profileRecord("mine", owner: "family-one"); mine["userRecordName"] = "B"
    let peer = f.profileRecord("peer", owner: "family-one"); peer["userRecordName"] = "other"
    f.pages = [.init(records: [.success(mine), .success(peer)], token: nil)]
    await f.sync.refresh(reason: "first family")
    f.modifications = []
    try f.sync.join(zoneOwnerName: "family-two")
    await f.sync.refresh(reason: "next family")
    #expect(f.profiles.profiles.contains { $0.id == "mine" })
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    #expect(!f.modifications.contains { $0.1.contains("peer") || $0.1.contains("state-peer") })
    #expect(f.profiles.profiles.first { $0.id == accountA.id } == accountA)
    #expect(f.profiles.storedState(id: accountA.id) == stateA)
    #expect(try Data(contentsOf: photoA) == Data("account A photo".utf8))
    #expect(!f.modifications.contains { $0.1.contains(accountA.id) || $0.1.contains("state-" + accountA.id) })

}

@Test @MainActor func failedFamilyRetirementRemainsExcludedAcrossRelaunchAndRetriesBeforeUploads() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.owners = ["family-owner"]
    let mine = f.profileRecord("mine", owner: "family-owner"); mine["userRecordName"] = "A"
    let peer = f.profileRecord("peer", owner: "family-owner"); peer["userRecordName"] = "other"
    f.pages = [.init(records: [.success(mine), .success(peer)], token: nil)]
    await f.sync.refresh(reason: "joined")
    let index = f.directory.appending(path: "profiles/profiles.json")
    let saved = try Data(contentsOf: index)
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    f.owners = []
    do { try await f.sync.stopSharing(); Issue.record("Failed local retirement must be reported") } catch {}
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    let state = try f.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(!state.profileIDs.contains("peer"))
    #expect(state.retiredFamilyProfileIDs?.contains("peer") == true)
    try FileManager.default.removeItem(at: index)
    try saved.write(to: index) // the old index survived a failed replacement
    f.relaunch(restoreProfiles: true)
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    f.modifications = []
    await f.sync.refresh(reason: "retry cleanup")
    #expect(!f.modifications.contains { $0.1.contains("peer") || $0.1.contains("state-peer") })
    #expect(try f.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).retiredFamilyProfileIDs == nil)
}

@Test @MainActor func markerFailureRevokesActivePeerAndOfflineRelaunchReadsCloudRetirementIntent() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.owners = ["family-one"]
    let mine = f.profileRecord("mine", owner: "family-one"); mine["userRecordName"] = "A"
    let peer = f.profileRecord("peer", owner: "family-one"); peer["userRecordName"] = "other"
    f.pages = [.init(records: [.success(mine), .success(peer)], token: nil)]
    await f.sync.refresh(reason: "first family")
    #expect(f.profiles.activate(try #require(f.profiles.profiles.first { $0.id == "peer" })))
    let marker = f.directory.appending(path: "profiles/family-retirement.json")
    try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
    do { try f.sync.join(zoneOwnerName: "family-two"); Issue.record("Marker failure must be reported") } catch {}
    #expect(f.profiles.isLocked)
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    // Model inability to create a marker: it is absent at the next offline launch.
    try FileManager.default.removeItem(at: marker)
    f.relaunch(restoreProfiles: true)
    #expect(!f.profiles.profiles.contains { $0.id == "peer" })
    #expect(f.profiles.profiles.contains { $0.id == "mine" })
    #expect(f.requests.last?.0.owner == "family-one", "No network refresh is needed to enforce the local journal")
}

@Test @MainActor func queuedAndSuspendedShareActionsCannotBorrowANewProfileSession() async throws {
    for createsShare in [false, true] {
        for transition in ["lock", "reopen", "switch"] {
            let f = try CloudFixture()
            let owner = try #require(f.profiles.owner)
            #expect(f.profiles.activate(owner))
            let other = try #require(f.profiles.create(name: "Other", avatar: .random(), pin: nil))
            await f.sync.refresh(reason: "ready")
            let authorization = try #require(f.sync.sharingAuthorization())
            f.suspendIdentity = true
            let task = Task { () -> Bool in
                do {
                    if createsShare { _ = try await f.sync.share(authorization: authorization) }
                    else { try await f.sync.stopSharing(authorization: authorization) }
                    return true
                } catch { return false }
            }
            for _ in 0..<200 where f.heldIdentity == nil { try await Task.sleep(for: .milliseconds(2)) }
            #expect(f.heldIdentity != nil)
            f.profiles.lock()
            if transition == "reopen" { #expect(f.profiles.activate(owner)) }
            if transition == "switch" { #expect(f.profiles.activate(other)) }
            f.suspendIdentity = false
            f.heldIdentity?.resume(); f.heldIdentity = nil
            #expect(await task.value == false)
            #expect(!f.modifications.contains { $0.1.contains(CKRecordNameZoneWideShare) || $0.2.contains(CKRecordNameZoneWideShare) })
            do { try await f.sync.stopSharing(authorization: authorization); Issue.record("Queued action must reject its stale session") } catch {}
            f.cleanUp()
        }
    }
}

/// Reproduce an installed app retaining a cloud revision after its server record is gone.
@MainActor
private func seededMissingRecordFixture() async throws -> (CloudFixture, String) {
    let fixture = try CloudFixture()
    fixture.profiles.sync = nil // Explicit refreshes keep debounce uploads out of these scenarios.
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    fixture.profiles.updateLibrary("nas") { $0.favourites = ["saved-song"] }
    await fixture.sync.refresh(reason: "previous cloud record")
    var edited = try #require(fixture.profiles.profiles.first { $0.id == owner.id })
    edited.name = "Samuel"
    #expect(fixture.profiles.update(edited))
    fixture.modifications = []
    fixture.savedRecordBatches = []
    fixture.requests = []
    return (fixture, owner.id)
}

@Test @MainActor func cloudMissingRecordRecoversLatestProfileAndPreviouslyAcknowledgedDocument() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var rejected = false
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordID.recordName == id, !rejected {
                rejected = true
                var latest = try #require(fixture.profiles.profiles.first { $0.id == id })
                latest.name = "Samuel Updated"
                #expect(fixture.profiles.update(latest))
                fixture.profiles.updateLibrary("nas") { $0.favourites.append("new-song") }
                results[record.recordID] = .failure(CKError(.unknownItem))
            } else {
                if record.recordID.recordName == id {
                    let persisted = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
                    #expect(persisted.zones[CKCurrentUserDefaultName]?.systemFields[id] == nil)
                    #expect(persisted.zones[CKCurrentUserDefaultName]?.remoteStamps[id] == nil)
                }
                results[record.recordID] = .success(record)
            }
        }
        return results
    }
    await fixture.sync.refresh(reason: "missing server record")
    if case .synced = fixture.sync.status {} else { Issue.record("Missing record should recover in the same refresh: \(fixture.sync.status)") }
    #expect(fixture.requests.count == 2) // Initial pull, then deletion/conflict reconciliation.
    let retry = try #require(fixture.savedRecordBatches.last)
    #expect(retry.first { $0.recordID.recordName == id }?["name"] as? String == "Samuel Updated")
    let data = try #require(retry.first { $0.recordType == "ProfileState" }?["document"] as? Data)
    #expect(try ProfileCloudDocument.decode(data).libraries["nas"]?.favourites == ["saved-song", "new-song"])
    #expect(fixture.profiles.profiles.contains { $0.id == id })
}

@Test @MainActor func cloudMissingRecordRepairSurvivesFailedRetryAndRelaunch() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var attempts = 0
    fixture.saveOutcomes = { records in
        attempts += 1
        if attempts > 1 { throw CKError(.networkFailure) }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .failure(CKError(.unknownItem))) })
    }
    await fixture.sync.refresh(reason: "repair then go offline")
    #expect(attempts == 2)
    let persisted = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(persisted.zones[CKCurrentUserDefaultName]?.systemFields[id] == nil)
    #expect(persisted.zones[CKCurrentUserDefaultName]?.remoteStateDigests?["state-\(id)"] == nil)
    #expect(persisted.profileIDs.contains(id))
    fixture.saveOutcomes = nil
    fixture.relaunch(restoreProfiles: true)
    fixture.profiles.sync = nil
    await fixture.sync.refresh(reason: "retry after relaunch")
    if case .synced = fixture.sync.status {} else { Issue.record("The repaired metadata should survive relaunch") }
    #expect(fixture.savedRecordBatches.last?.contains { $0.recordID.recordName == id } == true)
    #expect(fixture.savedRecordBatches.last?.contains { $0.recordID.recordName == "state-\(id)" } == true)
    #expect(fixture.profiles.storedState(id: id).libraries["nas"]?.favourites == ["saved-song"])
}

@Test @MainActor func cloudMissingRecordRecoveryDoesNotResurrectARemotelyDeletedProfile() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    fixture.saveOutcomes = { records in
        fixture.pages = [.init(records: [], deletions: [.init(id: .init(recordName: id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")])]
        return Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .failure(CKError(.unknownItem))) })
    }
    await fixture.sync.refresh(reason: "another device deleted the profile")
    #expect(!fixture.profiles.profiles.contains { $0.id == id })
    #expect(fixture.savedRecordBatches.count == 1)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[id] != nil)
}

@Test @MainActor func cloudMissingRecordRecoveryStopsWhenAccountChangesDuringPull() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    fixture.saveOutcomes = { records in
        fixture.duringChanges = {
            fixture.account = "B"
            fixture.sync.accountChanged()
            fixture.duringChanges = nil
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .failure(CKError(.unknownItem))) })
    }
    await fixture.sync.refresh(reason: "account changes during repair")
    #expect(fixture.savedRecordBatches.count == 1)
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.isLocked)
    #expect(!fixture.persistence.hasSnapshot(account: "B"))
}

@Test @MainActor func cloudMissingRecordRetryIsBoundedAndUsesFriendlyError() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    fixture.saveOutcomes = { records in
        Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .failure(CKError(.unknownItem, userInfo: [NSLocalizedDescriptionKey: "recordChangeTag specified, but record not found"]))) })
    }
    await fixture.sync.refresh(reason: "persistent missing record")
    #expect(fixture.savedRecordBatches.count == 3) // Profile and document each have one repair attempt.
    #expect(fixture.savedRecordBatches.flatMap { $0 }.filter { $0.recordID.recordName == id }.count == 2)
    if case .failed(let text) = fixture.sync.status {
        #expect(text.contains("still saved on this device"))
        #expect(!text.contains("recordChangeTag"))
    } else { Issue.record("An unrecoverable save must stay visible") }
    #expect(fixture.profiles.profiles.contains { $0.id == id })
}

@Test @MainActor func cloudNetworkSaveFailureDoesNotDiscardValidMetadata() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    let before = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    fixture.saveOutcomes = { records in
        Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .failure(CKError(.networkFailure))) })
    }
    await fixture.sync.refresh(reason: "ordinary connection loss")
    let after = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(after.zones[CKCurrentUserDefaultName]?.systemFields[id] == before.zones[CKCurrentUserDefaultName]?.systemFields[id])
    #expect(fixture.requests.count == 1)
    #expect(fixture.savedRecordBatches.count == 1)
}

@Test @MainActor func cloudMissingRecordRecoveryUsesNewerProfileReturnedByThePull() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var rejected = false
    fixture.saveOutcomes = { records in
        if rejected { return Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success($0)) }) }
        rejected = true
        let remote = fixture.profileRecord(id, name: "Newer cloud name")
        remote["updatedAt"] = Date.now.addingTimeInterval(100)
        remote["role"] = Profile.Role.owner.rawValue
        remote["userRecordName"] = "A"
        fixture.pages = [.init(records: [.success(remote)])]
        return Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .failure(CKError(.unknownItem))) })
    }
    await fixture.sync.refresh(reason: "record returned during recovery")
    #expect(fixture.savedRecordBatches.last?.first { $0.recordID.recordName == id }?["name"] as? String == "Newer cloud name")
    #expect(fixture.profiles.profiles.first { $0.id == id }?.name == "Newer cloud name")
}

@Test @MainActor func cloudProfileRevisionConflictsHaveABoundedRetryBudget() async throws {
    let (fixture, id) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    fixture.saveOutcomes = { records in
        Dictionary(uniqueKeysWithValues: records.map { record in
            let server = fixture.profileRecord(id)
            return (record.recordID, .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])))
        })
    }
    await fixture.sync.refresh(reason: "persistent profile conflicts")
    #expect(fixture.savedRecordBatches.count == 4)
    if case .failed = fixture.sync.status {} else { Issue.record("Repeated profile conflicts should remain visible") }
    #expect(fixture.profiles.profiles.first { $0.id == id }?.name == "Samuel")
}

@Test @MainActor func cloudFamilyRetryPreservesEncryptedAndClearedFields() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var info = FamilyInfo(name: "Family", serverName: "nas.example", serverAccount: "owner", musicPath: nil, updatedAt: .now)
    info.familyAccount = "listener"
    info.familyPassword = "new-test-password"
    fixture.sync.familyInfoProvider = { info }
    var rejected = false
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordType == "Family", !rejected {
                rejected = true
                let server = CKRecord(recordType: "Family", recordID: record.recordID)
                server["updatedAt"] = Date.distantPast
                server["musicPath"] = "/old-path"
                server.encryptedValues["familyPassword"] = "old-test-password"
                results[record.recordID] = .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
            } else { results[record.recordID] = .success(record) }
        }
        return results
    }
    await fixture.sync.refresh(reason: "family field conflict")
    let record = try #require(fixture.savedRecordBatches.last?.first { $0.recordType == "Family" })
    #expect(record.encryptedValues["familyPassword"] as? String == "new-test-password")
    #expect(record["musicPath"] == nil)
    if case .synced = fixture.sync.status {} else { Issue.record("The family record should reconcile") }
}

// MARK: - iCloud account availability (#221)

@Test @MainActor func cloudWithoutAnICloudAccountKeepsTheOpenProfilePlaying() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.account = nil
    var deactivations = 0
    f.profiles.onDeactivate = { deactivations += 1 }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    await f.sync.refresh(reason: "launch")
    await f.sync.refresh(reason: "foreground")
    #expect(!f.profiles.isLocked)
    #expect(deactivations == 0)
    #expect(f.sync.status == .noAccount)
    #expect(f.sync.currentUserRecordName == nil)
    #expect(f.requests.isEmpty)
    #expect(f.modifications.isEmpty)
}

@Test @MainActor func cloudSignOutAfterAVerifiedAccountLocksOnceThenLeavesTheProfileOpen() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    let owner = try #require(f.profiles.owner)
    #expect(f.profiles.activate(owner))
    await f.sync.refresh(reason: "signed in")
    #expect(f.sync.isActive)
    var deactivations = 0
    f.profiles.onDeactivate = { deactivations += 1 }
    f.account = nil // Signed out while the app was suspended: no notification arrived.
    await f.sync.refresh(reason: "foreground after sign-out")
    #expect(f.profiles.isLocked)
    #expect(deactivations == 1)
    #expect(f.sync.status == .noAccount)
    #expect(f.sync.currentUserRecordName == nil)
    #expect(f.profiles.activate(owner))
    await f.sync.refresh(reason: "foreground without an account")
    #expect(!f.profiles.isLocked)
    #expect(deactivations == 1)
}

@Test @MainActor func cloudTemporarilyUnavailableAccountNeitherLocksNorResetsSyncState() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    var deactivations = 0
    f.profiles.onDeactivate = { deactivations += 1 }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    f.identityUnavailable = true
    await f.sync.refresh(reason: "launch while iCloud is unavailable")
    #expect(!f.profiles.isLocked)
    if case .failed = f.sync.status {} else { Issue.record("An undetermined account must surface as a sync failure") }
    f.identityUnavailable = false
    f.pages = [.init(records: [], token: Data("cursor".utf8))]
    await f.sync.refresh(reason: "available")
    #expect(f.sync.isActive)
    f.identityUnavailable = true
    await f.sync.refresh(reason: "temporarily unavailable again")
    #expect(!f.profiles.isLocked)
    #expect(f.sync.currentUserRecordName == "A")
    if case .failed = f.sync.status {} else { Issue.record("An undetermined account must surface as a sync failure") }
    f.identityUnavailable = false
    await f.sync.refresh(reason: "available again")
    #expect(f.sync.isActive)
    #expect(f.requests.last?.1 == Data("cursor".utf8))
    #expect(f.subscriptions == 1)
    #expect(deactivations == 0)
}

@Test @MainActor func cloudSigningInWhileRunningWithoutAnAccountKeepsTheProfileOpen() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.account = nil
    var deactivations = 0
    f.profiles.onDeactivate = { deactivations += 1 }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    await f.sync.refresh(reason: "launch without an account")
    f.account = "A"
    f.sync.accountChangeNotified()
    await f.sync.refresh(reason: "iCloud account changed")
    #expect(!f.profiles.isLocked)
    #expect(deactivations == 0)
    #expect(f.sync.currentUserRecordName == "A")
    #expect(f.sync.isActive)

    // A verified account is still revoked the moment CloudKit reports a change.
    f.sync.accountChangeNotified()
    #expect(f.profiles.isLocked)
    #expect(deactivations == 1)
    #expect(f.sync.currentUserRecordName == nil)
}

@Test @MainActor func cloudLaunchWithoutAnAccountKeepsThePreviousAccountsSyncStateForItsReturn() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    f.pages = [.init(records: [], token: Data("cursor".utf8))]
    await f.sync.refresh(reason: "signed in")
    #expect(f.sync.isActive)
    let before = try f.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)

    f.relaunch(restoreProfiles: true) // Signed out while Gumbo was not running.
    f.account = nil
    var deactivations = 0
    f.profiles.onDeactivate = { deactivations += 1 }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    await f.sync.refresh(reason: "launch without an account")
    #expect(!f.profiles.isLocked)
    #expect(deactivations == 0)
    #expect(f.sync.status == .noAccount)
    let kept = try f.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(kept.zones[CKCurrentUserDefaultName]?.changeToken == Data("cursor".utf8))
    #expect(kept.subscribed == before.subscribed)
    #expect(kept.profileIDs == before.profileIDs)

    f.account = "A"
    await f.sync.refresh(reason: "signed in again")
    #expect(f.sync.isActive)
    #expect(f.requests.last?.1 == Data("cursor".utf8))
    #expect(f.subscriptions == 1)
    #expect(deactivations == 0)
}

@Test @MainActor func cloudInvitationWhileICloudIsUnavailableKeepsTheAccountAndPromisesNoRetry() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    var deactivations = 0
    f.profiles.onDeactivate = { deactivations += 1 }
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    await f.sync.refresh(reason: "signed in")
    f.identityUnavailable = true
    let message = await f.sync.accept(url: try #require(URL(string: "https://www.icloud.com/share/0gumbo-fixture#Family")))
    #expect(message == "iCloud is temporarily unavailable. Try again in a moment.")
    #expect(!f.profiles.isLocked)
    #expect(deactivations == 0)
    #expect(f.sync.currentUserRecordName == "A")
}

// MARK: - Family record uploads (#222, #250)

private let familyDetails = FamilyInfo(name: "NAS family", serverName: "NAS", serverAccount: "owner", musicPath: "/music",
                                       updatedAt: .distantPast, address: "https://nas.example:5001")

@Test @MainActor func ownerDeviceWithoutFamilyAccessNeitherClearsNorAnswersTheFamilyRecord() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.profiles.sync = nil // Explicit refreshes only.
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    var local = familyDetails
    local.name = "Owner's iPad family" // This device's own connection; it holds no Family Access.
    f.sync.familyInfoProvider = { local }
    var shared = familyDetails
    shared.familyAccount = "family-reader"
    shared.familyPassword = "first-fixture"
    f.pages = [.init(records: [.success(f.familyRecord(shared, updatedAt: Date(timeIntervalSince1970: 100)))], token: Data("1".utf8))]
    await f.sync.refresh(reason: "second owner device")
    let sent = try #require(f.familyUploads.last)
    #expect(f.familyUploads.count == 1)
    #expect(sent["name"] as? String == "Owner's iPad family")
    #expect(!sent.changedKeys().contains("familyAccount"))
    #expect(!sent.encryptedValues.changedKeys().contains("familyPassword"))
    #expect(f.sync.family?.familyPassword == "first-fixture")

    // The first device rotates the password; its upload arriving here must not start a reply.
    shared.familyPassword = "rotated-fixture"
    f.pages = [.init(records: [.success(f.familyRecord(shared, updatedAt: Date(timeIntervalSince1970: 200)))], token: Data("2".utf8))]
    await f.sync.refresh(reason: "push from the first device")
    #expect(f.familyUploads.count == 1)
    #expect(f.sync.family?.familyPassword == "rotated-fixture")

    f.relaunch()
    f.profiles.sync = nil
    f.sync.familyInfoProvider = { local }
    await f.sync.refresh(reason: "relaunch")
    #expect(f.familyUploads.count == 1)
}

@Test @MainActor func ownerDeviceWithMatchingDetailsDoesNotUploadTheFamilyRecordAtAll() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.profiles.sync = nil
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    f.sync.familyInfoProvider = { familyDetails }
    var shared = familyDetails
    shared.familyAccount = "family-reader"
    shared.familyPassword = "first-fixture"
    f.pages = [.init(records: [.success(f.familyRecord(shared, updatedAt: Date(timeIntervalSince1970: 100)))], token: Data("1".utf8))]
    await f.sync.refresh(reason: "second owner device")
    await f.sync.refresh(reason: "again")
    #expect(f.familyUploads.isEmpty)
    #expect(try f.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.familyUpload == FamilyRecordUpload(familyDetails))
}

@Test @MainActor func familyDetailsFromADeviceWithoutFamilyAccessKeepCredentialsThroughAConflict() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    fixture.sync.familyInfoProvider = { familyDetails }
    var rejected = false
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordType == "Family", !rejected {
                rejected = true
                let server = CKRecord(recordType: "Family", recordID: record.recordID)
                server["updatedAt"] = Date.distantPast
                server["name"] = "Old family name"
                server["familyAccount"] = "family-reader"
                server.encryptedValues["familyPassword"] = "kept-fixture"
                results[record.recordID] = .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
            } else { results[record.recordID] = .success(record) }
        }
        return results
    }
    await fixture.sync.refresh(reason: "details conflict")
    let record = try #require(fixture.familyUploads.last)
    #expect(fixture.familyUploads.count == 2)
    #expect(record["name"] as? String == familyDetails.name)
    #expect(record["familyAccount"] as? String == "family-reader")
    #expect(record.encryptedValues["familyPassword"] as? String == "kept-fixture")
    // What this device knows of the family now reads as iCloud's copy does.
    #expect(fixture.sync.family?.name == familyDetails.name)
    #expect(fixture.sync.family?.familyAccount == "family-reader")
    #expect(fixture.sync.family?.familyPassword == "kept-fixture")
    if case .synced = fixture.sync.status {} else { Issue.record("The family record should reconcile") }
}

@Test @MainActor func familyDetailsSentWithoutKnowingICloudsCopyLeaveTheRestUnknown() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var local = familyDetails
    fixture.sync.familyInfoProvider = { local }
    await fixture.sync.refresh(reason: "details sent")
    #expect(fixture.familyUploads.count == 1)

    fixture.relaunch()
    fixture.profiles.sync = nil
    fixture.sync.familyInfoProvider = { local }
    local.musicPath = "/music/library"
    await fixture.sync.refresh(reason: "details changed after relaunch")
    #expect(fixture.familyUploads.count == 2)
    // iCloud may hold another device's credentials: this device's lack of them says nothing.
    #expect(fixture.sync.family == nil)
}

@Test @MainActor func familyUploadIsNotRepeatedAfterRelaunchAndFollowsRotationAndRemovalHere() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var info = familyDetails
    info.familyAccount = "family-reader"
    info.familyPassword = "first-fixture"
    info.credentialsRevision = "first"
    fixture.sync.familyInfoProvider = { info }
    await fixture.sync.refresh(reason: "set up")
    #expect(fixture.familyUploads.count == 1)

    fixture.relaunch()
    fixture.profiles.sync = nil
    fixture.sync.familyInfoProvider = { info }
    await fixture.sync.refresh(reason: "relaunch")
    #expect(fixture.familyUploads.count == 1)

    info.familyPassword = "rotated-fixture"
    info.credentialsRevision = "rotated"
    await fixture.sync.refresh(reason: "rotated here")
    let rotated = try #require(fixture.familyUploads.last)
    #expect(fixture.familyUploads.count == 2)
    #expect(rotated.encryptedValues["familyPassword"] as? String == "rotated-fixture")
    #expect(!rotated.changedKeys().contains("serverName"))

    info.familyAccount = nil
    info.familyPassword = nil
    info.credentialsRevision = nil
    var rejected = false
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordType == "Family", !rejected {
                rejected = true
                let server = CKRecord(recordType: "Family", recordID: record.recordID)
                server["updatedAt"] = Date.distantPast
                server["familyAccount"] = "family-reader"
                server.encryptedValues["familyPassword"] = "rotated-fixture"
                results[record.recordID] = .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
            } else { results[record.recordID] = .success(record) }
        }
        return results
    }
    await fixture.sync.refresh(reason: "removed here")
    let cleared = try #require(fixture.familyUploads.last)
    #expect(cleared["familyAccount"] == nil)
    #expect(cleared.encryptedValues["familyPassword"] == nil)
    #expect(fixture.sync.family?.familyAccount == nil)
    await fixture.sync.refresh(reason: "settled")
    #expect(fixture.familyUploads.count == 4)
}

@Test @MainActor func failedFamilyUploadIsSentAgainOnTheNextRefreshAndAfterRelaunch() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var info = familyDetails
    info.familyAccount = "family-reader"
    info.familyPassword = "rotated-fixture"
    info.credentialsRevision = "rotated"
    fixture.sync.familyInfoProvider = { info }
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordType == "Family" { results[record.recordID] = .failure(CKError(.networkFailure)) }
            else { results[record.recordID] = .success(record) }
        }
        return results
    }
    await fixture.sync.refresh(reason: "family upload fails")
    #expect(fixture.familyUploads.count == 1)
    #expect(fixture.sync.family == nil)
    if case .failed = fixture.sync.status {} else { Issue.record("A failed family upload must stay visible") }
    await fixture.sync.refresh(reason: "next refresh")
    #expect(fixture.familyUploads.count == 2)

    fixture.saveOutcomes = nil
    fixture.relaunch()
    fixture.profiles.sync = nil
    fixture.sync.familyInfoProvider = { info }
    await fixture.sync.refresh(reason: "after relaunch")
    #expect(fixture.familyUploads.count == 3)
    #expect(fixture.familyUploads.last?.encryptedValues["familyPassword"] as? String == "rotated-fixture")
    #expect(fixture.sync.family?.familyPassword == "rotated-fixture")
    await fixture.sync.refresh(reason: "settled")
    #expect(fixture.familyUploads.count == 3)
}

@Test @MainActor func failedFamilyRotationAfterAnAcceptedUploadIsSentAgain() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var info = familyDetails
    info.familyAccount = "family-reader"
    info.familyPassword = "first-fixture"
    info.credentialsRevision = "first"
    fixture.sync.familyInfoProvider = { info }
    await fixture.sync.refresh(reason: "set up")
    #expect(fixture.familyUploads.count == 1)

    info.familyPassword = "rotated-fixture"
    info.credentialsRevision = "rotated"
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordType == "Family" { results[record.recordID] = .failure(CKError(.networkFailure)) }
            else { results[record.recordID] = .success(record) }
        }
        return results
    }
    await fixture.sync.refresh(reason: "rotation fails")
    #expect(fixture.familyUploads.count == 2)
    #expect(fixture.sync.family?.familyPassword == "first-fixture")
    fixture.saveOutcomes = nil
    await fixture.sync.refresh(reason: "next refresh")
    #expect(fixture.familyUploads.count == 3)
    #expect(fixture.familyUploads.last?.encryptedValues["familyPassword"] as? String == "rotated-fixture")
    await fixture.sync.refresh(reason: "settled")
    #expect(fixture.familyUploads.count == 3)
}

@Test @MainActor func familyRecordDeletedFromICloudIsCreatedAgainWithTheFamilysCredentials() async throws {
    let f = try CloudFixture(); defer { f.cleanUp() }
    f.profiles.sync = nil
    #expect(f.profiles.activate(try #require(f.profiles.owner)))
    var local = familyDetails
    local.name = "Owner's iPad family" // This device holds no Family Access.
    f.sync.familyInfoProvider = { local }
    var shared = familyDetails
    shared.familyAccount = "family-reader"
    shared.familyPassword = "kept-fixture"
    f.pages = [.init(records: [.success(f.familyRecord(shared, updatedAt: Date(timeIntervalSince1970: 100)))], token: Data("1".utf8))]
    await f.sync.refresh(reason: "second owner device")
    #expect(f.familyUploads.count == 1)

    let id = CKRecord.ID(recordName: "family", zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName))
    f.pages = [.init(records: [], deletions: [.init(id: id, type: "Family")], token: Data("2".utf8))]
    await f.sync.refresh(reason: "family record deleted")
    let created = try #require(f.familyUploads.last)
    #expect(f.familyUploads.count == 2)
    #expect(created["name"] as? String == "Owner's iPad family")
    #expect(created["serverName"] as? String == "NAS")
    #expect(created["familyAccount"] as? String == "family-reader")
    #expect(created.encryptedValues["familyPassword"] as? String == "kept-fixture")
    await f.sync.refresh(reason: "settled")
    #expect(f.familyUploads.count == 2)
}

@Test @MainActor func familyRecordMissingOnSaveIsCreatedAgainInFullAndCountsAsSent() async throws {
    let (fixture, _) = try await seededMissingRecordFixture()
    defer { fixture.cleanUp() }
    var info = familyDetails
    info.familyAccount = "family-reader"
    info.familyPassword = "first-fixture"
    info.credentialsRevision = "first"
    fixture.sync.familyInfoProvider = { info }
    await fixture.sync.refresh(reason: "set up")
    #expect(fixture.familyUploads.count == 1)

    info.familyPassword = "rotated-fixture"
    info.credentialsRevision = "rotated"
    var rejected = false
    fixture.saveOutcomes = { records in
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            if record.recordType == "Family", !rejected {
                rejected = true
                results[record.recordID] = .failure(CKError(.unknownItem))
            } else { results[record.recordID] = .success(record) }
        }
        return results
    }
    await fixture.sync.refresh(reason: "rotated, but the record is gone")
    let created = try #require(fixture.familyUploads.last)
    #expect(fixture.familyUploads.count == 3)
    #expect(!fixture.familyUploads[1].changedKeys().contains("serverName"))
    #expect(created["name"] as? String == familyDetails.name)
    #expect(created["serverName"] as? String == "NAS")
    #expect(created["serverAccount"] as? String == "owner")
    #expect(created["musicPath"] as? String == "/music")
    #expect(created["address"] as? String == familyDetails.address)
    #expect(created["familyAccount"] as? String == "family-reader")
    #expect(created.encryptedValues["familyPassword"] as? String == "rotated-fixture")
    let upload = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.familyUpload
    #expect(upload == FamilyRecordUpload(info))
    #expect(fixture.sync.family?.familyPassword == "rotated-fixture")
    if case .synced = fixture.sync.status {} else { Issue.record("The family record should be created again") }
    await fixture.sync.refresh(reason: "settled")
    #expect(fixture.familyUploads.count == 3)
}
