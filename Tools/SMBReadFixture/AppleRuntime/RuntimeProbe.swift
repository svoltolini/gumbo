import SwiftUI
import Foundation
import GumboCore

@main struct SMBRuntimeProbe: App {
    @State private var message = "Checking the generated SMB fixture…"
    var body: some Scene {
        WindowGroup {
            Text(message).padding(40).task { await run() }
        }
    }
    @MainActor private func run() async {
        #if os(macOS)
        let destination = (ProcessInfo.processInfo.environment["GUMBO_SMB_REPORT_PATH"].map { URL(filePath: $0) } ?? URL.temporaryDirectory.appending(path: "GumboSMBRuntime-result.json"))
        #else
        let destination = URL.documentsDirectory.appending(path: "runtime-result.json")
        #endif
        var report: [String: String] = ["date": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString, "bundle": Bundle.main.bundleIdentifier ?? "", "endpoint": "127.0.0.1:14450", "fixture": "Samba generated read-only music", "result": "failed"]
        do {
            let drive = try SMBDrive(endpoint: URL(string: "smb://127.0.0.1:14450")!, share: "music", account: "gumbo-test", password: "fixture-only", sourceID: "runtime-fixture", security: .encrypted)
            try await drive.connect()
            let entries = try await drive.list("/folder")
            guard entries.contains(where: { $0.name == "音楽 & #.bin" }) else { throw ProbeFailure.wrongBytes }
            let path = "/folder/音楽 & #.bin"
            let stat = try await drive.info(path)
            let data = try await drive.read(path, range: 17..<4099)
            guard stat.size == 8193, data == Data((17..<4099).map { UInt8($0 % 251) }) else { throw ProbeFailure.wrongBytes }
            let checkpoint = destination.deletingLastPathComponent().appending(path: "probe.partial")
            try Data(repeating: 99, count: 2048).write(to: checkpoint)
            defer { try? FileManager.default.removeItem(at: checkpoint) }
            let copied = try await drive.copyVerified(path, to: checkpoint, expectedBytes: 8193) { _ in }
            guard copied == 8193, try Data(contentsOf: checkpoint) == Data((0..<8193).map { UInt8($0 % 251) }) else { throw ProbeFailure.wrongBytes }
            await drive.disconnect()
            report["result"] = "passed"
            report["verified"] = "encrypted authenticated connect, Unicode listing, same-handle stat, bounded read, protected full-prefix correction/copy, disconnect"
            report["bytes"] = "8193"
            message = "SMB runtime checks passed"
        } catch {
            report["error"] = String(describing: error)
            message = "SMB runtime check failed: \(error)"
        }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic) }
        catch { message += "\nCould not save report: \(error)" }
    }
}
private enum ProbeFailure: Error { case wrongBytes }
