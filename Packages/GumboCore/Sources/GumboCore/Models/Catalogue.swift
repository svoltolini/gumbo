import Foundation
import GumboShared

/// A folder on the drive that holds audio files, as found by the scan.
public nonisolated struct ScannedFolder: Sendable, Hashable {
    public let path: String
    public let audio: [RemoteEntry]
    public let cover: RemoteEntry?
    /// The cover image in the folder above, which is the album's own folder when this is a disc
    /// folder such as "CD1". That folder holds no music itself, so the scan keeps nothing else of it.
    public var parentCover: RemoteEntry? = nil
}

/// The indexed music library: albums with their tracks, plus where they came from.
public nonisolated struct Catalogue: Codable, Sendable {
    public var serverName: String
    public var albums: [Album]
    public var indexedAt: Date
    /// The folder that was indexed, e.g. "/music".
    public var rootPath: String
    public var driveID: String
    public private(set) var artworkPolicyVersion: Int

    init(serverName: String, albums: [Album], indexedAt: Date, rootPath: String, driveID: String) {
        self.serverName = serverName
        self.albums = albums
        self.indexedAt = indexedAt
        self.rootPath = rootPath
        self.driveID = driveID
        artworkPolicyVersion = ArtworkPolicy.version
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try values.decode(String.self, forKey: .serverName)
        albums = try values.decode([Album].self, forKey: .albums)
        indexedAt = try values.decode(Date.self, forKey: .indexedAt)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        driveID = try values.decode(String.self, forKey: .driveID)
        let storedPolicy = try? values.decode(Int.self, forKey: .artworkPolicyVersion)
        if storedPolicy != ArtworkPolicy.version {
            // Older JSON does not establish where its colours came from. Keep all music metadata
            // and reset only those colours; source-cache palettes are reapplied by LibraryStore.
            for index in albums.indices {
                let colours = ArtPalette.pair(for: albums[index].id)
                albums[index].colorA = colours.0
                albums[index].colorB = colours.1
            }
        }
        artworkPolicyVersion = ArtworkPolicy.version
    }

    public nonisolated static let empty = Catalogue(serverName: "", albums: [], indexedAt: .distantPast, rootPath: "", driveID: "")

    public var isEmpty: Bool { albums.isEmpty }
    public var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    public var enrichedTrackCount: Int { albums.reduce(0) { $0 + $1.tracks.filter(\.isEnriched).count } }
    public var totalBytes: Int64 { albums.reduce(0) { $0 + $1.totalBytes } }
    public var artistCount: Int { Set(albums.map(\.artist)).count }

    public var summary: String { "\(albums.count.formatted()) albums · \(ByteText.format(totalBytes))" }
    public var detail: String { "\(albums.count.formatted()) albums · \(artistCount.formatted()) artists · \(ByteText.format(totalBytes))" }
    public var rootName: String { rootPath.split(separator: "/").last.map(String.init) ?? "music" }

    // MARK: Building from a folder scan

    /// Groups scanned folders into albums using folder and file names; `existing` supplies tags already read.
    public nonisolated static func build(folders: [ScannedFolder], rootPath: String, serverName: String, driveID: String, existing: Catalogue?, forceMetadataReread: Bool = false) -> Catalogue {
        let reusable = existing?.driveID == driveID ? existing : nil
        let previous = Dictionary(reusable?.albums.flatMap(\.tracks).map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let rootName = rootPath.split(separator: "/").last.map(String.init) ?? "music"

        struct Draft {
            var guess: PathParser.AlbumGuess
            var folderPath: String
            var coverPath: String?
            var tracks: [Track] = []
            var newest: Double = 0
        }
        var drafts: [String: Draft] = [:]
        var order: [String] = []

        for folder in folders {
            let relative = folder.path.hasPrefix(rootPath) ? String(folder.path.dropFirst(rootPath.count)) : folder.path
            let components = relative.split(separator: "/").map(String.init)
            let guess = PathParser.album(components: components, rootName: rootName)
            let id = Album.makeID(title: guess.title, artist: guess.artist)
            if drafts[id] == nil {
                let albumFolder = guess.hasDiscFolder ? String(folder.path.split(separator: "/").dropLast().map { "/" + $0 }.joined()) : folder.path
                drafts[id] = Draft(guess: guess, folderPath: albumFolder.isEmpty ? folder.path : albumFolder)
                order.append(id)
            }
            if guess.hasDiscFolder, let albumCover = folder.parentCover {
                // The album folder's image beside "CD1" and "CD2" covers the whole album; it wins over
                // a picture inside one disc folder, as a folder without discs does below.
                drafts[id]!.coverPath = albumCover.path
            } else if drafts[id]!.coverPath == nil || guess.disc == nil, let cover = folder.cover {
                drafts[id]!.coverPath = cover.path
            }
            for file in folder.audio {
                let trackGuess = PathParser.track(fileName: file.name)
                let codec = codec(forExtension: file.fileExtension)
                var track = Track(
                    id: file.path, albumID: id, title: trackGuess.title, index: 0,
                    number: trackGuess.number ?? 0, disc: trackGuess.disc ?? guess.disc ?? 1,
                    duration: 0, codec: codec, sampleRate: nil, bitDepth: nil, bitrate: nil,
                    fileSize: file.size, path: file.path, format: FormatLabel.make(codec: codec, sampleRate: nil, bitrate: nil, bitDepth: nil),
                    artist: trackGuess.artist, albumTitleTag: nil, albumArtistTag: nil, yearTag: nil, genreTag: nil,
                    isEnriched: false
                )
                track.sourceModifiedAt = file.modified?.timeIntervalSince1970
                track.sourceVersion = file.version
                // A changed, newly available or missing timestamp schedules a reread. Keep the
                // last good tags until that read succeeds, including during an explicit reread.
                // Providers without timestamps use the size/path cache until the user rereads.
                if let known = previous[file.path] {
                    let needsReread = forceMetadataReread || known.fileSize != file.size
                        || known.sourceModifiedAt != track.sourceModifiedAt
                        || known.sourceVersion != track.sourceVersion
                    if known.isEnriched {
                        track = known
                        track.fileSize = file.size
                        track.sourceModifiedAt = file.modified?.timeIntervalSince1970
                        track.sourceVersion = file.version
                        track.normalizeDiscFromAlbumTag()
                    }
                    if needsReread {
                        track.tagVersion = nil
                        track.enrichAttempts = nil
                        track.enrichAttemptedAt = nil
                    } else {
                        track.enrichAttempts = known.enrichAttempts
                        track.enrichAttemptedAt = known.enrichAttemptedAt
                    }
                }
                drafts[id]!.tracks.append(track)
                if let modified = file.modified?.timeIntervalSince1970 { drafts[id]!.newest = max(drafts[id]!.newest, modified) }
            }
        }

        var albums: [Album] = order.compactMap { id in
            guard var draft = drafts[id], !draft.tracks.isEmpty else { return nil }
            draft.tracks.sort { lhs, rhs in
                if lhs.disc != rhs.disc { return lhs.disc < rhs.disc }
                let l = lhs.number == 0 ? Int.max : lhs.number
                let r = rhs.number == 0 ? Int.max : rhs.number
                if l != r { return l < r }
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
            for index in draft.tracks.indices {
                draft.tracks[index].index = index
                if draft.tracks[index].number == 0 { draft.tracks[index].number = index + 1 }
            }
            let colors = ArtPalette.pair(for: id)
            var album = Album(
                id: id, title: draft.guess.title, artist: draft.guess.artist, year: draft.guess.year ?? 0,
                genre: "Unknown genre", label: nil, tracks: draft.tracks, colorA: colors.0, colorB: colors.1,
                addedRank: Int(draft.newest), folderPath: draft.folderPath, coverPath: draft.coverPath,
                folderTitle: draft.guess.title, folderArtist: draft.guess.artist, folderYear: draft.guess.year
            )
            album.refreshFromTags()
            return album
        }
        albums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return Catalogue(serverName: serverName, albums: albums, indexedAt: .now, rootPath: rootPath, driveID: driveID)
    }

    /// Rebuilds albums from the tags read so far, so folders that mix albums split correctly and
    /// compilations stay together. Folder-based grouping remains for tracks without tags.
    public mutating func regroupByTags() {
        struct Draft {
            var template: Album
            var artist: String
            var tracks: [Track] = []
            var sources: Set<String> = []
        }
        let previous = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourceByTrack = Dictionary(albums.flatMap { album in album.tracks.map { ($0.id, album.id) } },
                                       uniquingKeysWith: { first, _ in first })
        var drafts: [String: Draft] = [:]
        var order: [String] = []
        // Start from physical album folders again, not the previous grouping. Enrichment can
        // publish several times and an earlier partial result must not permanently split a release.
        for album in Self.folderInputs(albums, rootPath: rootPath) {
            let folderArtist = album.folderArtist == "Unknown Artist" ? nil : album.folderArtist
            // A folder named for this release is stronger evidence than per-song album-artist
            // credits copied by some rippers. Mixed folders still respect distinct album artists.
            let isAlbumFolder = Self.isAlbumFolder(album.folderPath, title: album.title)
                || Self.hasConsistentReleaseCredits(album, rootPath: rootPath)
            var groups: [String: [Track]] = [:]
            var groupOrder: [String] = []
            for track in album.tracks {
                let title = (track.albumTitleTag.nonEmpty ?? album.folderTitle).lowercased()
                let key = title + "\u{1F}" + (isAlbumFolder ? "" : (track.albumArtistTag.nonEmpty?.lowercased() ?? ""))
                if groups[key] == nil { groupOrder.append(key) }
                groups[key, default: []].append(track)
            }
            for key in groupOrder where key.hasSuffix("\u{1F}") {
                let title = String(key.dropLast())
                let tagged = groupOrder.filter { $0 != key && $0.hasPrefix(title + "\u{1F}") && groups[$0] != nil }
                guard !tagged.isEmpty, let untagged = groups[key] else { continue }
                for track in untagged {
                    let credit = ArtistClustering.participants(track.artist ?? "")
                    let home = tagged.first { taggedKey in
                        let artist = String(taggedKey.dropFirst(title.count + 1))
                        return !credit.isEmpty && !ArtistClustering.participants(artist).isDisjoint(with: credit)
                    } ?? tagged.max { (groups[$0]?.count ?? 0) < (groups[$1]?.count ?? 0) }!
                    groups[home, default: []].append(track)
                }
                groups[key] = nil
            }
            for key in groupOrder {
                guard let tracks = groups[key], !tracks.isEmpty else { continue }
                let title = tracks.first?.albumTitleTag.nonEmpty ?? album.folderTitle
                let artists = ArtistClustering.assign(
                    tracks.map { ArtistClustering.Item(albumArtist: $0.albumArtistTag, artist: $0.artist) },
                    folderArtist: folderArtist
                )
                for (track, artist) in zip(tracks, artists) {
                    let id = Album.makeID(title: title, artist: artist)
                    if drafts[id] == nil {
                        drafts[id] = Draft(template: album, artist: artist)
                        order.append(id)
                    }
                    var moved = track
                    moved.albumID = id
                    drafts[id]!.tracks.append(moved)
                    drafts[id]!.sources.insert(sourceByTrack[track.id] ?? album.id)
                }
            }
        }
        var derivedCount: [String: Int] = [:]
        for id in order {
            for source in drafts[id]?.sources ?? [] { derivedCount[source, default: 0] += 1 }
        }
        var regrouped: [Album] = []
        for id in order {
            guard let draft = drafts[id], !draft.tracks.isEmpty else { continue }
            let ownsSources = draft.sources.allSatisfy { derivedCount[$0] == 1 }
            let template = draft.template
            let colors = ArtPalette.pair(for: id)
            let sourceAlbums = draft.sources.compactMap { previous[$0] }
            var album = Album(
                id: id, title: template.folderTitle, artist: template.folderArtist, year: template.year, genre: template.genre,
                label: nil, tracks: draft.tracks, colorA: colors.0, colorB: colors.1,
                addedRank: sourceAlbums.map(\.addedRank).max() ?? template.addedRank,
                folderPath: Self.commonDirectory(of: draft.tracks.compactMap(\.path)),
                coverPath: ownsSources ? sourceAlbums.compactMap(\.coverPath).first : nil,
                folderTitle: template.folderTitle, folderArtist: template.folderArtist, folderYear: template.folderYear
            )
            album.sortTracks()
            album.refreshFromTags()
            album.artist = draft.artist
            if id != template.id, ownsSources, !CoverStore.hasCover(for: id) {
                for source in draft.sources where CoverStore.hasCover(for: source) {
                    CoverStore.copy(from: source, to: id)
                    break
                }
            }
            Self.adoptTrackCoverIfNeeded(for: album)
            regrouped.append(album)
        }
        albums = Self.mergingSameTitles(regrouped).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private nonisolated static func isAlbumFolder(_ path: String?, title: String) -> Bool {
        guard let name = path?.split(separator: "/").last.map(String.init) else { return false }
        let clean = PathParser.splitDisc(PathParser.splitYear(PathParser.clean(name)).0).title
        let guessed = PathParser.album(components: [name], rootName: name).title
        let normalizedTitle = PathParser.clean(title)
        return clean.caseInsensitiveCompare(normalizedTitle) == .orderedSame
            || guessed.caseInsensitiveCompare(normalizedTitle) == .orderedSame
    }

    /// Recover a shortened release title only when its physical folder still identifies it,
    /// and guest credits include the lead artist alone. A generic mixed folder or two different
    /// collaborations do not establish a release. Positions are an additional conflict check,
    /// not proof of source tags: the indexer can infer them from file names.
    private nonisolated static func hasConsistentReleaseCredits(_ album: Album, rootPath: String) -> Bool {
        guard let folder = album.folderPath, folder != rootPath, album.tracks.count > 1,
              Self.hasShortenedFolderTitle(folder, title: album.title),
              album.tracks.allSatisfy({ $0.isEnriched && $0.albumTitleTag.nonEmpty != nil && $0.number > 0 }) else { return false }
        var positions: Set<String> = []
        var lead: String?
        var standaloneLeads: Set<String> = []
        for track in album.tracks {
            guard positions.insert("\(track.disc):\(track.number)").inserted,
                  let credit = track.albumArtistTag.nonEmpty ?? track.artist.nonEmpty,
                  let first = ArtistClustering.splitParticipants(credit).first?.lowercased(),
                  first != "unknown artist", first != "various artists" else { return false }
            if let lead, lead != first { return false }
            if credit.caseInsensitiveCompare(first) == .orderedSame { standaloneLeads.insert(first) }
            lead = first
        }
        return lead.map { standaloneLeads.contains($0) } ?? false
    }

    private nonisolated static func hasShortenedFolderTitle(_ folder: String, title: String) -> Bool {
        func words(_ value: String) -> [String] {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let titleWords = words(title)
        guard titleWords.count >= 2 else { return false }
        let name = (folder as NSString).lastPathComponent
        let clean = PathParser.splitDisc(PathParser.splitYear(PathParser.clean(name)).0).title
        let guessed = PathParser.album(components: [name], rootName: name).title
        return [clean, guessed].contains { name in
            let folderWords = words(name)
            return folderWords.count > titleWords.count && folderWords.starts(with: titleWords)
        }
    }

    /// Coalesce tracks by physical folder and tagged title so cached splits can heal on a normal scan.
    /// A CD/Disc subfolder belongs to its parent; sibling "Album (Disc N)" folders share a logical path.
    private nonisolated static func folderInputs(_ albums: [Album], rootPath: String) -> [Album] {
        var inputs: [String: Album] = [:]
        var order: [String] = []
        for album in albums {
            for original in album.tracks {
                var track = original
                track.normalizeDiscFromAlbumTag()
                let title = track.albumTitleTag.nonEmpty ?? album.folderTitle
                var folder = track.path.map { ($0 as NSString).deletingLastPathComponent } ?? album.folderPath
                if let current = folder {
                    let name = (current as NSString).lastPathComponent
                    if PathParser.discNumber(in: name) != nil, current != rootPath {
                        folder = (current as NSString).deletingLastPathComponent
                    } else {
                        let split = PathParser.splitDisc(name)
                        if split.disc != nil {
                            folder = ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(split.title)
                        }
                    }
                }
                let key = (folder ?? album.id) + "\u{1F}" + PathParser.clean(title).lowercased()
                if inputs[key] == nil {
                    var input = album
                    input.title = title
                    input.folderPath = folder
                    input.tracks = []
                    inputs[key] = input
                    order.append(key)
                }
                inputs[key]!.tracks.append(track)
            }
        }
        return order.compactMap { inputs[$0] }
    }

    /// Cross-folder grouping requires the same album artist identity. Shared title or guest
    /// credits alone cannot establish that two folders contain the same album.
    public nonisolated static func mergingSameTitles(_ albums: [Album]) -> [Album] {
        var groups: [String: [Album]] = [:]
        var order: [String] = []
        for album in albums {
            let key = Album.makeID(title: album.title, artist: album.artist)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(album)
        }
        return order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            return group.count == 1 ? first : combine(group, artist: first.artist)
        }
    }

    /// One album out of several that share a title, filed under `artist`; the biggest one lends its details and cover.
    nonisolated private static func combine(_ group: [Album], artist: String) -> Album {
        let primary = group.max { $0.tracks.count < $1.tracks.count } ?? group[0]
        let id = Album.makeID(title: primary.title, artist: artist)
        var tracks = group.flatMap(\.tracks)
        for index in tracks.indices { tracks[index].albumID = id }
        let colors = ArtPalette.pair(for: id)
        var album = Album(
            id: id, title: primary.title, artist: artist, year: primary.year, genre: primary.genre, label: primary.label,
            tracks: tracks, colorA: colors.0, colorB: colors.1,
            addedRank: group.map(\.addedRank).max() ?? primary.addedRank,
            folderPath: commonDirectory(of: tracks.compactMap(\.path)),
            coverPath: primary.coverPath,
            folderTitle: primary.folderTitle, folderArtist: primary.folderArtist, folderYear: primary.folderYear
        )
        album.sortTracks()
        album.refreshFromTags()
        album.artist = artist
        if !CoverStore.hasCover(for: id) {
            for source in group.sorted(by: { $0.tracks.count > $1.tracks.count }) where CoverStore.hasCover(for: source.id) {
                CoverStore.copy(from: source.id, to: id)
                break
            }
        }
        adoptTrackCoverIfNeeded(for: album)
        diagnostics("Merged \(group.count) albums titled “\(primary.title)” (\(group.map(\.artist).joined(separator: " / "))) under \(artist)")
        return album
    }

    /// An album without a cover takes the picture embedded in one of its songs, if one was saved.
    public nonisolated static func adoptTrackCoverIfNeeded(for album: Album) {
        guard !CoverStore.hasCover(for: album.id) else { return }
        if let track = album.tracks.first(where: { CoverStore.hasTrackCover(for: $0.id) }) {
            CoverStore.adoptTrackCover(from: track.id, for: album.id)
        }
    }

    /// Whether a scan made before hidden files were ignored saved this catalogue: it lists a "._"
    /// twin as a song or as an album's cover, which no scan does now.
    var listsHiddenFiles: Bool {
        albums.contains { album in
            (album.coverPath.map { RemoteDriveSupport.isHidden(($0 as NSString).lastPathComponent) } ?? false)
                || album.tracks.contains(where: \.isHiddenFile)
        }
    }

    /// Such scans could save "._Cover (Front).jpg", which holds only Finder metadata, as a cover:
    /// the folder's album's, then the albums regrouping copied it to, or a song's picture its album
    /// adopted. An album with a cover never looks for one again, so forget those by their content,
    /// before regrouping can copy them on, and the cover pass fetches the real picture. Only needed
    /// after such a catalogue, or with none of this folder to tell (covers outlive a switch to another
    /// folder and back), so a healed library is not looked through on every refresh.
    nonisolated static func discardFinderMetadataCovers(previous: Catalogue?, driveID: String, rootPath: String) {
        if let previous, previous.driveID == driveID, previous.rootPath == rootPath, !previous.listsHiddenFiles { return }
        let removed = CoverStore.removeFinderMetadata()
        if removed > 0 { diagnostics("Discarded \(removed) covers read from hidden files; they are looked up again") }
    }

    /// Longest directory prefix shared by every path.
    public nonisolated static func commonDirectory(of paths: [String]) -> String? {
        guard var common = paths.first.map({ Array($0.split(separator: "/").dropLast()) }) else { return nil }
        for path in paths.dropFirst() {
            let parts = Array(path.split(separator: "/").dropLast())
            var matched = 0
            while matched < min(common.count, parts.count), common[matched] == parts[matched] { matched += 1 }
            common = Array(common.prefix(matched))
            if common.isEmpty { break }
        }
        return common.isEmpty ? nil : "/" + common.joined(separator: "/")
    }

    /// The album that currently holds a track, wherever regrouping has moved it.
    public func album(containing trackID: String) -> Album? {
        albums.first { album in album.tracks.contains { $0.id == trackID } }
    }

    /// Songs this catalogue lists that a newer complete listing no longer has. Hidden "._" files kept
    /// by a catalogue saved before scans ignored them were not deleted from the server: reported as
    /// deletions, they would stop playback and add a lasting download and Watch marker for each one.
    func removedTrackIDs(present: Set<String>) -> Set<String> {
        Set(albums.flatMap(\.tracks).filter { !$0.isHiddenFile }.map(\.id)).subtracting(present)
    }

    /// Replaces one track with its enriched version and refreshes its album's tags. The track is
    /// found by id, since regrouping may have moved it to another album since it was queued.
    public mutating func apply(_ track: Track) {
        let albumIndex = albums.firstIndex { $0.id == track.albumID && $0.tracks.contains { $0.id == track.id } }
            ?? albums.firstIndex { album in album.tracks.contains { $0.id == track.id } }
        guard let albumIndex, let trackIndex = albums[albumIndex].tracks.firstIndex(where: { $0.id == track.id }) else { return }
        var moved = track
        moved.albumID = albums[albumIndex].id
        albums[albumIndex].tracks[trackIndex] = moved
        albums[albumIndex].sortTracks()
        albums[albumIndex].refreshFromTags()
    }

    public nonisolated static func codec(forExtension ext: String) -> String {
        switch ext {
        case "flac": "flac"
        case "mp3": "mp3"
        case "m4a", "mp4", "aac": "aac"
        case "alac": "alac"
        case "wav": "wav"
        case "aif", "aiff": "aiff"
        case "ogg", "oga": "ogg"
        case "opus": "opus"
        case "wma": "wma"
        case "ape": "ape"
        case "wv": "wavpack"
        case "dsf", "dff": "dsd"
        default: ext
        }
    }

    // MARK: Folder tree

    public func folderTree() -> FolderNode {
        final class Builder {
            var children: [String: Builder] = [:]
            var tracks: [Track] = []
        }
        let root = Builder()
        for album in albums {
            for track in album.tracks {
                guard let path = track.path else { continue }
                let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
                var node = root
                for directory in relative.split(separator: "/").dropLast() {
                    let key = String(directory)
                    if let child = node.children[key] {
                        node = child
                    } else {
                        let child = Builder()
                        node.children[key] = child
                        node = child
                    }
                }
                node.tracks.append(track)
            }
        }
        func materialize(_ name: String, _ path: String, _ builder: Builder) -> FolderNode {
            let subfolders = builder.children
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { materialize($0.key, path + "/" + $0.key, $0.value) }
            let tracks = builder.tracks.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            return FolderNode(name: name, path: path, subfolders: subfolders, tracks: tracks)
        }
        return materialize(rootName, rootPath, root)
    }
}

/// Short human readable format badges such as "FLAC 24/96", "FLAC 44.1 kHz" or "MP3 320".
public nonisolated enum FormatLabel {
    public static func make(codec: String, sampleRate: Int?, bitrate: Int?, bitDepth: Int?) -> String {
        let name: String = switch codec {
        case "flac": "FLAC"
        case "alac": "ALAC"
        case "mp3": "MP3"
        case "aac": "AAC"
        case "dsd": "DSD"
        case "wav": "WAV"
        case "aiff": "AIFF"
        case "ogg": "OGG"
        case "opus": "Opus"
        case "wma": "WMA"
        case "ape": "APE"
        case "wavpack": "WavPack"
        case "pcm": "PCM"
        default: codec.isEmpty ? "Audio" : codec.uppercased()
        }
        if Track.losslessCodecs.contains(codec) {
            guard let sampleRate, sampleRate > 0 else { return name }
            if sampleRate >= 1_000_000 { return "\(name) \(String(format: "%.1f", Double(sampleRate) / 1_000_000)) MHz" }
            let khz = Double(sampleRate) / 1000
            let rate = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            if let bitDepth, bitDepth > 0 { return "\(name) \(bitDepth)/\(rate)" }
            return "\(name) \(rate) kHz"
        }
        guard let bitrate, bitrate > 0 else { return name }
        return "\(name) \(bitrate / 1000)"
    }
}

nonisolated extension Optional where Wrapped == String {
    public var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
