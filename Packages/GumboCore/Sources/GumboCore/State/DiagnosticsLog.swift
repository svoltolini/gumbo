import Foundation

/// In-app event log so problems on the phone can be read without a debugger.
@Observable
public final class DiagnosticsLog {
    public static let shared = DiagnosticsLog()

    public struct Entry: Identifiable, Hashable {
        public let id = UUID()
        public let date: Date
        public let message: String
    }

    public private(set) var entries: [Entry] = []

    /// Kept on disk so a problem can be read after a relaunch, or pulled off the device.
    public static let fileURL: URL = {
        let directory = AppDirectories.support.appending(path: "Gumbo")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "diagnostics.log")
    }()

    /// Writes, trims and clears the file on a background queue, in the order they were asked for.
    private static let file = DiagnosticsLogFile(url: fileURL)

    private init() {
        entries = Self.loadEntries()
        Self.file.trimIfNeeded()
    }

    public func record(_ message: String) {
        let entry = Entry(date: .now, message: message)
        entries.append(entry)
        if entries.count > DiagnosticsLogFile.keptLines { entries.removeFirst(entries.count - DiagnosticsLogFile.keptLines) }
        let line = entry.date.formatted(.iso8601) + "\t" + entry.message.replacingOccurrences(of: "\n", with: " ") + "\n"
        Self.file.append(Data(line.utf8))
    }

    public func clear() {
        entries.removeAll()
        Self.file.clear()
    }

    /// Reads only the end of the file, so a log left large by an earlier version never stalls launch.
    private static func loadEntries() -> [Entry] {
        guard let text = DiagnosticsLogFile.tail(of: fileURL, maxBytes: DiagnosticsLogFile.maximumBytes) else { return [] }
        let lines = text.split(separator: "\n").suffix(DiagnosticsLogFile.keptLines)
        return lines.compactMap { line in
            guard let tab = line.firstIndex(of: "\t"), let date = try? Date(String(line[..<tab]), strategy: .iso8601) else { return nil }
            return Entry(date: date, message: String(line[line.index(after: tab)...]))
        }
    }

    public var text: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { "\(formatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
    }
}

/// The log file on disk. Every access happens on one serial queue, off the main thread; once the
/// file grows past `maximumBytes` it is cut back to its last `keptLines` lines.
nonisolated final class DiagnosticsLogFile: @unchecked Sendable {
    static let maximumBytes = 256 * 1024
    static let keptLines = 300

    let url: URL
    private let queue = DispatchQueue(label: "gumbo.diagnostics-log", qos: .utility)
    /// Only touched on `queue`.
    private var size: Int?

    init(url: URL) {
        self.url = url
    }

    func append(_ data: Data) {
        queue.async { self.write(data) }
    }

    func clear() {
        queue.async {
            try? Data().write(to: self.url)
            self.size = 0
        }
    }

    /// Measures the file afresh, then trims it if it is over the cap.
    func trimIfNeeded() {
        queue.async {
            self.size = nil
            self.trim()
        }
    }

    /// Returns once everything asked for so far has reached the file.
    func waitUntilWritten() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            size = Int(end) + data.count
        } else {
            try? data.write(to: url)
            size = data.count
        }
        trim()
    }

    private func trim() {
        let current = size ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        size = current
        guard current > Self.maximumBytes, let text = Self.tail(of: url, maxBytes: Self.maximumBytes) else { return }
        let lines = text.split(separator: "\n").suffix(Self.keptLines)
        let kept = lines.isEmpty ? Data() : Data((lines.joined(separator: "\n") + "\n").utf8)
        do {
            try kept.write(to: url, options: .atomic)
            size = kept.count
        } catch {
            size = nil
        }
    }

    /// The last `maxBytes` of the file, starting at a whole line.
    static func tail(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return start == end ? "" : nil }
        let text = String(decoding: data, as: UTF8.self)
        guard start > 0 else { return text }
        guard let newline = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: newline)...])
    }
}

/// Records from any isolation domain.
public nonisolated func diagnostics(_ message: String) {
    Task { @MainActor in
        DiagnosticsLog.shared.record(message)
    }
}
