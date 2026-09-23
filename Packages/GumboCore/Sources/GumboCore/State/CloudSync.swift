import CloudKit
import Foundation
import Observation

/// Mirrors the profiles and their documents into CloudKit. The owner's private database holds a
/// "Family" zone; invited members reach the same zone through their shared database. The files on
/// the device stay what the screens read; this keeps them in step with the cloud, and does nothing
/// at all when the device has no iCloud account.
@Observable
public final class CloudSync {
    public enum Status: Equatable {
        case off, noAccount, syncing, synced(Date), failed(String)

        public var text: String {
            switch self {
            case .off: "Off"
            case .noAccount: "Not signed in to iCloud"
            case .syncing: "Syncing…"
            case .synced(let date): "Up to date · \(date.formatted(date: .omitted, time: .shortened))"
            case .failed(let message): message
            }
        }
    }

    public enum Membership: String {
        case owner, member
    }

    public struct Participant: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let isOwner: Bool
        public let accepted: Bool
        public let isMe: Bool
    }

    public static let containerID = "iCloud.com.samuelvoltolini.gumbo"
    private static let zoneName = "Family"

    public private(set) var status: Status = .off
    public private(set) var membership: Membership
    public private(set) var currentUserRecordName: String?
    public private(set) var participants: [Participant] = []
    public private(set) var family: FamilyInfo?
    /// True once the zone is shared with at least one other person, or this device joined one.
    public private(set) var isShared = false
    /// Only a definitive missing/deleted shared zone exposes invitation recovery while sync is failed.
    public private(set) var needsFamilyInvitation = false

    @ObservationIgnored private lazy var container = CKContainer(identifier: CloudSync.containerID)
    private let services: CloudServices
    private let persistence: CloudPersistence
    private let decodeProfileDocument: (Data) async throws -> (state: ProfileState, digest: String)
    private var accountState: CloudAccountState?
    private var generation = UUID()
    private var zoneOwnerName: String
    private var changeToken: Data?
    /// CloudKit's own metadata per record, so saves carry the right change tags.
    private var systemFields: [String: Data]
    /// `updatedAt` of every record as last seen in the cloud, so only newer local data is pushed.
    private var remoteStamps: [String: Date]
    private var remoteStateDigests: [String: String] = [:]
    /// The Family record being sent by this refresh. It counts as uploaded only once CloudKit accepts it.
    private var familyInFlight: FamilyRecordPlan?
    private var uploads: [String: Task<Void, Never>] = [:]
    /// The refresh promised by "It will try again" after a transient failure.
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var isStarted = false
    private var isRefreshing = false
    private var wantsAnotherRefresh = false
    private var accountObserver: (any NSObjectProtocol)?
    /// Retried on the next sync; remains visible while offline or when CloudKit refuses a deletion.
    public var pendingDeletionCount: Int { accountState?.zones[zoneOwnerName]?.deletions.values.filter { !$0.isEmpty }.count ?? 0 }

    public weak var profiles: ProfileStore?
    /// The owner's server details, written into the family record for members to connect with.
    public var familyInfoProvider: (() -> FamilyInfo?)?
    /// Called with the family record whenever it arrives or changes.
    public var onFamilyInfo: ((FamilyInfo) -> Void)?

    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: zoneOwnerName) }
    private var database: CKDatabase { membership == .member ? container.sharedCloudDatabase : container.privateCloudDatabase }
    private var shareRecordID: CKRecord.ID { CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID) }

    public var isOwner: Bool { membership == .owner }
    public var isActive: Bool {
        switch status {
        case .syncing, .synced: true
        default: false
        }
    }

    public convenience init() {
        self.init(services: .live(container: CKContainer(identifier: Self.containerID)), persistence: CloudPersistence(directory: Self.persistenceDirectory))
    }

    init(services: CloudServices, persistence: CloudPersistence,
         decodeProfileDocument: @escaping (Data) async throws -> (state: ProfileState, digest: String) = { try await ProfileCloudPreparation.decode($0) }) {
        self.services = services
        self.persistence = persistence
        self.decodeProfileDocument = decodeProfileDocument
        // Legacy global metadata has no verifiable account owner. Refetch instead of adopting it.
        membership = .owner
        zoneOwnerName = CKCurrentUserDefaultName
        systemFields = [:]
        remoteStamps = [:]
    }

    // MARK: Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.accountChangeNotified()
                await self?.refresh(reason: "iCloud account changed")
            }
        }
        Task { await refresh(reason: "launch") }
    }

    /// CloudKit posts this for every change of account status without saying which. A verified account
    /// is revoked at once, before anything more runs in it, even when iCloud was only unavailable for a
    /// moment: the open profile locks once rather than ever running under another account. With no
    /// verified account there is nothing to revoke, so signing in only stops the work in flight and,
    /// as at a launch signed in, the open profile keeps playing.
    func accountChangeNotified() {
        if currentUserRecordName != nil {
            accountChanged()
        } else {
            generation = UUID()
            for task in uploads.values { task.cancel() }
            uploads = [:]
        }
    }

    /// Revocation happens before any new account request, including while an old request is suspended.
    func accountChanged() {
        generation = UUID()
        for task in uploads.values { task.cancel() }
        uploads = [:]
        currentUserRecordName = nil
        accountState = nil
        membership = .owner
        zoneOwnerName = CKCurrentUserDefaultName
        changeToken = nil
        systemFields = [:]
        remoteStamps = [:]
        family = nil
        remoteStateDigests = [:]
        participants = []
        isShared = false
        needsFamilyInvitation = false
        status = .off
        try? persistence.saveVerifiedAccount(nil)
        // Even with no profile open: nothing granted under the previous account may carry over.
        profiles?.lock(deactivatingWhenClosed: true)
    }

    private func check(_ expected: UUID) throws {
        guard generation == expected, !Task.isCancelled else { throw CancellationError() }
    }

    private func scope(_ expected: UUID) throws -> CloudScope {
        try check(expected)
        guard let account = currentUserRecordName, accountState?.account == account else { throw CKError(.notAuthenticated) }
        return CloudScope(account: account, owner: zoneOwnerName, isMember: membership == .member)
    }

    private func verifyIdentity(_ expected: UUID) async throws {
        let reported = try await services.identity()
        try check(expected)
        let identity: String
        switch reported {
        case .available(let account):
            identity = account
        case .noAccount:
            // Signed out since this session verified an account: revoke it like any account change.
            // Otherwise the open profile keeps playing and the Watch keeps its downloads (#219, #221),
            // even when an account verified in an earlier launch has since signed out: a launch that
            // finds no account can't tell that from a moment without one. The account saved as last
            // verified stays, so whichever different account signs in next revokes what it granted.
            if currentUserRecordName != nil { accountChanged() }
            status = .noAccount
            throw CancellationError()
        case .unavailable:
            // No evidence of another account: keep the account, its sync state and the open profile.
            throw SyncFailure.message("iCloud is temporarily unavailable. Try again in a moment.")
        }
        guard currentUserRecordName != identity else { return }
        if currentUserRecordName != nil {
            // A missed notification must still invalidate every previously queued operation.
            accountChanged()
        } else if let earlier = persistence.verifiedAccount(), earlier != identity {
            // The account verified here before was replaced while Gumbo was not running, or before this
            // launch's first check finished. Revoke it as a change seen while running would, so access
            // still held under it, such as a Watch grant kept across a relaunch, ends too (#219).
            accountChanged()
        }
        // Recorded before the sync state loads, so even when that fails the next launch still knows
        // which account this device last verified.
        try? persistence.saveVerifiedAccount(identity)
        let snapshot: CloudAccountState
        do {
            let isNew = !persistence.hasSnapshot(account: identity)
            var loaded = try persistence.load(account: identity, defaultOwner: CKCurrentUserDefaultName)
            if loaded.membership == Membership.member.rawValue, Self.isOwnZone(loaded.zoneOwner, account: identity) {
                Self.restoreOwnership(of: &loaded)
                services.log("This device had joined its own family as a member; it is the owner again")
            }
            if isNew, try persistence.claimsLegacyProfiles(account: identity) {
                loaded.profileIDs = Set(profiles?.profiles.map(\.id) ?? [])
            }
            for profile in profiles?.profiles ?? [] {
                if case .recovery(_)? = profile.localOrigin {
                    if try recoveryProfileBelongs(profile, to: identity) { loaded.profileIDs.insert(profile.id) }
                    else { loaded.profileIDs.remove(profile.id) }
                }
            }
            try persistence.save(loaded)
            snapshot = loaded
        } catch {
            status = .failed("The iCloud account's sync state could not be read or saved on this device.")
            throw error
        }
        currentUserRecordName = identity
        accountState = snapshot
        membership = Membership(rawValue: snapshot.membership) ?? .owner
        zoneOwnerName = snapshot.zoneOwner
        loadZoneState()
    }

    /// The owner's own family zone, however CloudKit names it: never one to join as a member (#252).
    private static func isOwnZone(_ owner: String, account: String?) -> Bool {
        owner == CKCurrentUserDefaultName || owner == account
    }

    /// An earlier version let an owner who opened their own invitation become a "member" of their own
    /// zone, which no shared database holds, so every sync failed and nothing could undo it (#252).
    /// Back to owning it: deletions asked for meanwhile never reached the zone and are sent again there.
    private static func restoreOwnership(of snapshot: inout CloudAccountState) {
        if snapshot.zoneOwner != CKCurrentUserDefaultName, let stray = snapshot.zones.removeValue(forKey: snapshot.zoneOwner) {
            var zone = snapshot.zones[CKCurrentUserDefaultName] ?? .init()
            for id in stray.deletions.keys where zone.deletions[id] == nil { zone.deletions[id] = [id, "state-\(id)"] }
            snapshot.zones[CKCurrentUserDefaultName] = zone
        }
        snapshot.membership = Membership.owner.rawValue
        snapshot.zoneOwner = CKCurrentUserDefaultName
    }

    private func loadZoneState() {
        let zone = accountState?.zones[zoneOwnerName] ?? .init()
        changeToken = zone.changeToken
        systemFields = zone.systemFields
        remoteStamps = zone.remoteStamps
        remoteStateDigests = zone.remoteStateDigests ?? [:]
        family = nil
        participants = []
        isShared = membership == .member
        needsFamilyInvitation = false
    }

    /// Pulls what changed, then pushes anything newer on this device. Overlapping calls fold into one more pass.
    public func refresh(reason: String) async {
        if isRefreshing {
            wantsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if wantsAnotherRefresh {
                wantsAnotherRefresh = false
                Task { await refresh(reason: "queued") }
            }
        }
        var expected = generation
        do {
            try await verifyIdentity(expected)
            // Identity discovery itself may have invalidated a missed account change.
            expected = generation
            status = .syncing
            guard profiles?.isProfileIndexReadable != false else {
                throw SyncFailure.message("Restore the saved profile list before syncing with iCloud.")
            }
            try finishFamilyRetirement()
            try reconcileFamilyRoles()
            try await adoptSharedZoneIfPresent(expected)
            expected = generation
            if membership == .owner {
                try await services.createZone(scope(expected))
                try check(expected)
            }
            try await ensureSubscriptions(expected)
            try await retryDeletions(expected)
            try await fetchChanges()
            try check(expected)
            try registerRecoveryProfiles()
            if let replacement = profiles?.ensureProfileAfterSync(isOwner: isOwner) {
                accountState?.profileIDs.insert(replacement.id)
                try persistState()
            }
            if profiles?.profiles.isEmpty == true { throw SyncFailure.message("A new local profile could not be saved after iCloud removed the last profile.") }
            discardStandIns()
            try await retryDeletions(expected)
            try await pushLocal()
            try check(expected)
            status = .synced(.now)
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            if let profiles, profiles.isLocked {
                let eligible = profiles.profiles.filter { accountState?.profileIDs.contains($0.id) == true }
                if eligible.contains(where: { $0.userRecordName == currentUserRecordName }) || (profiles.profiles.count == 1 && eligible.count == 1) {
                    profiles.openAutomaticallyIfPossible(boundTo: currentUserRecordName)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected else { return }
            status = .failed(Self.describe(error))
            services.log("iCloud sync (\(reason)) failed: \(Self.describe(error))")
            scheduleRetry(after: error)
        }
    }

    /// Busy, rate-limited or offline: refresh again after the wait iCloud asks for, or with backoff.
    /// Edits made meanwhile are skipped by `schedule` while sync is failed; the refresh pushes them,
    /// since it sends everything newer on this device.
    private func scheduleRetry(after error: any Error) {
        guard let delay = Self.retryDelay(for: error, attempt: retryAttempt) else { return }
        retryAttempt += 1
        let expected = generation
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, generation == expected, !Task.isCancelled else { return }
            retryTask = nil
            services.log("Retrying iCloud sync")
            await refresh(reason: "retry")
        }
    }

    /// How long to wait before retrying after `error`, or nil when retrying would not help.
    nonisolated static func retryDelay(for error: any Error, attempt: Int) -> Duration? {
        guard let ckError = error as? CKError else { return nil }
        switch ckError.code {
        case .zoneBusy, .requestRateLimited, .serviceUnavailable, .networkUnavailable, .networkFailure:
            if let seconds = ckError.retryAfterSeconds, seconds > 0 { return .seconds(min(seconds, 3600)) }
            return .seconds(min(5 * pow(2, Double(min(attempt, 10))), 300))
        default:
            return nil
        }
    }

    /// A share accepted on any of this person's devices shows up in their shared database; follow it.
    private func adoptSharedZoneIfPresent(_ expected: UUID) async throws {
        guard membership != .member else { return }
        let owners = try await services.sharedZones()
        try check(expected)
        guard let owner = owners.first(where: { !Self.isOwnZone($0, account: currentUserRecordName) }) else { return }
        try join(zoneOwnerName: owner)
        services.log("Following the shared family")
    }

    func join(zoneOwnerName: String) throws {
        // The owner's own zone is in their private database, never their shared one (#252).
        guard !Self.isOwnZone(zoneOwnerName, account: currentUserRecordName) else { return }
        try persistState()
        guard var snapshot = accountState else { throw CKError(.notAuthenticated) }
        let entering = membership != .member || self.zoneOwnerName != zoneOwnerName
        if membership == .member, self.zoneOwnerName != zoneOwnerName {
            excludeFormerFamily(from: &snapshot)
        }
        // A family joined before, and left, may have changed since: what this device fetched from it
        // then must not stand in for a full fetch now, or its people never come back (#251).
        if entering { snapshot.zones[zoneOwnerName]?.forgetFetchedRecords() }
        snapshot.membership = Membership.member.rawValue
        snapshot.zoneOwner = zoneOwnerName
        try installFamilyScope(snapshot)
        guard profiles?.markAllAsMembers(in: snapshot.profileIDs) != false else {
            throw SyncFailure.message("The family membership could not be saved to the profiles on this device.")
        }
    }

    private func excludeFormerFamily(from snapshot: inout CloudAccountState) {
        let own = Set((profiles?.profiles ?? []).filter { $0.userRecordName == snapshot.account }.map(\.id))
        let retired = snapshot.profileIDs.subtracting(own)
        snapshot.profileIDs.subtract(retired)
        snapshot.retiredFamilyProfileIDs = (snapshot.retiredFamilyProfileIDs ?? []).union(retired)
        // Its cursor would only bring back what changed after it, never the retired profiles (#251).
        snapshot.zones[snapshot.zoneOwner]?.forgetFetchedRecords()
    }

    private func installFamilyScope(_ snapshot: CloudAccountState) throws {
        // Save the exclusion and pending cleanup before exposing the destination zone.
        try persistence.save(snapshot)
        generation = UUID()
        for task in uploads.values { task.cancel() }
        uploads = [:]
        membership = Membership(rawValue: snapshot.membership) ?? .owner
        zoneOwnerName = snapshot.zoneOwner
        accountState = snapshot
        loadZoneState()
        do {
            try finishFamilyRetirement()
            try reconcileFamilyRoles()
        }
        catch { status = .failed(Self.describe(error)); throw error }
    }

    private func reconcileFamilyRoles() throws {
        guard let profiles, let snapshot = accountState else { return }
        let saved = membership == .member
            ? profiles.markAllAsMembers(in: snapshot.profileIDs)
            : profiles.ensurePersonalOwner(in: snapshot.profileIDs, preferring: currentUserRecordName)
        guard saved else { throw SyncFailure.message("The family membership could not be saved on this device.") }
    }

    private func finishFamilyRetirement() throws {
        guard var snapshot = accountState, let ids = snapshot.retiredFamilyProfileIDs, !ids.isEmpty else { return }
        guard let profiles, profiles.retireFamilyProfiles(ids) else {
            throw SyncFailure.message("Previous family data could not be removed on this device. Try syncing again.")
        }
        snapshot.retiredFamilyProfileIDs = nil
        try persistence.save(snapshot)
        accountState = snapshot
    }

    private func ensureSubscriptions(_ expected: UUID) async throws {
        guard accountState?.subscribed != true else { return }
        try await services.subscribe()
        try check(expected)
        accountState?.subscribed = true
        try persistState()
    }

    // MARK: Pulling

    public func fetchChanges() async throws {
        let expected = generation
        let activeScope = try scope(expected)
        let requested = changeToken
        let page: CloudChangePage
        do {
            page = try await services.changes(activeScope, requested)
            try check(expected)
            needsFamilyInvitation = false
        } catch let error as CKError where error.code == .changeTokenExpired {
            try check(expected)
            // A reset is durable before another page is requested. Never acknowledge a bad page.
            changeToken = nil
            try persistState()
            try await fetchChanges()
            return
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            try check(expected)
            // A missing shared zone must not silently move its profiles/deletion intents into a new family.
            needsFamilyInvitation = membership == .member
            throw SyncFailure.message(membership == .member
                ? "The shared family is no longer available. Ask its owner for a new invitation and join again in Family settings."
                : "The iCloud family is unavailable. Try syncing again.")
        }
        var failures = 0
        for result in page.records {
            try check(expected)
            do {
                let record = try result.get()
                guard record.recordID.zoneID == activeScope.zoneID else { throw SyncFailure.message("An iCloud record arrived for a different family.") }
                try await apply(record)
                try check(expected)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Decoding can fail after suspension too. Do not continue an old account's
                // page merely because its worker threw before the success-path generation check.
                try check(expected)
                failures += 1
                services.log("iCloud: a changed record could not be applied: \(Self.describe(error))")
            }
        }
        try check(expected)
        for deletion in page.deletions {
            do {
                guard deletion.id.zoneID == activeScope.zoneID else { throw SyncFailure.message("An iCloud deletion arrived for a different family.") }
                try removed(deletion.id, type: deletion.type)
            } catch { failures += 1 }
        }
        // Persist successful entries for idempotent retry, keeping the previous cursor on any failure.
        try persistState()
        guard failures == 0 else {
            let problem = SyncFailure.message("iCloud sync is incomplete: \(failures) change(s) will be retried.")
            status = .failed(problem.localizedDescription)
            throw problem
        }
        // A document set aside while this page was in flight asked for everything again. Moving
        // past this page would skip the records that were meant to come back.
        guard changeToken == requested else {
            try await fetchChanges()
            return
        }
        let previous = changeToken
        changeToken = page.token
        do { try persistState() }
        catch {
            changeToken = previous
            throw error
        }
        if page.moreComing { try await fetchChanges() }
    }

    private enum SyncFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let message): message } }
    }

    private func isTombstoned(_ id: String) -> Bool {
        accountState?.zones[zoneOwnerName]?.deletions[id] != nil
    }

    private func retainDeletionForReturnedRecord(_ id: String) throws {
        // Another device (or an already submitted upload) may return a live record after an ack.
        // Keep suppressing it locally and send both deletions again during this refresh.
        accountState?.zones[zoneOwnerName]?.deletions[id] = [id, "state-\(id)"]
        try persistState()
    }

    private func apply(_ record: CKRecord) async throws {
        let expected = generation
        switch record.recordType {
        case "Profile":
            guard let profile = Self.profile(from: record) else { throw SyncFailure.message("A profile from iCloud is incomplete.") }
            if isTombstoned(profile.id) { try retainDeletionForReturnedRecord(profile.id); return }
            guard let profiles else { throw SyncFailure.message("Profiles are not ready to receive iCloud changes.") }
            if profile.avatar.hasPhoto, (record["photo"] as? CKAsset)?.fileURL == nil {
                throw SyncFailure.message("A profile photo from iCloud is incomplete.")
            }
            if profiles.profiles.first(where: { $0.id == profile.id }).map({ $0.updatedAt >= profile.updatedAt }) != true {
                guard profiles.storeRemotePhoto(at: profile.avatar.hasPhoto ? (record["photo"] as? CKAsset)?.fileURL : nil, for: profile.id),
                      profiles.applyRemote(profile) else { throw SyncFailure.message("A profile from iCloud could not be saved on this device.") }
            }
            remoteStamps[record.recordID.recordName] = profile.updatedAt
            accountState?.profileIDs.insert(profile.id)
        case "ProfileState":
            guard let data = record["document"] as? Data,
                  let profileID = record["profileID"] as? String,
                  record.recordID.recordName == "state-\(profileID)" else { throw SyncFailure.message("A profile's iCloud document is incomplete.") }
            if isTombstoned(profileID) { try retainDeletionForReturnedRecord(profileID); return }
            let decoded = try await decodeProfileDocument(data)
            try check(expected)
            if isTombstoned(profileID) { try retainDeletionForReturnedRecord(profileID); return }
            guard let profiles, profiles.applyRemote(decoded.state, id: profileID) else { throw SyncFailure.message("A profile's iCloud document could not be saved on this device.") }
            remoteStamps[record.recordID.recordName] = decoded.state.updatedAt
            remoteStateDigests[record.recordID.recordName] = decoded.digest
        case "Family":
            let info = try Self.familyInfo(from: record)
            remoteStamps[record.recordID.recordName] = info.updatedAt
            family = info
            onFamilyInfo?(info)
        case "cloudkit.share":
            if let share = record as? CKShare { update(share) }
        default: break
        }
        remember(record)
    }

    private func removed(_ recordID: CKRecord.ID, type: CKRecord.RecordType) throws {
        switch type {
        case "Profile":
            guard let profiles, profiles.removeRemote(id: recordID.recordName, replacementAccount: currentUserRecordName, replacementIsOwner: isOwner) else {
                throw SyncFailure.message("A deleted iCloud profile could not be removed from this device.")
            }
            if accountState?.zones[zoneOwnerName] == nil { accountState?.zones[zoneOwnerName] = .init() }
            if accountState?.zones[zoneOwnerName]?.deletions[recordID.recordName] == nil {
                accountState?.zones[zoneOwnerName]?.deletions[recordID.recordName] = []
            }
        case "cloudkit.share":
            participants = []
            isShared = false
        default: break
        }
        systemFields[recordID.recordName] = nil
        remoteStamps[recordID.recordName] = nil
        remoteStateDigests[recordID.recordName] = nil
    }

    private func update(_ share: CKShare) {
        participants = share.participants.map { participant in
            let name = participant.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) } ?? ""
            let recordName = participant.userIdentity.userRecordID?.recordName ?? UUID().uuidString
            return Participant(
                id: recordName,
                name: name.isEmpty ? (participant.role == .owner ? "Owner" : "Invited") : name,
                isOwner: participant.role == .owner,
                accepted: participant.acceptanceStatus == .accepted,
                isMe: recordName == currentUserRecordName
            )
        }
        isShared = share.participants.count > 1 || membership == .member
    }

    // MARK: Pushing

    /// Uploads local profiles and documents the cloud has not seen, or has older copies of.
    /// A fresh install makes a stand-in profile before iCloud has answered, and an older build
    /// uploaded it. Once the family's profiles are here and one of them is already this person's,
    /// any untouched stand-in goes, here and in the cloud, so every device converges on one profile.
    private func discardStandIns() {
        guard let profiles, let user = currentUserRecordName,
              profiles.profiles.contains(where: { $0.userRecordName == user }) else { return }
        let standIns = profiles.profiles.filter { profile in
            profile.userRecordName == nil && profile.pin == nil && profile.avatar.photoVersion == nil
                && profile.localOrigin != .created
                && abs(profile.updatedAt.timeIntervalSince(profile.createdAt)) < 2
                && profiles.storedStateIsPristine(id: profile.id)
        }
        for standIn in standIns where profiles.profiles.count > 1 {
            services.log("Removing the stand-in profile “\(standIn.name)”: this iCloud account already has a profile")
            profiles.discardStandIn(standIn)
        }
    }

    private func pushLocal() async throws {
        guard let profiles else { return }
        defer { familyInFlight = nil }
        let expected = generation
        var toSave: [CKRecord] = []
        var newProfiles = 0
        let remoteProfileCount = remoteStamps.keys.filter { !$0.hasPrefix("state-") && $0 != "family" }.count
        for profile in profiles.profiles {
            guard accountState?.profileIDs.contains(profile.id) == true, !isTombstoned(profile.id) else { continue }
            let stamp = remoteStamps[profile.id]
            if stamp == nil {
                guard remoteProfileCount + newProfiles < Profile.limit else {
                    services.log("Not uploading “\(profile.name)”: the family already has \(Profile.limit) profiles")
                    continue
                }
                newProfiles += 1
            }
            if stamp == nil || profile.updatedAt > stamp! {
                toSave.append(record(for: profile))
            }
            let state = profiles.storedState(id: profile.id)
            if state.updatedAt > .distantPast {
                let prepared = try await ProfileCloudPreparation.prepare(state, acknowledgedDigest: remoteStateDigests["state-\(profile.id)"])
                try check(expected)
                if containsProfileInCurrentAccount(profile.id), let record = record(for: prepared, profileID: profile.id) { toSave.append(record) }
            }
        }
        if membership == .owner, let active = profiles.active, accountState?.profileIDs.contains(active.id) == true,
           let intent = familyInfoProvider?() {
            // Only what this device changed since its own last upload is sent, never merely what differs
            // from iCloud's copy, so the owner's devices do not answer each other's Family uploads.
            let uploaded = accountState?.zones[zoneOwnerName]?.familyUpload
            // A record sent before whose revision is gone was found missing: create it again in full.
            var plan = FamilyRecordPlan(intent: intent, lastUpload: uploaded, server: family,
                                        recreating: uploaded != nil && systemFields["family"] == nil)
            if plan.needsSave {
                plan.info.updatedAt = .now
                toSave.append(record(for: plan))
                familyInFlight = plan
            } else if plan.upload != uploaded {
                // iCloud already holds this intent.
                recordFamilyUpload(plan.upload)
                try persistState()
            }
        }
        if let user = currentUserRecordName, !profiles.profiles.contains(where: { $0.userRecordName == user }), let active = profiles.active,
           accountState?.profileIDs.contains(active.id) == true, active.userRecordName == nil {
            // The profile in use becomes this iCloud user's own, so their other devices open it directly.
            profiles.bindActiveProfile(to: user)
            if let stored = profiles.profiles.first(where: { $0.id == active.id }) {
                toSave.removeAll { $0.recordID.recordName == stored.id }
                toSave.append(record(for: stored))
            }
        }
        toSave.removeAll { record in
            let id = record.recordType == "Profile" ? record.recordID.recordName : record["profileID"] as? String
            return id.map { !containsProfileInCurrentAccount($0) } ?? false
        }
        guard !toSave.isEmpty else { return }
        try await save(toSave)
    }

    public func profileChanged(_ profile: Profile) {
        guard accountState?.profileIDs.contains(profile.id) == true, !isTombstoned(profile.id) else { return }
        schedule(key: profile.id) { [weak self] in
            guard let self else { return }
            try await save([record(for: profile)])
        }
    }

    func containsProfileInCurrentAccount(_ id: String) -> Bool {
        accountState?.profileIDs.contains(id) == true && !isTombstoned(id)
    }

    /// A new profile inherits the active profile's verified account scope, including after an
    /// offline relaunch. Persist that association before the profile is exposed locally.
    func prepareProfileCreation(_ profile: Profile) -> Bool {
        guard let active = profiles?.active else { return false }
        let isVerified = currentUserRecordName != nil && accountState?.account == currentUserRecordName
        do {
            guard var snapshot = isVerified ? accountState : try persistence.deletionContext(profileID: active.id) else {
                if active.userRecordName == nil, try !persistence.hasCloudAssociation(profileID: active.id) {
                    return true // Local first-launch profiles are adopted on their first verified sync.
                }
                status = .failed("Connect to iCloud to confirm which family the new profile belongs to.")
                return false
            }
            guard snapshot.profileIDs.contains(active.id), snapshot.zones[snapshot.zoneOwner]?.deletions[active.id] == nil else {
                status = .failed("Open a profile in this Apple Account before creating another profile.")
                return false
            }
            snapshot.profileIDs.insert(profile.id)
            try persistence.save(snapshot)
            if isVerified { accountState = snapshot }
            return true
        } catch {
            status = .failed("The new profile could not be created because its iCloud membership could not be saved on this device.")
            return false
        }
    }

    /// Must succeed before local removal; an offline deletion survives relaunch in this account/family.
    func prepareProfileDeletion(id: String) -> Bool {
        var snapshot: CloudAccountState
        let isVerified = currentUserRecordName != nil && accountState?.account == currentUserRecordName
        do {
            guard let context = isVerified ? accountState : try persistence.deletionContext(profileID: id) else {
                if profiles?.profiles.first(where: { $0.id == id })?.userRecordName == nil,
                   try !persistence.hasCloudAssociation(profileID: id) {
                    return true // A purely local profile has no remote deletion to retry.
                }
                status = .failed("Connect to iCloud to confirm which family's profile to delete.")
                return false
            }
            snapshot = context
        } catch {
            status = .failed("The profile's pending iCloud deletion could not be saved on this device.")
            return false
        }
        guard snapshot.profileIDs.contains(id) else {
            status = .failed("This profile belongs to another Apple Account. Switch back to that account before deleting it.")
            return false
        }
        let owner = snapshot.zoneOwner
        if snapshot.zones[owner]?.deletions[id] != nil { return true }
        var zone = snapshot.zones[owner] ?? .init()
        if isVerified {
            zone.changeToken = changeToken
            zone.systemFields = systemFields
            zone.remoteStamps = remoteStamps
            zone.remoteStateDigests = remoteStateDigests
        }
        zone.deletions[id] = [id, "state-\(id)"]
        snapshot.zones[owner] = zone
        do {
            try persistence.save(snapshot)
            if isVerified { accountState = snapshot }
            else { status = .failed("The profile deletion is saved and will sync when its Apple Account reconnects.") }
        } catch {
            status = .failed("The profile could not be deleted because its pending iCloud change could not be saved on this device.")
            return false
        }
        uploads[id]?.cancel()
        uploads["state-\(id)"]?.cancel()
        return true
    }

    public func profileDeleted(id: String) {
        guard isTombstoned(id), isActive else { return }
        Task { await refresh(reason: "profile deleted") }
    }

    private func retryDeletions(_ expected: UUID) async throws {
        guard let deletions = accountState?.zones[zoneOwnerName]?.deletions else { return }
        // Reconcile first, including already-acknowledged tombstones: a crash or disk failure may
        // have happened after the durable intent but before the local profile list was replaced.
        for id in deletions.keys {
            guard let profiles, profiles.removeRemote(id: id, replacementAccount: currentUserRecordName, replacementIsOwner: isOwner) else {
                throw SyncFailure.message("A pending profile deletion could not be applied on this device. It will be retried.")
            }
        }
        try registerRecoveryProfiles()
        let names = Set(deletions.values.flatMap { $0 })
        guard !names.isEmpty else { return }
        let activeScope = try scope(expected)
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: activeScope.zoneID) }
        let result = try await services.modify(activeScope, [], ids)
        try check(expected)
        var firstFailure: (any Error)?
        for id in ids {
            let outcome = result.deleted[id] ?? .failure(SyncFailure.message("iCloud did not acknowledge a profile deletion."))
            let succeeded: Bool
            switch outcome {
            case .success: succeeded = true
            case .failure(let error):
                succeeded = (error as? CKError)?.code == .unknownItem
                if !succeeded, firstFailure == nil { firstFailure = error }
            }
            if succeeded {
                for profileID in deletions.keys { accountState?.zones[zoneOwnerName]?.deletions[profileID]?.remove(id.recordName) }
                systemFields[id.recordName] = nil
                remoteStamps[id.recordName] = nil
                remoteStateDigests[id.recordName] = nil
            }
        }
        try persistState()
        if let firstFailure { throw SyncFailure.message("A profile deletion is pending: \(Self.describe(firstFailure))") }
    }

    private func registerRecoveryProfiles() throws {
        guard let account = currentUserRecordName else { return }
        var changed = false
        for profile in profiles?.profiles ?? [] {
            if case .recovery(_)? = profile.localOrigin {
                let belongs = try recoveryProfileBelongs(profile, to: account)
                if belongs != (accountState?.profileIDs.contains(profile.id) == true) {
                    if belongs { accountState?.profileIDs.insert(profile.id) }
                    else { accountState?.profileIDs.remove(profile.id) }
                    changed = true
                }
            }
        }
        if changed { try persistState() }
    }

    private func recoveryProfileBelongs(_ profile: Profile, to account: String) throws -> Bool {
        guard case .recovery(let origin)? = profile.localOrigin else { return false }
        if let origin { return origin == account }
        if let previous = try persistence.deletionContext(profileID: profile.id) {
            guard previous.account == account else { return false }
        } else if try persistence.hasCloudAssociation(profileID: profile.id) {
            return false // Multiple known account owners require resolution instead of guessing.
        }
        guard profiles?.bindUnassignedRecoveryProfile(id: profile.id, to: account) == true else {
            throw SyncFailure.message("The recovery profile's Apple Account could not be saved on this device.")
        }
        return true
    }

    /// This device set a profile's unreadable document aside and started it again from nothing.
    /// Forget what iCloud last acknowledged for that document, so the next push is an insert that
    /// iCloud answers with the family's copy to merge rather than overwriting it, and pull every
    /// record again so that copy comes back without waiting for a push.
    func documentSetAside(id: String) {
        let name = "state-\(id)"
        uploads[name]?.cancel()
        uploads[name] = nil
        systemFields[name] = nil
        remoteStamps[name] = nil
        remoteStateDigests[name] = nil
        changeToken = nil
        do { try persistState() } catch { return } // No verified account: nothing was acknowledged.
        Task { await refresh(reason: "profile document set aside") }
    }

    public func stateChanged(_ state: ProfileState, id: String) {
        guard accountState?.profileIDs.contains(id) == true, !isTombstoned(id) else { return }
        schedule(key: "state-\(id)") { [weak self] in
            guard let self, let profiles, containsProfileInCurrentAccount(id) else { return }
            let expected = generation
            let prepared = try await ProfileCloudPreparation.prepare(profiles.storedState(id: id), acknowledgedDigest: remoteStateDigests["state-\(id)"])
            try check(expected)
            guard containsProfileInCurrentAccount(id), let record = record(for: prepared, profileID: id) else { return }
            try await save([record])
        }
    }

    private func schedule(key: String, _ work: @escaping () async throws -> Void) {
        guard isActive else { return }
        let expected = generation
        uploads[key]?.cancel()
        uploads[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, generation == expected, !Task.isCancelled else { return }
            do {
                try await work()
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                status = .failed(Self.describe(error))
                services.log("iCloud upload failed: \(Self.describe(error))")
                scheduleRetry(after: error)
            }
            if generation == expected { uploads[key] = nil }
        }
    }

    /// Reconciles profile-state fields with the server before retrying a changed record. One bad record
    /// makes CloudKit report "Atomic failure" for the others in the batch; those are retried on their
    /// own so the real problem, not its side effect, is what gets logged and shown.
    private func save(_ records: [CKRecord], conflictAttempt: Int = 0) async throws {
        let expected = generation
        let activeScope = try scope(expected)
        guard records.allSatisfy({ $0.recordID.zoneID == activeScope.zoneID }) else { throw CancellationError() }
        let records = records.filter { record in
            let id = record.recordType == "Profile" ? record.recordID.recordName : record["profileID"] as? String
            return id.map { containsProfileInCurrentAccount($0) } ?? true
        }
        guard !records.isEmpty else { return }
        let result = try await services.modify(activeScope, records, [])
        guard generation == expected else { throw CancellationError() }
        var acknowledgedDigests: [CKRecord.ID: String] = [:]
        for (id, outcome) in result.saved {
            if case .success(let saved) = outcome, saved.recordType == "ProfileState", let data = saved["document"] as? Data {
                acknowledgedDigests[id] = try await decodeProfileDocument(data).digest
                try check(expected)
            }
        }
        var returnedDeletedRecord = false
        for record in records {
            let profileID = record.recordType == "Profile" ? record.recordID.recordName : record["profileID"] as? String
            if let profileID, isTombstoned(profileID) {
                try retainDeletionForReturnedRecord(profileID)
                returnedDeletedRecord = true
            }
        }
        if returnedDeletedRecord {
            Task { await refresh(reason: "completed upload for a deleted profile") }
            throw CancellationError()
        }
        try check(expected)
        var retry: [CKRecord] = []
        var heldBack: [CKRecord] = []
        var missing: [CKRecord] = []
        var problem: (any Error)?
        for record in records {
            try check(expected)
            let id = record.recordID
            let profileID = record.recordType == "Profile" ? id.recordName : record["profileID"] as? String
            if let profileID, isTombstoned(profileID) { try retainDeletionForReturnedRecord(profileID); continue }
            let outcome = result.saved[id] ?? .failure(SyncFailure.message("iCloud did not acknowledge a saved record."))
            switch outcome {
            case .success(let saved):
                remember(saved)
                if let stamp = saved["updatedAt"] as? Date { remoteStamps[id.recordName] = stamp }
                if let digest = acknowledgedDigests[id] { remoteStateDigests[id.recordName] = digest }
                if record.recordType == "Family", let plan = familyInFlight {
                    familyInFlight = nil
                    recordFamilyUpload(plan.upload)
                    // Fields this device did not write stay unknown until a pull, rather than read as its own.
                    if plan.knowsRecord { family = plan.info }
                }
            case .failure(let error):
                guard let ours = records.first(where: { $0.recordID == id }) else { throw error }
                let ckError = error as? CKError
                if ckError?.code == .serverRecordChanged, let server = ckError?.serverRecord {
                    remember(server)
                    if ours.recordType == "ProfileState" {
                        // Applying merges into the newest durable local state, including edits made
                        // while this request was suspended. Retry with the server's current tag.
                        try await apply(server)
                        guard let profileID = ours["profileID"] as? String, let profiles else {
                            throw SyncFailure.message("The profile is unavailable for iCloud reconciliation.")
                        }
                        let latest = profiles.storedState(id: profileID)
                        let prepared = try await ProfileCloudPreparation.prepare(latest, acknowledgedDigest: remoteStateDigests[id.recordName])
                        try check(expected)
                        if isTombstoned(profileID) { try retainDeletionForReturnedRecord(profileID); continue }
                        if let merged = self.record(for: prepared, profileID: profileID) {
                            if conflictAttempt >= 3 {
                                problem = SyncFailure.message("iCloud changes are still arriving. Saved changes will be reconciled on the next sync.")
                            } else {
                                retry.append(merged)
                            }
                        }
                        continue
                    }
                    let serverStamp = server["updatedAt"] as? Date ?? .distantPast
                    let ourStamp = ours["updatedAt"] as? Date ?? .distantPast
                    if ourStamp > serverStamp {
                        if conflictAttempt >= 3 {
                            problem = SyncFailure.message("iCloud changes are still arriving. Saved changes will be reconciled on the next sync.")
                        } else {
                            // Include cleared fields and encrypted values, not just non-nil public fields.
                            let encryptedKeys = Set(ours.encryptedValues.changedKeys())
                            for key in ours.changedKeys() where !encryptedKeys.contains(key) { server[key] = ours[key] }
                            for key in encryptedKeys { server.encryptedValues[key] = ours.encryptedValues[key] }
                            retry.append(server)
                            if ours.recordType == "Family" { familyInFlight?.rebase(onto: try? Self.familyInfo(from: server)) }
                        }
                    } else {
                        try await apply(server)
                    }
                } else if ckError?.code == .unknownItem, conflictAttempt < 3,
                          systemFields[id.recordName] != nil || ours.recordChangeTag != nil {
                    missing.append(ours)
                } else if ckError?.code == .batchRequestFailed, records.count > 1 {
                    heldBack.append(ours)
                } else {
                    services.log("iCloud: could not save \(ours.recordType) \(id.recordName): \(Self.detail(error))")
                    if problem == nil { problem = SaveFailure(record: ours, underlying: error) }
                }
            }
        }
        try persistState()
        if !missing.isEmpty {
            let recovered = try await recoverMissingRecords(missing, expected: expected)
            // A recovery pull can observe a deletion of another record in this batch too.
            retry.removeAll { record in
                let id = record.recordType == "Profile" ? record.recordID.recordName : record["profileID"] as? String
                return id.map { !containsProfileInCurrentAccount($0) } ?? false
            }
            let recoveredIDs = Set(recovered.map(\.recordID))
            retry.removeAll { recoveredIDs.contains($0.recordID) }
            retry.append(contentsOf: recovered)
        }
        if !retry.isEmpty { try await save(retry, conflictAttempt: conflictAttempt + 1) }
        if let problem { throw problem }
        // Only side effects came back: the record that caused them is found by saving each alone.
        for record in heldBack { try await save([record], conflictAttempt: conflictAttempt) }
    }

    /// Cached revisions can outlive their records (for example when a development installation is
    /// replaced by TestFlight). Pull first so deletions and newer server edits win before rebuilding
    /// a rejected write. Never clear profiles, account ownership, or deletion tombstones to recover.
    private func recoverMissingRecords(_ missing: [CKRecord], expected: UUID) async throws -> [CKRecord] {
        let rejectedFields = systemFields
        try await fetchChanges()
        try check(expected)
        for record in missing {
            let name = record.recordID.recordName
            // A record returned by the pull has fresh metadata; retain it for conflict-safe saving.
            if systemFields[name] == rejectedFields[name] {
                systemFields[name] = nil
                remoteStamps[name] = nil
                remoteStateDigests[name] = nil
            }
            if record.recordType == "Profile" {
                // The document must remain pending even if the recovery save fails or the app exits.
                remoteStateDigests["state-\(name)"] = nil
            }
        }
        // Make the repair survive an offline retry or process termination before the next save.
        try persistState()
        var rebuilt: [CKRecord.ID: CKRecord] = [:]
        for missingRecord in missing {
            try check(expected)
            let name = missingRecord.recordID.recordName
            switch missingRecord.recordType {
            case "Profile", "ProfileState":
                let id = missingRecord.recordType == "Profile" ? name : missingRecord["profileID"] as? String
                guard let id, containsProfileInCurrentAccount(id), let profiles,
                      let latest = profiles.profiles.first(where: { $0.id == id }) else { continue }
                let state = profiles.storedState(id: id)
                let prepared = try await ProfileCloudPreparation.prepare(state, acknowledgedDigest: nil)
                try check(expected)
                guard containsProfileInCurrentAccount(id), let current = profiles.profiles.first(where: { $0.id == latest.id }) else { continue }
                if missingRecord.recordType == "Profile" {
                    let record = record(for: current)
                    rebuilt[record.recordID] = record
                }
                // A missing Profile may also have an unuploaded document whose old digest made
                // pushLocal skip it. Send it through the same revision/merge checks as ordinary saves.
                if let record = record(for: prepared, profileID: id) { rebuilt[record.recordID] = record }
            case "Family":
                guard isOwner, let profiles, let active = profiles.active,
                      containsProfileInCurrentAccount(active.id), let intent = familyInfoProvider?() else { continue }
                // Still missing after the pull: created again in full. Returned by it: planned against it.
                var plan = FamilyRecordPlan(intent: intent, lastUpload: accountState?.zones[zoneOwnerName]?.familyUpload,
                                            server: family, recreating: systemFields[name] == nil)
                guard plan.needsSave else { continue }
                plan.info.updatedAt = .now
                let record = record(for: plan)
                rebuilt[record.recordID] = record
                familyInFlight = plan
            default:
                throw SaveFailure(record: missingRecord, underlying: CKError(.unknownItem))
            }
        }
        return rebuilt.values.sorted { $0.recordID.recordName < $1.recordID.recordName }
    }

    /// A record CloudKit would not take, named so the message says what was lost.
    private struct SaveFailure: LocalizedError {
        let record: CKRecord
        let underlying: any Error

        var errorDescription: String? {
            let what: String
            switch record.recordType {
            case "Profile": what = "the profile “\(record["name"] as? String ?? "")”"
            case "ProfileState": what = "a profile's favourites and playlists"
            case "Family": what = "the family's server details"
            default: what = "a record"
            }
            return "Couldn't save \(what) to iCloud: \(CloudSync.describe(underlying))"
        }
    }

    // MARK: Records

    private func baseRecord(named name: String, type: String) -> CKRecord {
        if let data = systemFields[name], let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = true
            if let record = CKRecord(coder: unarchiver) { return record }
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    private func record(for profile: Profile) -> CKRecord {
        let record = baseRecord(named: profile.id, type: "Profile")
        record["name"] = profile.name
        record["symbol"] = profile.avatar.symbol
        record["colorHex"] = profile.avatar.colorHex
        Self.writePIN(profile.pin, to: record)
        record["role"] = profile.role.rawValue
        record["createdAt"] = profile.createdAt
        record["updatedAt"] = profile.updatedAt
        record["userRecordName"] = profile.userRecordName
        record["photoVersion"] = profile.avatar.photoVersion
        if let url = ProfileStore.photoURL(for: profile.id), profile.avatar.hasPhoto {
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
        return record
    }

    private func record(for state: PreparedProfileCloudState, profileID: String) -> CKRecord? {
        guard let data = state.document else { return nil }
        let record = baseRecord(named: "state-\(profileID)", type: "ProfileState")
        record["document"] = data
        record["profileID"] = profileID
        record["updatedAt"] = state.updatedAt
        return record
    }

    /// Sets only the fields the plan writes. CloudKit sends only the fields set on a record, so the
    /// others keep what iCloud has, in an ordinary save and in a conflict retry built from this record.
    private func record(for plan: FamilyRecordPlan) -> CKRecord {
        let info = plan.info
        let record = baseRecord(named: "family", type: "Family")
        record["updatedAt"] = info.updatedAt
        if plan.writesDetails {
            record["name"] = info.name
            record["address"] = info.provider?.kind == .synology || info.provider == nil ? info.address : nil
            let providerData: Data? = info.provider.flatMap { try? JSONEncoder().encode($0) }
            record["providerConnection"] = providerData as CKRecordValue?
            record["serverName"] = info.serverName
            record["serverAccount"] = info.serverAccount
            record["musicPath"] = info.musicPath
        }
        if plan.writesCredentials {
            record["familyAccount"] = info.familyAccount
            // End-to-end encrypted; the key is shared only with the family's participants.
            record.encryptedValues["familyPassword"] = info.familyPassword
        }
        return record
    }

    private func recordFamilyUpload(_ upload: FamilyRecordUpload) {
        if accountState?.zones[zoneOwnerName] == nil { accountState?.zones[zoneOwnerName] = .init() }
        accountState?.zones[zoneOwnerName]?.familyUpload = upload
    }

    private static func familyInfo(from record: CKRecord) throws -> FamilyInfo {
        let provider: ProviderConfiguration?
        if let stored = record["providerConnection"] {
            guard let data = stored as? Data else { throw ProviderError.invalidConfiguration }
            provider = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        } else { provider = nil }
        return FamilyInfo(
            name: record["name"] as? String ?? "Family",
            serverName: record["serverName"] as? String ?? "",
            serverAccount: record["serverAccount"] as? String ?? "",
            musicPath: record["musicPath"] as? String,
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            familyAccount: record["familyAccount"] as? String,
            familyPassword: record.encryptedValues["familyPassword"] as? String,
            address: record["address"] as? String,
            provider: provider
        )
    }

    /// What earlier versions find in `pinSalt` and `pinHash` once the verifier is encrypted: a PIN
    /// is set, and nothing typed matches it. They keep the profile locked rather than opening it.
    static let encryptedPINMarker = "encrypted"

    /// The PIN verifier travels end-to-end encrypted, like the family password, in fields of its own:
    /// an existing plain field can't become encrypted (#257). They must be in the production schema
    /// before a build that writes them ships; see docs/CLOUDKIT-PIN-VERIFIER-DEPLOYMENT.md.
    static func writePIN(_ pin: PINRecord?, to record: CKRecord) {
        record["pinSalt"] = pin.map { _ in encryptedPINMarker }
        record["pinHash"] = pin.map { _ in encryptedPINMarker }
        record.encryptedValues["pinVerifierSalt"] = pin?.salt
        record.encryptedValues["pinVerifierHash"] = pin?.hash
    }

    /// The plain fields say whether there is a PIN, as they did for earlier versions, which may still
    /// write them: a PIN they set or remove wins over an encrypted verifier left from before.
    static func pin(from record: CKRecord) -> PINRecord? {
        guard let salt = record["pinSalt"] as? String, let hash = record["pinHash"] as? String else { return nil }
        guard hash == encryptedPINMarker else { return PINRecord(salt: salt, hash: hash) }
        if let salt = record.encryptedValues["pinVerifierSalt"] as? String,
           let hash = record.encryptedValues["pinVerifierHash"] as? String {
            return PINRecord(salt: salt, hash: hash)
        }
        // Marked but unreadable here: the profile stays locked until its PIN is set again.
        return PINRecord(salt: salt, hash: hash)
    }

    private static func profile(from record: CKRecord) -> Profile? {
        guard let name = record["name"] as? String else { return nil }
        let pin = Self.pin(from: record)
        return Profile(
            id: record.recordID.recordName,
            name: name,
            avatar: ProfileAvatar(symbol: record["symbol"] as? String ?? "music.note", colorHex: record["colorHex"] as? String ?? "#4a2fd6", photoVersion: record["photoVersion"] as? Int),
            pin: pin,
            role: Profile.Role(rawValue: record["role"] as? String ?? "") ?? .member,
            createdAt: record["createdAt"] as? Date ?? .now,
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            userRecordName: record["userRecordName"] as? String
        )
    }

    private func remember(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        systemFields[record.recordID.recordName] = archiver.encodedData
    }

    // MARK: Sharing

    public struct SharingAuthorization {
        fileprivate let session: UUID?
        fileprivate let isOwner: Bool
    }

    /// Capture in the button action, before scheduling any unstructured task.
    public func sharingAuthorization() -> SharingAuthorization? {
        if let profiles {
            guard !profiles.isLocked else { return nil }
            let permitted = isOwner ? profiles.canManageProfiles
                : profiles.active?.userRecordName == currentUserRecordName && currentUserRecordName != nil
            guard permitted else { return nil }
        }
        return SharingAuthorization(session: profiles?.sessionID, isOwner: isOwner)
    }

    func checkSharingAuthorization(_ authorization: SharingAuthorization) throws {
        guard let current = sharingAuthorization(), current.session == authorization.session,
              current.isOwner == authorization.isOwner else { throw CancellationError() }
    }

    /// The share for the family zone, made on first use. Only the owner can call this.
    public func share(authorization supplied: SharingAuthorization? = nil) async throws -> CKShare {
        guard let authorization = supplied ?? sharingAuthorization(), authorization.isOwner else { throw CKError(.permissionFailure) }
        try checkSharingAuthorization(authorization)
        try await verifyIdentity(generation)
        try checkSharingAuthorization(authorization)
        let expected = generation
        _ = try scope(expected)
        guard membership == .owner else { throw CKError(.permissionFailure) }
        let database = database
        let recordID = shareRecordID
        let existing = try? await database.record(for: recordID) as? CKShare
        try check(expected)
        try checkSharingAuthorization(authorization)
        let share = existing ?? CKShare(recordZoneID: zoneID)
        let title = familyTitle
        if existing != nil, share.publicPermission == .readWrite, share.url != nil, share[CKShare.SystemFieldKey.title] as? String == title {
            update(share)
            return share
        }
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        if let photo = ownerPhotoData() {
            share[CKShare.SystemFieldKey.thumbnailImageData] = photo as CKRecordValue
        }
        // The app hands the link out itself, so anyone who opens it may join and write their own profile.
        share.publicPermission = .readWrite
        try checkSharingAuthorization(authorization)
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys, atomically: true)
        try check(expected)
        try checkSharingAuthorization(authorization)
        guard case .success(let saved) = result.saveResults[share.recordID], let savedShare = saved as? CKShare else {
            throw CKError(.internalError)
        }
        update(savedShare)
        services.log("\(existing == nil ? "Family share created" : "Family share updated"); link \(savedShare.url == nil ? "not ready yet" : "ready")")
        return savedShare
    }

    /// "Samuel's family", or a neutral name while the owner is still called "Me".
    public var familyTitle: String {
        let name = profiles?.owner?.name.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty, name.caseInsensitiveCompare("Me") != .orderedSame else { return "Gumbo family" }
        return "\(name)'s family"
    }

    private func ownerPhotoData() -> Data? {
        guard let owner = profiles?.owner, let url = ProfileStore.photoURL(for: owner.id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// An invitation link tapped on this device.
    public func accept(_ metadata: CKShare.Metadata) async {
        _ = await join(metadata)
    }

    /// An invitation link pasted into the app, for when the system opened it somewhere else. Any
    /// Apple Account can join this way; Family Sharing plays no part. Returns what went wrong, if anything.
    public func accept(url: URL) async -> String? {
        guard Self.isInvitation(url) else { return "That isn't a Gumbo invitation link. It starts with icloud.com/share." }
        let metadata: CKShare.Metadata
        var expected = generation
        do {
            try await verifyIdentity(expected)
            expected = generation
            metadata = try await container.shareMetadata(for: url)
            try check(expected)
        } catch {
            guard generation == expected, !(error is CancellationError) else { return "The Apple Account changed. Try the invitation again." }
            let message = Self.describeInvitation(error)
            services.log("Could not read the invitation link: \(Self.detail(error))")
            return message
        }
        return await join(metadata)
    }

    private func join(_ metadata: CKShare.Metadata) async -> String? {
        var expected = generation
        do {
            do {
                try await verifyIdentity(expected)
            } catch is CancellationError where currentUserRecordName != nil && !Task.isCancelled {
                // An invitation that launched Gumbo races the launch's own account check. When that
                // check revoked an account last verified here before verifying the current one, the
                // join continues under the account it verified instead of dropping the invitation.
                expected = generation
                try await verifyIdentity(expected)
            }
            expected = generation
            let owner = metadata.share.recordID.zoneID.ownerName
            if metadata.participantRole == .owner || Self.isOwnZone(owner, account: currentUserRecordName) {
                // The owner opened their own invitation: they already have the family (#252).
                services.log("Opened this family's own invitation; syncing instead of joining")
                await refresh(reason: "own invitation")
                return nil
            }
            _ = try await container.accept(metadata)
            try check(expected)
            try join(zoneOwnerName: owner)
            services.log("Joined the family shared by \(owner)")
            await refresh(reason: "joined family")
            return nil
        } catch {
            guard generation == expected, !(error is CancellationError) else { return "The Apple Account changed. Try the invitation again." }
            let message = Self.describeInvitation(error)
            status = .failed(message)
            services.log("Could not join the family: \(Self.detail(error))")
            return message
        }
    }

    /// Whether a URL is a CloudKit share link (the only kind of invitation Gumbo sends).
    public nonisolated static func isInvitation(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return (host == "www.icloud.com" || host == "icloud.com") && url.path().hasPrefix("/share/")
    }

    /// The invitation in text someone typed or pasted: a message may carry the link among other
    /// words, and a typed link often leaves out `https://`. Nil when there is no invitation.
    public nonisolated static func invitationURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed.split(whereSeparator: \.isWhitespace)
            .first { $0.lowercased().contains("icloud.com/share") }
            .map(String.init) ?? trimmed
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), ["https", "http"].contains(url.scheme?.lowercased()), isInvitation(url) else { return nil }
        return url
    }

    private nonisolated static func describeInvitation(_ error: any Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .unknownItem, .badContainer, .participantMayNeedVerification:
                return "This invitation isn't valid any more. Ask for a new link, and make sure both of you use the same version of Gumbo."
            case .alreadyShared, .tooManyParticipants:
                return "The family is full: up to five people can join."
            case .notAuthenticated:
                return "Sign in to iCloud in the Settings app first. Any Apple Account works; you don't need Family Sharing."
            default: break
            }
        }
        return describe(error)
    }

    /// A retry must stay attached to the Apple Account and family that requested it.
    public var sharingScopeIdentifier: String? {
        guard let account = currentUserRecordName else { return nil }
        return "\(account.utf8.count):\(account)\(zoneOwnerName.utf8.count):\(zoneOwnerName)"
    }

    /// Returns only after CloudKit acknowledges removal; callers must surface failures.
    public func stopSharing(authorization supplied: SharingAuthorization? = nil) async throws {
        guard let authorization = supplied ?? sharingAuthorization() else { throw CKError(.permissionFailure) }
        try checkSharingAuthorization(authorization)
        let expected = generation
        guard let requestedScope = sharingScopeIdentifier else { throw CKError(.notAuthenticated) }
        do {
            try await verifyIdentity(expected)
            try check(expected)
            guard sharingScopeIdentifier == requestedScope else { throw CancellationError() }
            let context = try scope(expected)
            let id = shareRecordID
            try checkSharingAuthorization(authorization)
            let result = try await services.modify(context, [], [id])
            try check(expected)
            guard let acknowledgement = result.deleted[id] else { throw CKError(.internalError) }
            switch acknowledgement {
            case .success: break
            case .failure(let error):
                if (error as? CKError)?.code != .unknownItem { throw error }
            }
            participants = []
            isShared = false
            if membership == .member {
                try persistState()
                guard var snapshot = accountState else { throw CKError(.notAuthenticated) }
                excludeFormerFamily(from: &snapshot)
                snapshot.membership = Membership.owner.rawValue
                snapshot.zoneOwner = CKCurrentUserDefaultName
                try installFamilyScope(snapshot)
                services.log("Left the family")
                await refresh(reason: "left family")
            } else {
                services.log("Stopped sharing the family")
            }
        } catch {
            if generation == expected, !(error is CancellationError) {
                services.log("Could not change the family share: \(Self.describe(error))")
                status = .failed(Self.describe(error))
            }
            throw error
        }
    }

    // MARK: Persistence

    private func persistState() throws {
        guard var snapshot = accountState, snapshot.account == currentUserRecordName else { throw CKError(.notAuthenticated) }
        snapshot.membership = membership.rawValue
        snapshot.zoneOwner = zoneOwnerName
        var zone = snapshot.zones[zoneOwnerName] ?? .init()
        zone.changeToken = changeToken
        zone.systemFields = systemFields
        zone.remoteStamps = remoteStamps
        zone.remoteStateDigests = remoteStateDigests
        snapshot.zones[zoneOwnerName] = zone
        try persistence.save(snapshot)
        accountState = snapshot
    }

    static let persistenceDirectory: URL = {
        let base = AppDirectories.support
            .appending(path: "Gumbo/cloud", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private nonisolated static func describe(_ error: any Error) -> String {
        if let failure = error as? SaveFailure { return failure.errorDescription ?? "" }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure: return "No internet connection."
            case .notAuthenticated: return "Not signed in to iCloud."
            case .quotaExceeded: return "iCloud storage is full."
            case .permissionFailure: return "iCloud refused the change."
            case .unknownItem: return "This item changed in iCloud. Your changes are still saved on this device. Try syncing again."
            case .batchRequestFailed: return "iCloud turned down a related change."
            case .zoneBusy, .requestRateLimited, .serviceUnavailable: return "iCloud is busy. It will try again."
            case .serverRejectedRequest, .invalidArguments: return "iCloud rejected the record. \(ckError.localizedDescription)"
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Everything the log needs to name the cause: the code, the message and what the server said.
    private nonisolated static func detail(_ error: any Error) -> String {
        guard let ckError = error as? CKError else { return "\(error)" }
        var parts = ["code \(ckError.code.rawValue) (\(ckError.code))", ckError.localizedDescription]
        if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("underlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)") }
        if let server = ckError.userInfo["ServerErrorDescription"] as? String { parts.append("server: \(server)") }
        if let retry = ckError.retryAfterSeconds { parts.append("retry after \(retry)s") }
        return parts.joined(separator: " · ")
    }
}

extension ProfileState {
    /// Nothing favourited, played or made: the profile was never used.
    var isPristine: Bool {
        settings == ProfileSettings() && (sync?.libraries.isEmpty ?? true)
            && libraries.values.allSatisfy {
                $0.favourites.isEmpty && $0.playlists.isEmpty && $0.played.isEmpty && $0.recentAlbums.isEmpty && $0.searches.isEmpty
            }
    }
}
