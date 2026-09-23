import Foundation
import Testing
@testable import GumboCore

@Suite("Diagnostics log file")
struct DiagnosticsLogFileTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "gumbo-diagnostics-\(UUID().uuidString).log")
    }

    @Test func fileIsCutBackToTheLastLinesOnceItPassesTheCap() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = DiagnosticsLogFile(url: url)
        let filler = String(repeating: "x", count: 200)
        let count = DiagnosticsLogFile.maximumBytes / 200 + 50
        for index in 0..<count {
            file.append(Data("line \(index) \(filler)\n".utf8))
        }
        file.waitUntilWritten()
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= DiagnosticsLogFile.maximumBytes)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count < count)
        #expect(lines.last?.hasPrefix("line \(count - 1) ") == true)
    }

    @Test func oversizedFileLeftByAnEarlierVersionIsTrimmedAndOnlyItsTailIsRead() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let line = String(repeating: "y", count: 99) + "\n"
        try Data(String(repeating: line, count: DiagnosticsLogFile.maximumBytes / 50).utf8).write(to: url)
        let tail = try #require(DiagnosticsLogFile.tail(of: url, maxBytes: 1000))
        #expect(tail.utf8.count <= 1000)
        #expect(tail.hasPrefix("y"))
        let file = DiagnosticsLogFile(url: url)
        file.trimIfNeeded()
        file.waitUntilWritten()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == DiagnosticsLogFile.keptLines)
    }

    @Test func clearEmptiesTheFileAfterPendingWrites() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = DiagnosticsLogFile(url: url)
        file.append(Data("first\n".utf8))
        file.clear()
        file.append(Data("second\n".utf8))
        file.waitUntilWritten()
        #expect(try String(contentsOf: url, encoding: .utf8) == "second\n")
    }
}
