import CryptoKit
import Foundation

/// Protocol choice is independent of the brand printed on a NAS enclosure.
public nonisolated enum NASProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case synology, webDAV, smb
    public var id: Self { self }
    public var title: String {
        switch self { case .synology: "Synology"; case .webDAV: "WebDAV"; case .smb: "SMB" }
    }
}

/// Versioned, non-secret connection details. Passwords remain in a provider-scoped Keychain item.
/// A missing configuration on an old ServerConnection means DSM; an unknown version never does.
public nonisolated struct ProviderConfiguration: Codable, Hashable, Sendable {
    public let version: Int
    public let kind: NASProviderKind
    public let endpoint: URL
    public let share: String?
    public let domain: String?
    public let requiresEncryption: Bool

    public init(kind: NASProviderKind, endpoint: URL, share: String? = nil, domain: String? = nil,
                requiresEncryption: Bool = true) throws {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw ProviderError.invalidConfiguration }
        let scheme = components.scheme?.lowercased()
        switch kind {
        case .synology:
            guard NASOrigin(url: endpoint) != nil else { throw ProviderError.invalidConfiguration }
        case .webDAV:
            guard scheme == "https", share == nil, domain == nil else { throw ProviderError.secureConnectionRequired }
        case .smb:
            guard scheme == "smb", endpoint.path.isEmpty || endpoint.path == "/",
                  let share, !share.isEmpty, ![".", ".."].contains(share),
                  !share.contains(where: { "/\\\0".contains($0) }) else { throw ProviderError.invalidConfiguration }
        }
        let pathComponents = endpoint.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathComponents.contains(".."), !pathComponents.contains("."), !endpoint.path.contains("\0") else {
            throw ProviderError.invalidConfiguration
        }
        var canonical = components
        canonical.scheme = scheme
        canonical.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let canonicalHost = canonical.host, !canonicalHost.isEmpty,
              !canonicalHost.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw ProviderError.invalidConfiguration }
        if scheme == "https" && canonical.port == 443 || scheme == "smb" && canonical.port == 445 { canonical.port = nil }
        if kind == .webDAV { canonical.path = endpoint.path.hasSuffix("/") ? endpoint.path : endpoint.path + "/" }
        self.version = 1
        self.kind = kind
        guard let canonicalURL = canonical.url else { throw ProviderError.invalidConfiguration }
        self.endpoint = canonicalURL
        self.share = share
        self.domain = domain?.isEmpty == true ? nil : domain
        self.requiresEncryption = requiresEncryption
    }

    private enum CodingKeys: String, CodingKey { case version, kind, endpoint, share, domain, requiresEncryption }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw ProviderError.unsupportedVersion }
        try self.init(kind: values.decode(NASProviderKind.self, forKey: .kind),
                      endpoint: values.decode(URL.self, forKey: .endpoint),
                      share: values.decodeIfPresent(String.self, forKey: .share),
                      domain: values.decodeIfPresent(String.self, forKey: .domain),
                      requiresEncryption: values.decode(Bool.self, forKey: .requiresEncryption))
    }

    public func sourceID(account: String) -> String {
        if kind == .synology { return NASSource.identifier(baseURL: endpoint, account: account) }
        // JSON framing prevents delimiter collisions. Share, realm, path and protocol are identity boundaries.
        let fields = [kind.rawValue, endpoint.absoluteString, share ?? "", domain ?? "", account]
        let data = try! JSONEncoder().encode(fields)
        return "nas-v3-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public nonisolated enum ProviderError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration, unsupportedVersion, secureConnectionRequired, unavailableOnDevice
    case authenticationRequired, permissionDenied, missing, changed, incompleteListing, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Check the server address, protocol and shared folder. Don't include a password in the address."
        case .unsupportedVersion: "This connection was created by a newer version of Gumbo. Update Gumbo to open it."
        case .secureConnectionRequired: "Use the server's HTTPS WebDAV address with a trusted certificate."
        case .unavailableOnDevice: "This connection isn't available directly on this device. Use your iPhone to transfer downloads."
        case .authenticationRequired: "The server rejected this sign-in. Check the account and password."
        case .permissionDenied: "This account doesn't have access to that folder."
        case .missing: "The file or folder is no longer on the server."
        case .changed: "The file changed on the server. Refresh your library and try again."
        case .incompleteListing: "The server didn't return the complete folder. Your library has been kept unchanged."
        case .invalidResponse: "The server returned an unexpected response."
        }
    }
}

public nonisolated struct RemoteCapabilities: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let read = Self(rawValue: 1 << 0)
    public static let ranges = Self(rawValue: 1 << 1)
    public static let backgroundDownload = Self(rawValue: 1 << 2)
    public static let upload = Self(rawValue: 1 << 3)
    public static let rename = Self(rawValue: 1 << 4)
    public static let delete = Self(rawValue: 1 << 5)
    /// Reviewed staging/backup replacement. This alone does not promise an atomic compare-and-swap.
    public static let replace = Self(rawValue: 1 << 6)
    public static let manageAccounts = Self(rawValue: 1 << 7)
    /// Reserved for providers with a verified atomic version condition; none currently advertise it.
    public static let conditionalReplace = Self(rawValue: 1 << 8)

    public var supportsTagReplacement: Bool { isSuperset(of: [.read, .ranges, .upload, .rename, .delete, .replace]) }
}

nonisolated extension Error {
    /// Applies only while opening a connection. A file ACL denial during playback is not a
    /// reason to forget a valid password or replace the catalogue.
    var requiresProviderSignIn: Bool {
        if let error = self as? ProviderError { return error == .authenticationRequired || error == .permissionDenied }
        if let error = self as? WebDAVError { return error == .authenticationRequired || error == .forbidden }
        if let error = self as? SMBDriveError { return error == .credentialsRequired || error == .authenticationRequired || error == .permissionDenied }
        return false
    }
}
