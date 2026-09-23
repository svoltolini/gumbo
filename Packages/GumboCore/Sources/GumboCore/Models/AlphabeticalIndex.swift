import Foundation

/// Splits a list into A–Z groups, for screens such as CarPlay's that cap how many rows a list holds.
public nonisolated enum AlphabeticalIndex {
    /// "A" to "Z" by the first letter, accents and case ignored; "#" for digits, symbols and other scripts.
    public static func letter(for name: String) -> String {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        guard let first = folded.unicodeScalars.first, ("a"..."z").contains(first) else { return "#" }
        return String(first).uppercased()
    }

    /// The groups in A–Z order with "#" last, keeping the given order within each group.
    public static func groups<Element>(_ elements: [Element], name: (Element) -> String) -> [(letter: String, elements: [Element])] {
        var byLetter: [String: [Element]] = [:]
        for element in elements { byLetter[letter(for: name(element)), default: []].append(element) }
        return byLetter.keys
            .sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }
            .map { ($0, byLetter[$0] ?? []) }
    }

    /// Consecutive ranges of at most `size` indices covering `count` elements.
    public static func pages(count: Int, size: Int) -> [Range<Int>] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }
}
