import CryptoKit
import Foundation

/// What this device last sent in one family zone's Family record. Only digests are kept: of the
/// server details, and of this device's own Family Access credentials as identified by their
/// account and local revision. The password itself is never part of it.
nonisolated struct FamilyRecordUpload: Codable, Equatable, Sendable {
    var details: String
    /// Nil when this device held no credentials, so it neither sent nor cleared any.
    var credentials: String?

    init(_ intent: FamilyInfo) {
        details = Self.digest(Details(intent))
        if let account = intent.familyAccount, intent.familyPassword != nil {
            credentials = Self.digest([account, intent.credentialsRevision ?? ""])
        } else {
            credentials = nil
        }
    }

    private nonisolated struct Details: Encodable {
        let name: String
        let serverName: String
        let serverAccount: String
        let musicPath: String?
        let address: String?
        let provider: ProviderConfiguration?

        init(_ info: FamilyInfo) {
            name = info.name
            serverName = info.serverName
            serverAccount = info.serverAccount
            musicPath = info.musicPath
            address = info.address
            provider = info.provider
        }
    }

    private static func digest(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Strings, URLs and flags only: encoding cannot fail.
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What an owner's device writes to the Family record. The server details and the Family Access
/// credentials are each written only when this device changed them since its own last upload, so
/// the owner's devices converge instead of answering each other's uploads, and credentials kept on
/// another of the owner's devices are left in place instead of being cleared.
nonisolated struct FamilyRecordPlan: Equatable, Sendable {
    /// The record as it reads once saved: what this device writes, and iCloud's copy of the rest where known.
    var info: FamilyInfo
    var writesDetails: Bool
    var writesCredentials: Bool
    /// Becomes this device's last upload once CloudKit accepts the record, or at once when nothing needs sending.
    var upload: FamilyRecordUpload

    var needsSave: Bool { writesDetails || writesCredentials }

    /// - Parameters:
    ///   - intent: The owner's server details, with this device's own Family Access credentials, if any.
    ///   - lastUpload: What this device last sent to this family zone, if anything.
    ///   - server: The Family record as last read from iCloud, if known.
    ///   - recreating: The record is gone from iCloud and is being created again.
    init(intent: FamilyInfo, lastUpload: FamilyRecordUpload?, server: FamilyInfo?, recreating: Bool = false) {
        let upload = FamilyRecordUpload(intent)
        // A record being created again has nothing in iCloud to keep or to match.
        let known = recreating ? nil : server
        let writesDetails = recreating
            || (upload.details != lastUpload?.details && known?.hasSameServerDetails(as: intent) != true)
        var credentials = (account: intent.familyAccount, password: intent.familyPassword)
        let writesCredentials: Bool
        if upload.credentials != nil {
            // Held here: sent after being set up, rotated or re-entered on this device, or when iCloud
            // is known to have lost them. Otherwise another device's newer copy stays in place.
            let serverHasThem = known.map { $0.familyAccount == credentials.account && $0.familyPassword == credentials.password } ?? false
            let serverLostThem = known.map { $0.familyAccount == nil && $0.familyPassword == nil } ?? false
            writesCredentials = recreating
                || (!serverHasThem && (upload.credentials != lastUpload?.credentials || serverLostThem))
        } else if lastUpload?.credentials != nil {
            // Removed, revoked or no longer for this server here: clear what this device sent.
            writesCredentials = known.map { $0.familyAccount != nil || $0.familyPassword != nil } ?? true
        } else {
            // Never held here: the family keeps what it has, and a record created again gets it back.
            credentials = (server?.familyAccount, server?.familyPassword)
            writesCredentials = recreating && credentials.account != nil
        }
        let kept = known ?? intent
        var info = writesDetails ? intent : kept
        info.familyAccount = writesCredentials ? credentials.account : kept.familyAccount
        info.familyPassword = writesCredentials ? credentials.password : kept.familyPassword
        info.credentialsRevision = nil
        info.updatedAt = intent.updatedAt
        self.info = info
        self.writesDetails = writesDetails
        self.writesCredentials = writesCredentials
        self.upload = upload
    }
}
