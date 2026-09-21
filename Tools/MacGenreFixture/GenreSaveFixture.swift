import AppKit
import SwiftUI
@testable import Gumbo
@testable import GumboCore

/// A sandboxed UI fixture, not a production provider. Only generated bundle resources are copied
/// into this fixture app's private container. There are no network or Keychain operations.
nonisolated struct FixtureDrive: WritableRemoteDrive {
    let id = "genre-save-writable-fixture"
    let displayName = "Generated Files"
    let folder: URL
    var capabilities: RemoteCapabilities { [.read, .ranges, .upload, .rename, .delete, .replace] }

    private func local(_ path: String) throws -> URL {
        guard path.hasPrefix("/fixture/") else { throw RemoteWriteError.missing }
        let name = String(path.dropFirst("/fixture/".count))
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw RemoteWriteError.missing }
        return folder.appending(path: name)
    }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func streamURL(for path: String) -> URL? { nil }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        // Deliberate fixture latency makes the production progress view observable.
        try await Task.sleep(for: .milliseconds(350))
        let handle = try FileHandle(forReadingFrom: local(path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: Int(range.count)) ?? Data()
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data {
        let data = try Data(contentsOf: local(path))
        guard data.count <= maxBytes else { throw RemoteDriveError.tooLarge }
        return data
    }
    func info(_ path: String) async throws -> RemoteEntry {
        let file = try local(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw RemoteWriteError.missing }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteWriteError.readOnly }
        return RemoteEntry(path: path, name: file.lastPathComponent, isDirectory: false,
                           size: values.fileSize.map(Int64.init), modified: values.contentModificationDate)
    }
    func upload(_ file: URL, toFolder path: String, name: String, modified: Date?) async throws {
        guard path == "/fixture" else { throw RemoteWriteError.readOnly }
        let destination = try local(path + "/" + name)
        try FileManager.default.copyItem(at: file, to: destination)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path) }
    }
    func rename(_ path: String, to name: String) async throws {
        try FileManager.default.moveItem(at: local(path), to: local("/fixture/" + name))
    }
    func delete(_ path: String) async throws { try FileManager.default.removeItem(at: local(path)) }
}

struct FixtureView: View {
    let library: LibraryStore
    let profiles: ProfileStore
    let albumMode: Bool
    let initialAlbum: Album?
    @State private var showEditor: Bool
    @State private var heartbeat = 0

    init(library: LibraryStore, profiles: ProfileStore, albumMode: Bool) {
        self.library = library; self.profiles = profiles; self.albumMode = albumMode
        initialAlbum = library.catalogue.albums.first
        _showEditor = State(initialValue: !albumMode)
    }

    var body: some View {
        Group {
            if albumMode, let album = initialAlbum {
                NavigationStack { MacAlbumDetailView(album: album) }
                    .frame(minWidth: 720, minHeight: 520)
            } else {
                genreHost
            }
        }
    }

    private var genreHost: some View {
        VStack(spacing: 18) {
            Text("Generated music only").font(.title)
            Text("Library genres: " + library.genres.map(\.name).joined(separator: ", "))
            Text("Songs: \(library.catalogue.trackCount)")
            Text("UI heartbeat: \(heartbeat)").monospacedDigit()
            Button("Edit Genre") { showEditor = true }
        }
        .frame(width: 560, height: 420)
        .sheet(isPresented: $showEditor) {
            if let genre = library.genres.first {
                GenreEditorSheet(genre: genre).environment(library).environment(profiles)
                    .frame(width: 520, height: 540)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                heartbeat += 1
            }
        }
    }
}

@main struct GenreSaveFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                // Refuse to run without sandbox isolation; the normal app cache must stay untouched.
                let support = AppDirectories.support
                guard support.path.contains("com.samuelvoltolini.gumbo.genre-write-fixture") else {
                    fatalError("Run the signed sandboxed fixture app, not a bare executable")
                }
                let run = support.appending(path: "genre-run-" + UUID().uuidString, directoryHint: .isDirectory)
                let music = run.appending(path: "music", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
                let originals = Bundle.main.resourceURL!.appending(path: "FixtureMusic", directoryHint: .isDirectory)
                let files = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                for file in files { try FileManager.default.copyItem(at: file, to: music.appending(path: file.lastPathComponent)) }
                let drive = FixtureDrive(folder: music)
                let profiles = ProfileStore(directory: run.appending(path: "profiles"), defaults: .standard)
                profiles.openAutomaticallyIfPossible()
                let library = LibraryStore()
                library.profiles = profiles
                let albumID = Album.makeID(title: "Generated fixture album", artist: "Gumbo fixture")
                var tracks: [Track] = []
                for (index, file) in files.enumerated() {
                    let path = "/fixture/" + file.lastPathComponent
                    let entry = try await drive.info(path)
                    tracks.append(Track(id: path, albumID: albumID, title: "Generated test audio", index: index,
                        number: index + 1, disc: 1, duration: 5, codec: file.pathExtension, sampleRate: 44100,
                        bitDepth: nil, bitrate: nil, fileSize: entry.size, path: path, format: file.pathExtension.uppercased(),
                        artist: "Gumbo fixture", albumTitleTag: "Generated fixture album", albumArtistTag: "Gumbo fixture",
                        yearTag: nil, genreTag: "Ambient", isEnriched: true))
                }
                let album = Album(id: albumID, title: "Generated fixture album", artist: "Gumbo fixture", year: 2026,
                    genre: "Ambient", label: nil, tracks: tracks, colorA: "000000", colorB: "D4D5D6", addedRank: 0,
                    folderPath: "/fixture", coverPath: nil, folderTitle: "Generated fixture album", folderArtist: "Gumbo fixture", folderYear: 2026)
                library.replace(with: Catalogue(serverName: "Generated Files", albums: [album], indexedAt: .now,
                    rootPath: "/fixture", driveID: drive.id), drive: drive)
                // No session restore, keychain lookup, server request or CloudKit container.
                let model = AppModel(library: library, defaults: .standard, services: ConnectionServices(), restoresSession: false)
                let token = UUID()
                library.fileDeletionConnectionTokenProvider = { token }
                let player = PlayerModel()
                let downloads = DownloadManager()
                let albumMode = ProcessInfo.processInfo.arguments.contains("--album-deletion")
                    || Bundle.main.object(forInfoDictionaryKey: "GumboFixtureAlbumMode") as? Bool == true
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 660),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = albumMode ? "Gumbo Generated Album Fixture" : "Gumbo Writable Genre Fixture"
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: FixtureView(library: library, profiles: profiles, albumMode: albumMode)
                    .environment(library).environment(profiles).environment(model).environment(player).environment(downloads).tint(.black))
                window.center()
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                try Data(run.path.utf8).write(to: support.appending(path: "latest-run.txt"))
                for _ in 0..<1800 {
                    try await Task.sleep(for: .milliseconds(200))
                    if library.catalogue.trackCount == 0 {
                        try Data("Deletion confirmed; generated album removed".utf8).write(to: run.appending(path: "album-deleted.txt"))
                    }
                    if library.catalogue.albums.flatMap(\.tracks).allSatisfy({ $0.genreTag == "Jazz" }) {
                        let data = try JSONEncoder().encode(library.catalogue)
                        try data.write(to: run.appending(path: "saved-catalogue.json"))
                    }
                }
                app.terminate(nil)
            } catch { fatalError("Fixture setup failed: \(error)") }
        }
        app.run()
    }
}
