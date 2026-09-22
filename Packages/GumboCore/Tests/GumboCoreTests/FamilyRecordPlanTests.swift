import Foundation
import Testing
@testable import GumboCore

/// What an owner's device writes to the Family record (#222, #250).
@Suite struct FamilyRecordPlanTests {
    private let details = FamilyInfo(name: "NAS family", serverName: "NAS", serverAccount: "owner", musicPath: "/music",
                                     updatedAt: .distantPast, address: "https://nas.example:5001")

    private func holding(_ password: String, revision: String?) -> FamilyInfo {
        var info = details
        info.familyAccount = "family-reader"
        info.familyPassword = password
        info.credentialsRevision = revision
        return info
    }

    /// The Family record as read from iCloud: no local revision, a server stamp.
    private func server(_ info: FamilyInfo, account: String?, password: String?) -> FamilyInfo {
        var copy = info
        copy.familyAccount = account
        copy.familyPassword = password
        copy.credentialsRevision = nil
        copy.updatedAt = Date(timeIntervalSince1970: 100)
        return copy
    }

    @Test func deviceWithoutFamilyAccessLeavesMatchingRecordAlone() {
        let plan = FamilyRecordPlan(intent: details, lastUpload: nil, server: server(details, account: "family-reader", password: "first"))
        #expect(!plan.needsSave)
        #expect(plan.upload.credentials == nil)
        #expect(plan.info.familyPassword == "first")
    }

    @Test func deviceWithoutFamilyAccessSendsItsDetailsOnceAndNeverTheCredentials() {
        var other = details
        other.name = "Owner's iPad family"
        let first = FamilyRecordPlan(intent: other, lastUpload: nil, server: server(details, account: "family-reader", password: "first"))
        #expect(first.writesDetails)
        #expect(!first.writesCredentials)
        #expect(first.info.name == "Owner's iPad family")
        #expect(first.info.familyPassword == "first")
        // Another device's rotation arriving later is not answered, and neither is a relaunch.
        let answered = FamilyRecordPlan(intent: other, lastUpload: first.upload, server: server(details, account: "family-reader", password: "rotated"))
        #expect(!answered.needsSave)
        #expect(answered.info.name == "NAS family")
        #expect(!FamilyRecordPlan(intent: other, lastUpload: first.upload, server: nil).needsSave)
    }

    /// Another address may reach the same NAS, so a device without Family Access never erases the
    /// family's credentials, even beside details it cannot match to the server they were made for.
    @Test func deviceWithoutFamilyAccessKeepsTheCredentialsBesideDetailsForAnotherAddress() {
        var moved = details
        moved.address = "https://192.168.1.20:5001"
        let plan = FamilyRecordPlan(intent: moved, lastUpload: FamilyRecordUpload(details),
                                    server: server(details, account: "family-reader", password: "first"))
        #expect(plan.writesDetails)
        #expect(!plan.writesCredentials)
        #expect(plan.info.address == "https://192.168.1.20:5001")
        #expect(plan.info.familyAccount == "family-reader")
        #expect(plan.info.familyPassword == "first")
    }

    @Test func recordPlannedWithoutICloudsCopyKnowsOnlyWhatItWrites() {
        var other = details
        other.name = "Owner's iPad family"
        // After a relaunch, iCloud's copy is unknown until it changes again.
        let detailsOnly = FamilyRecordPlan(intent: other, lastUpload: FamilyRecordUpload(details), server: nil)
        #expect(detailsOnly.writesDetails && !detailsOnly.writesCredentials)
        #expect(!detailsOnly.knowsRecord)
        #expect(FamilyRecordPlan(intent: holding("first", revision: "r1"), lastUpload: nil, server: nil).knowsRecord)
        #expect(FamilyRecordPlan(intent: other, lastUpload: nil, server: server(details, account: "family-reader", password: "first")).knowsRecord)
        #expect(FamilyRecordPlan(intent: other, lastUpload: FamilyRecordUpload(details), server: nil, recreating: true).knowsRecord)

        // A conflict is retried on top of iCloud's copy, which supplies everything not written here.
        var retried = detailsOnly
        retried.rebase(onto: server(details, account: "family-reader", password: "first"))
        #expect(retried.knowsRecord)
        #expect(retried.info.name == "Owner's iPad family")
        #expect(retried.info.familyAccount == "family-reader")
        #expect(retried.info.familyPassword == "first")
        var unreadable = FamilyRecordPlan(intent: other, lastUpload: nil, server: server(details, account: "family-reader", password: "first"))
        unreadable.rebase(onto: nil)
        #expect(!unreadable.knowsRecord)
    }

    @Test func credentialsHeldHereAreSentOnceAndAfterEachLocalChange() {
        let intent = holding("first", revision: "r1")
        let first = FamilyRecordPlan(intent: intent, lastUpload: nil, server: nil)
        #expect(first.writesDetails && first.writesCredentials)
        #expect(first.info.familyPassword == "first")
        #expect(first.info.credentialsRevision == nil)
        let relaunch = FamilyRecordPlan(intent: intent, lastUpload: first.upload, server: nil)
        #expect(!relaunch.needsSave)
        #expect(relaunch.info.familyPassword == "first")

        let rotation = FamilyRecordPlan(intent: holding("rotated", revision: "r2"), lastUpload: first.upload,
                                        server: server(details, account: "family-reader", password: "first"))
        #expect(!rotation.writesDetails)
        #expect(rotation.writesCredentials)
        #expect(rotation.info.familyPassword == "rotated")

        // Saved before revisions existed: sent once, then settled.
        let legacy = holding("first", revision: nil)
        let legacyFirst = FamilyRecordPlan(intent: legacy, lastUpload: nil, server: nil)
        #expect(legacyFirst.writesCredentials)
        #expect(!FamilyRecordPlan(intent: legacy, lastUpload: legacyFirst.upload, server: nil).needsSave)
    }

    @Test func staleCopyHeldHereDoesNotOverwriteAnotherDevicesRotation() {
        let intent = holding("first", revision: "r1")
        let plan = FamilyRecordPlan(intent: intent, lastUpload: FamilyRecordUpload(intent),
                                    server: server(details, account: "family-reader", password: "rotated"))
        #expect(!plan.needsSave)
        #expect(plan.info.familyPassword == "rotated")
    }

    @Test func credentialsLostFromICloudAreRestoredByTheDeviceHoldingThem() {
        let intent = holding("first", revision: "r1")
        let plan = FamilyRecordPlan(intent: intent, lastUpload: FamilyRecordUpload(intent),
                                    server: server(details, account: nil, password: nil))
        #expect(plan.writesCredentials)
        #expect(!plan.writesDetails)
        #expect(plan.info.familyPassword == "first")
    }

    @Test func removalHereClearsWhatThisDeviceSentOnce() {
        let sent = FamilyRecordUpload(holding("first", revision: "r1"))
        let removal = FamilyRecordPlan(intent: details, lastUpload: sent, server: nil)
        #expect(removal.writesCredentials)
        #expect(!removal.writesDetails)
        #expect(removal.info.familyAccount == nil && removal.info.familyPassword == nil)
        #expect(removal.upload.credentials == nil)
        #expect(FamilyRecordPlan(intent: details, lastUpload: sent, server: server(details, account: "family-reader", password: "first")).writesCredentials)
        #expect(!FamilyRecordPlan(intent: details, lastUpload: sent, server: server(details, account: nil, password: nil)).needsSave)
        // Once cleared, credentials another device sets up later stay in place.
        #expect(!FamilyRecordPlan(intent: details, lastUpload: removal.upload, server: server(details, account: "family-reader", password: "new")).needsSave)
    }

    @Test func recordCreatedAgainCarriesEverythingThisDeviceKnows() {
        let intent = holding("first", revision: "r1")
        let known = server(details, account: "family-reader", password: "first")
        let holder = FamilyRecordPlan(intent: intent, lastUpload: FamilyRecordUpload(intent), server: known, recreating: true)
        #expect(holder.writesDetails && holder.writesCredentials)
        let other = FamilyRecordPlan(intent: details, lastUpload: FamilyRecordUpload(details), server: known, recreating: true)
        #expect(other.writesDetails && other.writesCredentials)
        #expect(other.info.familyPassword == "first")
        let unknown = FamilyRecordPlan(intent: details, lastUpload: FamilyRecordUpload(details), server: nil, recreating: true)
        #expect(unknown.writesDetails && !unknown.writesCredentials)
        let removed = FamilyRecordPlan(intent: details, lastUpload: FamilyRecordUpload(intent), server: known, recreating: true)
        #expect(removed.writesCredentials)
        #expect(removed.info.familyPassword == nil)
    }

    @Test func uploadDigestsNeverContainThePassword() throws {
        let upload = FamilyRecordUpload(holding("secret-fixture", revision: "r1"))
        let data = try JSONEncoder().encode(upload)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-fixture"))
        #expect(FamilyRecordUpload(holding("other-password", revision: "r1")) == upload)
        #expect(FamilyRecordUpload(holding("secret-fixture", revision: "r2")) != upload)
    }

    /// Two of the owner's devices with different local views, each refreshing after the other's upload.
    @Test func ownerDevicesConvergeWithoutClearingCredentials() {
        struct Device {
            var intent: FamilyInfo
            var uploaded: FamilyRecordUpload?
        }
        var cloud: FamilyInfo?
        var writes = 0
        func sync(_ device: inout Device) {
            let plan = FamilyRecordPlan(intent: device.intent, lastUpload: device.uploaded, server: cloud)
            if plan.needsSave {
                var next = cloud ?? plan.info
                if plan.writesDetails {
                    next.name = plan.info.name
                    next.serverName = plan.info.serverName
                    next.serverAccount = plan.info.serverAccount
                    next.musicPath = plan.info.musicPath
                    next.address = plan.info.address
                    next.provider = plan.info.provider
                }
                if plan.writesCredentials {
                    next.familyAccount = plan.info.familyAccount
                    next.familyPassword = plan.info.familyPassword
                }
                cloud = next
                writes += 1
            }
            device.uploaded = plan.upload
        }
        var ipad = details
        ipad.name = "Owner's iPad family"
        var holder = Device(intent: holding("first", revision: "r1"))
        var other = Device(intent: ipad)
        for _ in 0..<10 { sync(&holder); sync(&other) }
        #expect(writes == 2)
        #expect(cloud?.familyPassword == "first")
        holder.intent = holding("rotated", revision: "r2")
        for _ in 0..<10 { sync(&other); sync(&holder) }
        #expect(writes == 3)
        #expect(cloud?.familyPassword == "rotated")
        #expect(cloud?.name == "Owner's iPad family")
    }
}
