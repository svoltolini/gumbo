import Foundation

public nonisolated enum WebDAVError: LocalizedError, Equatable, Sendable {
    case invalidAddress, invalidCredentials, unsafePath, authenticationRequired, forbidden, notFound
    case redirectRefused, invalidResponse, incompleteListing, rangeNotSupported, invalidRange

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter the full HTTPS address of the WebDAV folder, without sign-in details or a query in the address."
        case .invalidCredentials: "Enter a WebDAV username and password. The username cannot contain a colon."
        case .unsafePath: "The server returned a file outside the selected WebDAV folder."
        case .authenticationRequired: "The WebDAV sign-in was refused. Check your username and password."
        case .forbidden: "This account does not have permission to read that WebDAV folder."
        case .notFound: "The WebDAV file or folder could not be found."
        case .redirectRefused: "The WebDAV address redirects to another location. Enter its final HTTPS address."
        case .invalidResponse: "The WebDAV server returned an unreadable response."
        case .incompleteListing: "The WebDAV folder listing was incomplete. Your saved library has been kept; try refreshing again."
        case .rangeNotSupported: "This WebDAV server does not support the byte-range requests needed to read music files."
        case .invalidRange: "The WebDAV server returned the wrong part of the music file."
        }
    }
}

/// All RemoteDrive paths are decoded, absolute paths relative to this endpoint. Credentials and
/// URLs from a listing never become trusted addresses; every href is checked against this scope.
nonisolated struct WebDAVPathScope: Sendable {
    let baseURL: URL
    let origin: NASOrigin
    let rootComponents: [String]

    init(baseURL: URL) throws {
        guard let origin = NASOrigin(url: baseURL), origin.isHTTPS,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil else { throw WebDAVError.invalidAddress }
        let root: [String]
        do { root = try Self.decode(components.percentEncodedPath, requiresAbsolute: true, allowsEmpty: true) }
        catch { throw WebDAVError.invalidAddress }
        components.percentEncodedPath = Self.encoded(root, trailingSlash: true)
        guard let canonical = components.url else { throw WebDAVError.invalidAddress }
        self.baseURL = canonical
        self.origin = origin
        rootComponents = root
    }

    func url(for path: String, directory: Bool = false) throws -> URL {
        let parts = try Self.virtualComponents(path)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = Self.encoded(rootComponents + parts, trailingSlash: directory || parts.isEmpty)
        guard let url = components.url else { throw WebDAVError.unsafePath }
        return url
    }

    func path(for href: String, relativeTo requestURL: URL) throws -> String {
        guard let supplied = URLComponents(string: href), supplied.query == nil, supplied.fragment == nil,
              supplied.user == nil, supplied.password == nil else { throw WebDAVError.unsafePath }
        // Check before URL resolution, which would otherwise erase dot segments.
        _ = try Self.decode(supplied.percentEncodedPath, requiresAbsolute: false, allowsEmpty: false)
        guard let absolute = URL(string: href, relativeTo: requestURL)?.absoluteURL,
              NASOrigin(url: absolute) == origin,
              let components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else { throw WebDAVError.unsafePath }
        let parts = try Self.decode(components.percentEncodedPath, requiresAbsolute: true, allowsEmpty: false)
        guard parts.starts(with: rootComponents) else { throw WebDAVError.unsafePath }
        return "/" + parts.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func canonicalPath(_ path: String) throws -> String {
        "/" + (try virtualComponents(path)).joined(separator: "/")
    }

    private static func virtualComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { throw WebDAVError.unsafePath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let trimmed = parts.last == "" ? parts.dropLast() : parts[...]
        guard trimmed.allSatisfy({ valid(String($0)) }) else { throw WebDAVError.unsafePath }
        return trimmed.map(String.init)
    }

    private static func decode(_ encodedPath: String, requiresAbsolute: Bool, allowsEmpty: Bool) throws -> [String] {
        if encodedPath.isEmpty { if allowsEmpty { return [] }; throw WebDAVError.unsafePath }
        guard (!requiresAbsolute || encodedPath.hasPrefix("/")), !encodedPath.hasPrefix("//") else { throw WebDAVError.unsafePath }
        var pieces = encodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if pieces.first == "" { pieces.removeFirst() }
        if pieces.last == "" { pieces.removeLast() }
        return try pieces.map {
            guard let decoded = $0.removingPercentEncoding, valid(decoded) else { throw WebDAVError.unsafePath }
            return decoded
        }
    }

    private static func valid(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\\")
            && !component.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func encoded(_ parts: [String], trailingSlash: Bool) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let value = "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        return trailingSlash && value != "/" ? value + "/" : value
    }
}
