import Foundation

/// A bounded, namespace-aware DAV parser. Failed child responses invalidate the entire listing:
/// an inaccessible or truncated folder must never be evidence that cached songs were deleted.
nonisolated enum WebDAVListing {
    static let maximumBytes: Int64 = 8 * 1024 * 1024
    static let maximumEntries = 25_000

    static func parse(_ data: Data, scope: WebDAVPathScope, requestURL: URL, path: String, depth: Int) throws -> [RemoteEntry] {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), !text.uppercased().contains("<!DOCTYPE"),
              !text.uppercased().contains("<!ENTITY") else { throw WebDAVError.invalidResponse }
        let reader = DAVXMLReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, let root = reader.root, root.isDAV("multistatus") else {
            throw WebDAVError.invalidResponse
        }
        let expected = try WebDAVPathScope.canonicalPath(path)
        let responses = root.children.filter { $0.isDAV("response") }
        guard !responses.isEmpty, responses.count <= maximumEntries else { throw WebDAVError.incompleteListing }
        var entries: [RemoteEntry] = []
        var seen = Set<String>()
        for response in responses {
            let hrefs = response.dav("href")
            guard hrefs.count == 1 else { throw WebDAVError.incompleteListing }
            let entryPath = try scope.path(for: hrefs[0].text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: requestURL)
            guard seen.insert(entryPath).inserted else { throw WebDAVError.incompleteListing }
            if entryPath != expected {
                let parent = entryPath.split(separator: "/").dropLast().joined(separator: "/")
                guard depth == 1, "/" + parent == expected else { throw WebDAVError.incompleteListing }
            }
            for status in response.dav("status") {
                guard let code = statusCode(status.text), (200..<300).contains(code) else { throw WebDAVError.incompleteListing }
            }
            var properties: [String: DAVXMLNode] = [:]
            let propstats = response.dav("propstat")
            guard !propstats.isEmpty else { throw WebDAVError.incompleteListing }
            for propstat in propstats {
                guard propstat.dav("status").count == 1, let status = propstat.dav("status").first,
                      let code = statusCode(status.text), propstat.dav("prop").count == 1,
                      let prop = propstat.dav("prop").first else { throw WebDAVError.incompleteListing }
                // A 404 for optional metadata is normal. Missing resource type still fails below.
                guard code == 200 || code == 404 else { throw WebDAVError.incompleteListing }
                if code == 200 {
                    for property in prop.children where property.namespace == "DAV:" {
                        guard properties.updateValue(property, forKey: property.name) == nil else { throw WebDAVError.incompleteListing }
                    }
                }
            }
            guard let kind = properties["resourcetype"] else { throw WebDAVError.incompleteListing }
            let directory = kind.children.contains { $0.isDAV("collection") }
            if kind.children.contains(where: { !$0.isDAV("collection") }) { throw WebDAVError.incompleteListing }
            var size: Int64?
            if let value = properties["getcontentlength"]?.text.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                guard value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let parsed = Int64(value), parsed >= 0 else {
                    throw WebDAVError.incompleteListing
                }
                size = parsed
            }
            let modified = properties["getlastmodified"].flatMap { httpDate($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            // The path is the authoritative filename. A displayname can be unrelated or unsafe.
            let name = entryPath.split(separator: "/").last.map(String.init) ?? scope.baseURL.host ?? "WebDAV"
            let version = WebDAVDrive.strongETag(properties["getetag"]?.text.trimmingCharacters(in: .whitespacesAndNewlines))
            entries.append(RemoteEntry(path: entryPath, name: name, isDirectory: directory, size: directory ? nil : size, modified: modified, version: version))
        }
        guard let own = entries.first(where: { $0.path == expected }), depth != 1 || own.isDirectory else {
            throw WebDAVError.incompleteListing
        }
        return depth == 0 ? [own] : entries.filter { $0.path != expected }
    }

    private static func statusCode(_ value: String) -> Int? {
        let parts = value.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), parts[1].count == 3 else { return nil }
        return Int(parts[1])
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

private nonisolated final class DAVXMLNode {
    let name: String
    let namespace: String?
    var text = ""
    var children: [DAVXMLNode] = []
    init(name: String, namespace: String?) { self.name = name; self.namespace = namespace }
    func isDAV(_ name: String) -> Bool { namespace == "DAV:" && self.name == name }
    func dav(_ name: String) -> [DAVXMLNode] { children.filter { $0.isDAV(name) } }
}

private nonisolated final class DAVXMLReader: NSObject, XMLParserDelegate {
    var root: DAVXMLNode?
    var stack: [DAVXMLNode] = []
    var count = 0
    var invalid = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard count <= 400_000, stack.count < 32 else { invalid = true; parser.abortParsing(); return }
        let node = DAVXMLNode(name: elementName, namespace: namespaceURI)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { invalid = true; parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text.append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
        stack.last?.text.append(text)
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { invalid = true; parser.abortParsing(); return nil }
}
