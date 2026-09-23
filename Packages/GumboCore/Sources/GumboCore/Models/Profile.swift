import CommonCrypto
import CryptoKit
import Foundation

/// A person using the app. Kept on the device for now and shaped as one record plus one state
/// document, so the same data can move to a CloudKit family zone later without changing screens.
public nonisolated struct Profile: Codable, Identifiable, Hashable, Sendable {
    public nonisolated enum Role: String, Codable, Sendable {
        case owner, member
    }

    /// Local bookkeeping only; omitted from CloudKit records. Optional for older profile files.
    public nonisolated enum LocalOrigin: Codable, Hashable, Sendable {
        case created
        case recovery(account: String?)
    }

    public var id: String
    public var name: String
    public var avatar: ProfileAvatar
    /// Set when the profile asks for a PIN before it opens.
    public var pin: PINRecord?
    public var role: Role
    public var createdAt: Date
    public var updatedAt: Date
    /// The iCloud user this profile belongs to, once it has synced from a device signed in as them.
    public var userRecordName: String? = nil
    public var localOrigin: LocalOrigin? = nil

    public var isLocked: Bool { pin != nil }

    public nonisolated static let limit = 6

    public init(id: String, name: String, avatar: ProfileAvatar, pin: PINRecord?, role: Role, createdAt: Date, updatedAt: Date, userRecordName: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.pin = pin
        self.role = role
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userRecordName = userRecordName
    }
}

/// What a family shares besides its people: the server the music lives on, so a member's device can
/// connect without typing addresses.
public nonisolated struct FamilyInfo: Codable, Sendable, Equatable {
    public var name: String
    public var serverName: String
    public var serverAccount: String
    public var musicPath: String?
    public var updatedAt: Date
    /// A read-only account on the NAS made for the family, so members connect without the owner's password.
    public var familyAccount: String? = nil
    public var familyPassword: String? = nil
    /// The server's URL as the owner reaches it: a DDNS name, or an address on the home network.
    public var address: String? = nil
    public var provider: ProviderConfiguration? = nil
    /// Local only, never uploaded: changes whenever this device saves new family credentials, so
    /// sync sends them after a change made here rather than over another device's newer copy.
    public var credentialsRevision: String? = nil

    public init(name: String, serverName: String, serverAccount: String, musicPath: String?, updatedAt: Date, familyAccount: String? = nil, familyPassword: String? = nil, address: String? = nil, provider: ProviderConfiguration? = nil, credentialsRevision: String? = nil) {
        self.name = name
        self.serverName = serverName
        self.serverAccount = serverAccount
        self.musicPath = musicPath
        self.updatedAt = updatedAt
        self.familyAccount = familyAccount
        self.familyPassword = familyPassword
        self.address = provider?.kind == .synology || provider == nil ? address : nil
        self.provider = provider
        self.credentialsRevision = credentialsRevision
    }

    /// Whether members have a way to reach the server at all.
    public var isReachable: Bool { provider != nil || address != nil }

    public func connection(account: String) throws -> ServerConnection {
        guard let endpoint = provider?.endpoint ?? address.flatMap(URL.init(string:)) else { throw ProviderError.invalidConfiguration }
        return ServerConnection(name: serverName, baseURL: endpoint, account: account, musicPath: musicPath, provider: provider)
    }

    /// The same server details, whatever the timestamps and credentials say.
    public func hasSameServerDetails(as other: FamilyInfo) -> Bool {
        name == other.name && provider == other.provider && address == other.address && serverName == other.serverName
            && serverAccount == other.serverAccount && musicPath == other.musicPath
    }
}

/// The family's read-only NAS account as kept by the owner's device.
public nonisolated struct FamilyAccess: Sendable, Equatable {
    public var account: String
    public var password: String
    public var sourceID: String

    public init(account: String, password: String, sourceID: String) {
        self.account = account
        self.password = password
        self.sourceID = sourceID
    }
}

/// A photo when the person picked one, otherwise their initials on a colour chosen for them.
/// `symbol` is kept for profiles made before photos existed.
public nonisolated struct ProfileAvatar: Codable, Hashable, Sendable {
    public var symbol: String
    public var colorHex: String
    /// Counts photo changes, so screens and other devices know when to load it again; nil means no photo.
    public var photoVersion: Int? = nil

    public var hasPhoto: Bool { photoVersion != nil }

    public init(symbol: String, colorHex: String, photoVersion: Int? = nil) {
        self.symbol = symbol
        self.colorHex = colorHex
        self.photoVersion = photoVersion
    }

    /// "Ana Kestrel" → "AK", "Me" → "M".
    public static func initials(for name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    public static let symbols = [
        "music.note", "headphones", "guitars.fill", "pianokeys", "music.mic", "waveform",
        "star.fill", "heart.fill", "sparkles", "moon.stars.fill", "sun.max.fill", "bolt.fill",
        "leaf.fill", "flame.fill", "snowflake", "pawprint.fill", "gamecontroller.fill", "airplane",
        "sailboat.fill", "bicycle", "cup.and.saucer.fill", "camera.fill", "book.fill", "globe.europe.africa.fill",
    ]

    public static let colors = [
        "#d4234f", "#e07a2f", "#d4a017", "#5c9e1c", "#0d9488", "#2a9dd6",
        "#4a2fd6", "#8f7dff", "#c93a7a", "#b8622e", "#1f3a8a", "#3d4a5c",
    ]

    public static func random() -> ProfileAvatar {
        ProfileAvatar(symbol: symbols.randomElement() ?? "music.note", colorHex: colors.randomElement() ?? "#4a2fd6")
    }
}

/// A salted, deliberately slow hash of a four digit PIN; the PIN itself is never stored.
///
/// `hash` is self-describing: `pbkdf2-sha256$<iterations>$<base64 key>` for PBKDF2-HMAC-SHA256, or,
/// for records made by earlier versions, 64 hex digits of one salted SHA-256. Both still open the
/// profile; an earlier record is derived again the slow way, under the same salt, once its PIN is
/// entered correctly (#257). The saved JSON shape (`salt`, `hash`) stays the same.
public nonisolated struct PINRecord: Codable, Hashable, Sendable {
    public let salt: String
    public let hash: String

    /// About 50–100 ms on a recent iPhone or Apple TV: unnoticeable at the keypad, and 10,000 PINs
    /// cost far more than one salted SHA-256 each.
    static let iterations = 200_000
    /// Bounds on what a record may ask for, so a damaged or hostile record can't freeze the device.
    private static let acceptedIterations = 10_000...2_000_000
    private static let scheme = "pbkdf2-sha256"

    public static func make(_ pin: String) -> PINRecord {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        // The derivation can't fail with these arguments; were it to, the older digest still works.
        return PINRecord(salt: salt, hash: derivedHash(salt: salt, pin: pin, iterations: iterations) ?? legacyDigest(salt: salt, pin: pin))
    }

    public func matches(_ pin: String) -> Bool {
        let expected: String?
        if isLegacy {
            expected = Self.legacyDigest(salt: salt, pin: pin)
        } else if let iterations = derivationIterations {
            expected = Self.derivedHash(salt: salt, pin: pin, iterations: iterations)
        } else {
            expected = nil // Neither format: nothing opens it.
        }
        guard let expected else { return false }
        return Self.constantTimeEquals(expected, hash)
    }

    /// Made by an earlier version: one salted SHA-256, cheap to try every PIN against.
    public var isLegacy: Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The same PIN derived the slow way under the same salt, for a legacy record the PIN matches.
    public func upgraded(with pin: String) -> PINRecord? {
        guard isLegacy, matches(pin), let derived = Self.derivedHash(salt: salt, pin: pin, iterations: Self.iterations) else { return nil }
        return PINRecord(salt: salt, hash: derived)
    }

    /// Whether this record is `earlier` derived again the slow way: the same salt, so the same PIN
    /// as far as this device can tell, rather than a new PIN that would call for a new opening.
    public func isUpgrade(of earlier: PINRecord) -> Bool {
        earlier.isLegacy && !isLegacy && derivationIterations != nil && salt == earlier.salt
    }

    private var derivationIterations: Int? {
        let parts = hash.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.scheme, let iterations = Int(parts[1]),
              Self.acceptedIterations.contains(iterations), !parts[2].isEmpty else { return nil }
        return iterations
    }

    private static func derivedHash(salt: String, pin: String, iterations: Int) -> String? {
        let password = Array(pin.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = Array(salt.utf8)
        let length = 32
        var key = [UInt8](repeating: 0, count: length)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count, saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, length)
        guard status == kCCSuccess else { return nil }
        return "\(scheme)$\(iterations)$\(Data(key).base64EncodedString())"
    }

    private static func legacyDigest(salt: String, pin: String) -> String {
        SHA256.hash(data: Data((salt + ":" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// What a profile keeps for one library (one drive): favourites, plays, lists and searches.
public nonisolated struct LibraryState: Codable, Sendable, Equatable {
    public var favourites: [String] = []
    public var playlists: [LocalPlaylist] = []
    /// Track ids, newest first.
    public var played: [String] = []
    /// Album ids, newest first.
    public var recentAlbums: [String] = []
    public var searches: [String] = []
    /// Album ids marked for offline download. Files may need re-fetch from NAS; this is the membership list.
    public var downloadedAlbums: [String] = []
    /// Playlist ids marked for offline download. Files may need re-fetch from NAS; this is the membership list.
    public var downloadedPlaylists: [String] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favourites = try container.decodeIfPresent([String].self, forKey: .favourites) ?? []
        playlists = try container.decodeIfPresent([LocalPlaylist].self, forKey: .playlists) ?? []
        played = try container.decodeIfPresent([String].self, forKey: .played) ?? []
        recentAlbums = try container.decodeIfPresent([String].self, forKey: .recentAlbums) ?? []
        searches = try container.decodeIfPresent([String].self, forKey: .searches) ?? []
        downloadedAlbums = try container.decodeIfPresent([String].self, forKey: .downloadedAlbums) ?? []
        downloadedPlaylists = try container.decodeIfPresent([String].self, forKey: .downloadedPlaylists) ?? []
    }
}

/// A profile's preferences, the same on every library.
public nonisolated struct ProfileSettings: Codable, Sendable, Equatable {
    public var quality = "Lossless"
    public var gapless = true
    public var appearance = "Auto"
    public var hidesBracketedTitleParts = false
    public var repeatMode = "off"
    public var shuffle = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? "Lossless"
        gapless = try container.decodeIfPresent(Bool.self, forKey: .gapless) ?? true
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "Auto"
        hidesBracketedTitleParts = try container.decodeIfPresent(Bool.self, forKey: .hidesBracketedTitleParts) ?? false
        repeatMode = try container.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
        shuffle = try container.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
    }
}

/// Everything a profile saves. Per-field revisions merge independent edits within the document.
public nonisolated struct ProfileState: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey { case libraries, settings, updatedAt, sync, syncData }
    /// Keyed by drive id; the sample library uses "".
    public var libraries: [String: LibraryState] = [:]
    public var settings = ProfileSettings()
    public var updatedAt = Date.distantPast
    /// Optional so existing v1.0 documents can be migrated without resetting their saved data.
    var sync: ProfileStateSync?

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraries = try container.decodeIfPresent([String: LibraryState].self, forKey: .libraries) ?? [:]
        settings = try container.decodeIfPresent(ProfileSettings.self, forKey: .settings) ?? ProfileSettings()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        if let compressed = try container.decodeIfPresent(Data.self, forKey: .syncData) {
            sync = try ProfileStateSyncCodec.decode(compressed)
        } else {
            sync = try container.decodeIfPresent(ProfileStateSync.self, forKey: .sync)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(libraries, forKey: .libraries)
        try container.encode(settings, forKey: .settings)
        try container.encode(updatedAt, forKey: .updatedAt)
        if let sync { try container.encode(ProfileStateSyncCodec.encode(sync), forKey: .syncData) }
    }
}
