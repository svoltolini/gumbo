import CryptoKit
import Foundation

/// One atomic snapshot per verified Apple Account. Family zones never share a cursor or record tag.
struct CloudAccountState: Codable {
    struct Zone: Codable {
        var changeToken: Data?
        var systemFields: [String: Data] = [:]
        var remoteStamps: [String: Date] = [:]
        /// Optional for snapshots saved before per-field profile-state reconciliation existed.
        var remoteStateDigests: [String: String]? = nil
        /// Kept after acknowledgement too: delayed pages must never resurrect a deleted profile.
        var deletions: [String: Set<String>] = [:]
        /// What this device last sent in the Family record (or found iCloud already holding), recorded
        /// only once CloudKit has accepted it, so a failed upload is sent again.
        var familyUpload: FamilyRecordUpload? = nil

        /// Forgets what was fetched from the zone, so the next pull reads every record in it again.
        /// Deletion intents stay: a profile deleted here must not come back with the rest.
        mutating func forgetFetchedRecords() {
            changeToken = nil
            systemFields = [:]
            remoteStamps = [:]
            remoteStateDigests = nil
            familyUpload = nil
        }
    }

    var account: String
    var membership = "owner"
    var zoneOwner: String
    var subscribed = false
    /// Local profiles known to belong to this account; a different account cannot upload them.
    var profileIDs: Set<String> = []
    var zones: [String: Zone] = [:]
    var retiredFamilyProfileIDs: Set<String>? = nil
}

struct CloudPersistence {
    let directory: URL

    func hasSnapshot(account: String) -> Bool { FileManager.default.fileExists(atPath: file(account: account).path) }

    /// Offline deletion can target a previously verified scope without treating it as the signed-in
    /// account. Ambiguous ownership waits for verification instead of choosing an account silently.
    func deletionContext(profileID: String) throws -> CloudAccountState? {
        let matches = try accountSnapshots().filter { $0.profileIDs.contains(profileID) }
        return matches.count == 1 ? matches.first : nil
    }

    func hasCloudAssociation(profileID: String) throws -> Bool {
        if try accountSnapshots().contains(where: { $0.profileIDs.contains(profileID) }) { return true }
        // Before migration, old global record metadata is evidence that local profiles may exist remotely.
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "legacy-profile-account.json").path) else { return false }
        return ["cloud-system-fields.json", "cloud-remote-stamps.json"].contains {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    func pendingFamilyRetirements() throws -> Set<String> {
        try accountSnapshots().reduce(into: Set<String>()) { $0.formUnion($1.retiredFamilyProfileIDs ?? []) }
    }

    private func accountSnapshots() throws -> [CloudAccountState] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var snapshots: [CloudAccountState] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("account-") && url.pathExtension == "json" {
            let state = try JSONDecoder().decode(CloudAccountState.self, from: Data(contentsOf: url))
            guard file(account: state.account).lastPathComponent == url.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
            snapshots.append(state)
        }
        return snapshots
    }

    /// Old profile files have no account provenance. Only the first verified account may adopt them.
    func claimsLegacyProfiles(account: String) throws -> Bool {
        let url = directory.appending(path: "legacy-profile-account.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(String.self, from: Data(contentsOf: url)) == account
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: url, options: .atomic)
        return true
    }

    func load(account: String, defaultOwner: String) throws -> CloudAccountState {
        let url = file(account: account)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CloudAccountState(account: account, zoneOwner: defaultOwner)
        }
        let state = try JSONDecoder().decode(CloudAccountState.self, from: Data(contentsOf: url))
        guard state.account == account else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }

    func save(_ state: CloudAccountState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file(account: state.account), options: .atomic)
    }

    /// The account last verified on this device, until an account change revokes what it granted. A
    /// launch that first verifies another one learns that it was replaced while Gumbo was not running.
    func verifiedAccount() -> String? {
        guard let data = try? Data(contentsOf: verifiedAccountFile) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    func saveVerifiedAccount(_ account: String?) throws {
        guard let account else {
            guard FileManager.default.fileExists(atPath: verifiedAccountFile.path) else { return }
            try FileManager.default.removeItem(at: verifiedAccountFile)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: verifiedAccountFile, options: .atomic)
    }

    private var verifiedAccountFile: URL { directory.appending(path: "verified-account.json") }

    private func file(account: String) -> URL {
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "account-\(key).json")
    }
}
