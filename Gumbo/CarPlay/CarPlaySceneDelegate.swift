#if os(iOS)
import CarPlay
import GumboCore
import UIKit

/// The car's screen. CarPlay hands the app an interface controller when the phone connects; the
/// controller below fills it with the library, the playlists, the albums and the artists as lists, and hands
/// playback to the system's Now Playing screen, driven by the same player as the phone.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        guard let library = AppDelegate.library, let player = AppDelegate.player,
              let profiles = AppDelegate.profiles, let model = AppDelegate.model else { return }
        controller = CarPlayController(interface: interfaceController, library: library, player: player, profiles: profiles, model: model)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.disconnect()
        controller = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppDelegate.model?.scenePhaseChanged(.active)
    }
}

/// Builds and refreshes the car's templates.
@MainActor
final class CarPlayController {
    private let interface: CPInterfaceController
    private let library: LibraryStore
    private let player: PlayerModel
    private let profiles: ProfileStore
    private let model: AppModel

    private var libraryTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var albumsTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    /// What the root currently shows, so a change in readiness swaps it and a change in content only updates it.
    private var rootKind: RootKind?
    private var rootContext: BrowseContext?
    private var isConnected = true
    private var playbackRequest = UUID()

    /// A list selection belongs to the authenticated opening and server that created it.
    private struct BrowseContext: Equatable {
        let sessionID: UUID?
        let driveID: String
    }

    private var browseContext: BrowseContext {
        BrowseContext(sessionID: profiles.sessionID, driveID: library.catalogue.driveID)
    }

    private enum RootKind: Equatable {
        case notSetUp, locked, tabs
    }

    /// How many entries a list carries; the car reads short lists best and CarPlay caps them anyway.
    private static var listLimit: Int { min(100, CPListTemplate.maximumItemCount) }

    init(interface: CPInterfaceController, library: LibraryStore, player: PlayerModel, profiles: ProfileStore, model: AppModel) {
        self.interface = interface
        self.library = library
        self.player = player
        self.profiles = profiles
        self.model = model
        refresh()
        observeChanges()
    }

    // MARK: Root

    private var currentKind: RootKind {
        if model.stage != .ready { return .notSetUp }
        if profiles.isLocked { return .locked }
        return .tabs
    }

    /// Sets the root when what should be there changed; otherwise refreshes the lists in place.
    private func refresh() {
        guard isConnected else { return }
        let kind = currentKind
        let context = browseContext
        if kind != rootKind || context != rootContext {
            rootKind = kind
            rootContext = context
            playbackRequest = UUID()
            libraryTemplate = nil
            playlistsTemplate = nil
            albumsTemplate = nil
            artistsTemplate = nil
            let root: CPTemplate
            switch kind {
            case .notSetUp:
                root = messageTemplate(title: "Gumbo", text: "Set up Gumbo on your iPhone first", detail: "Connect your server, then the library appears here.")
            case .locked:
                root = messageTemplate(title: "Gumbo", text: "Choose a profile on your iPhone", detail: "Playlists and favourites belong to a profile.")
            case .tabs:
                configureNowPlaying()
                let libraryList = CPListTemplate(title: "Library", sections: librarySections())
                libraryList.tabTitle = "Library"
                libraryList.tabImage = UIImage(systemName: "square.stack.fill")
                let playlistsList = CPListTemplate(title: "Playlists", sections: playlistSections())
                playlistsList.tabTitle = "Playlists"
                playlistsList.tabImage = UIImage(systemName: "music.note.list")
                let albumsList = CPListTemplate(title: "Albums", sections: albumSections())
                albumsList.tabTitle = "Albums"
                albumsList.tabImage = UIImage(systemName: "square.grid.2x2.fill")
                let artistsList = CPListTemplate(title: "Artists", sections: artistSections())
                artistsList.tabTitle = "Artists"
                artistsList.tabImage = UIImage(systemName: "music.mic")
                libraryTemplate = libraryList
                playlistsTemplate = playlistsList
                albumsTemplate = albumsList
                artistsTemplate = artistsList
                root = CPTabBarTemplate(templates: [libraryList, playlistsList, albumsList, artistsList])
            }
            interface.setRootTemplate(root, animated: false) { [weak self] success, error in
                guard !success else { return }
                if self?.rootContext == context, self?.rootKind == kind { self?.rootKind = nil }
                DiagnosticsLog.shared.record("CarPlay could not show its library: \(error?.localizedDescription ?? "unknown presentation error")")
            }
        } else if kind == .tabs {
            libraryTemplate?.updateSections(librarySections())
            playlistsTemplate?.updateSections(playlistSections())
            albumsTemplate?.updateSections(albumSections())
            artistsTemplate?.updateSections(artistSections())
        }
    }

    /// Rebuilds when the library, the playlists or the profile lock change.
    private func observeChanges() {
        withObservationTracking {
            _ = library.contentRevision
            _ = library.catalogue.driveID
            _ = library.playlists
            _ = library.favouritesPlaylist
            _ = library.favouritesMixPlaylist
            _ = library.recentlyPlayedPlaylist
            _ = profiles.sessionID
            _ = profiles.isLocked
            _ = model.stage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                self.refresh()
                self.observeChanges()
            }
        }
    }

    func disconnect() {
        isConnected = false
        playbackRequest = UUID()
    }

    private func canUse(_ context: BrowseContext) -> Bool {
        isConnected && currentKind == .tabs && context == browseContext
    }

    private func handle(_ item: CPListItem, action: @escaping @MainActor (CarPlayController) async -> Void) {
        let context = browseContext
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                defer { completion() }
                guard let self, self.canUse(context) else { return }
                await action(self)
            }
        }
    }

    private func push(_ template: CPTemplate) async {
        do {
            _ = try await interface.pushTemplate(template, animated: true)
        } catch {
            DiagnosticsLog.shared.record("CarPlay could not open a page: \(error.localizedDescription)")
        }
    }

    private func messageTemplate(title: String, text: String, detail: String) -> CPListTemplate {
        let item = CPListItem(text: text, detailText: detail, image: UIImage(systemName: "iphone"))
        item.isEnabled = false
        return CPListTemplate(title: title, sections: [CPListSection(items: [item])])
    }

    // MARK: Sections

    private func librarySections() -> [CPListSection] {
        let recent = library.recentlyAdded.prefix(Self.listLimit).map(albumItem)
        return [CPListSection(items: Array(recent), header: "Recently added", sectionIndexTitle: nil)]
    }

    private func playlistSections() -> [CPListSection] {
        let smart = [library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist, library.libraryShufflePlaylist]
            .filter { !$0.tracks.isEmpty }
        var sections: [CPListSection] = []
        if !smart.isEmpty {
            sections.append(CPListSection(items: smart.map(playlistItem), header: "Made for you", sectionIndexTitle: nil))
        }
        let room = max(0, Self.listLimit - smart.count)
        if library.playlists.count <= room {
            if !library.playlists.isEmpty {
                sections.append(CPListSection(items: library.playlists.map(playlistItem), header: "Your playlists", sectionIndexTitle: nil))
            }
        } else if room > 0 {
            // The rest stay reachable a page at a time.
            let all = CPListItem(text: "All playlists", detailText: "\(library.playlists.count) playlists", image: UIImage(systemName: "music.note.list"))
            all.accessoryType = .disclosureIndicator
            handle(all) { controller in
                await controller.showPages(title: "Your playlists", controller.library.playlists) { $0.playlistItem($1) }
            }
            let own = library.playlists.prefix(room - 1).map(playlistItem)
            sections.append(CPListSection(items: [all] + own, header: "Your playlists", sectionIndexTitle: nil))
        }
        return sections
    }

    private func albumSections() -> [CPListSection] {
        alphabetical(Self.byTitle(library.albums), noun: "albums", name: { $0.title },
                     current: { Self.byTitle($0.library.albums) }, row: { $0.albumItem($1) })
    }

    private func artistSections() -> [CPListSection] {
        alphabetical(library.artists, noun: "artists", name: { $0.name },
                     current: { $0.library.artists }, row: { $0.artistItem($1) })
    }

    private static func byTitle(_ albums: [Album]) -> [Album] {
        albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// A–Z browsing within the car's row limit: a list with a section per letter when everything
    /// fits, otherwise a row per letter that opens that letter's page, read afresh when tapped.
    private func alphabetical<Element: Sendable>(
        _ elements: [Element], noun: String, name: @escaping @Sendable (Element) -> String,
        current: @escaping @MainActor (CarPlayController) -> [Element],
        row: @escaping @MainActor (CarPlayController, Element) -> CPListItem
    ) -> [CPListSection] {
        let groups = AlphabeticalIndex.groups(elements, name: name)
        if elements.count <= Self.listLimit, groups.count <= CPListTemplate.maximumSectionCount {
            return groups.map { group in
                CPListSection(items: group.elements.map { row(self, $0) }, header: group.letter, sectionIndexTitle: group.letter)
            }
        }
        let letters = groups.prefix(Self.listLimit).map { group -> CPListItem in
            let count = group.elements.count
            let item = CPListItem(text: group.letter, detailText: "\(count) \(noun)")
            item.accessoryType = .disclosureIndicator
            handle(item) { controller in
                let now = AlphabeticalIndex.groups(current(controller), name: name).first { $0.letter == group.letter }?.elements ?? []
                await controller.showPages(title: group.letter, now, row: row)
            }
            return item
        }
        return [CPListSection(items: letters)]
    }

    /// Pushes a list of the elements; more than a list holds are split into numbered pages.
    private func showPages<Element: Sendable>(
        title: String, _ elements: [Element], row: @escaping @MainActor (CarPlayController, Element) -> CPListItem
    ) async {
        let pages = AlphabeticalIndex.pages(count: elements.count, size: Self.listLimit)
        let items: [CPListItem]
        if pages.count <= 1 {
            items = elements.map { row(self, $0) }
        } else {
            items = pages.prefix(Self.listLimit).map { range -> CPListItem in
                let page = Array(elements[range])
                let item = CPListItem(text: "\(title) \(range.lowerBound + 1)–\(range.upperBound)", detailText: nil)
                item.accessoryType = .disclosureIndicator
                handle(item) { controller in await controller.showPages(title: title, page, row: row) }
                return item
            }
        }
        await push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }

    // MARK: Items

    private func albumItem(_ album: Album) -> CPListItem {
        let item = CPListItem(text: album.title, detailText: album.artist, image: cover(for: album))
        item.accessoryType = .disclosureIndicator
        handle(item) { controller in
            guard let current = controller.library.album(id: album.id) else { return }
            await controller.showAlbum(current)
        }
        loadCover(for: album, into: item)
        return item
    }

    private func playlistItem(_ playlist: Playlist) -> CPListItem {
        let item = CPListItem(text: playlist.name, detailText: playlist.summary, image: playlist.covers.first.map(cover(for:)))
        item.accessoryType = .disclosureIndicator
        handle(item) { controller in
            guard let current = controller.library.playlist(id: playlist.id) else { return }
            await controller.showPlaylist(current)
        }
        if let first = playlist.covers.first { loadCover(for: first, into: item) }
        return item
    }

    private func artistItem(_ artist: Artist) -> CPListItem {
        let item = CPListItem(text: artist.name, detailText: artist.summary, image: artist.albums.first.map(cover(for:)))
        item.accessoryType = .disclosureIndicator
        handle(item) { controller in
            guard let current = controller.library.artists.first(where: { $0.id == artist.id }) else { return }
            await controller.showArtist(current)
        }
        if let first = artist.albums.first { loadCover(for: first, into: item) }
        return item
    }

    // MARK: Pages

    private func showAlbum(_ album: Album) async {
        let play = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"))
        handle(play) { controller in
            guard let current = controller.library.album(id: album.id) else { return }
            await controller.start(current.tracks, title: nil)
        }
        let shuffle = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        handle(shuffle) { controller in
            guard let current = controller.library.album(id: album.id) else { return }
            await controller.start(current.tracks, shuffled: true, title: current.title)
        }
        let songs = album.tracks.prefix(max(0, Self.listLimit - 2)).map { track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artist ?? album.artist)
            handle(item) { controller in
                guard let current = controller.library.album(id: album.id),
                      let index = current.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                await controller.start(current.tracks, from: index, title: nil)
            }
            return item
        }
        let template = CPListTemplate(title: album.title, sections: [
            CPListSection(items: [play, shuffle]),
            CPListSection(items: songs, header: "\(album.tracks.count) songs", sectionIndexTitle: nil),
        ])
        await push(template)
    }

    private func showPlaylist(_ playlist: Playlist) async {
        let play = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"))
        handle(play) { controller in
            guard let current = controller.library.playlist(id: playlist.id) else { return }
            await controller.start(current.tracks, title: current.name)
        }
        let shuffle = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        handle(shuffle) { controller in
            guard let current = controller.library.playlist(id: playlist.id) else { return }
            await controller.start(current.tracks, shuffled: true, title: current.name)
        }
        let songs = playlist.entries.prefix(max(0, Self.listLimit - 2)).map { entry -> CPListItem in
            let track = entry.track
            let album = library.album(id: track.albumID)
            let item = CPListItem(text: track.title, detailText: track.artist ?? album?.artist ?? "", image: album.map(cover(for:)))
            handle(item) { controller in
                guard let current = controller.library.playlist(id: playlist.id),
                      let index = current.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                await controller.start(current.tracks, from: index, title: current.name)
            }
            return item
        }
        let template = CPListTemplate(title: playlist.name, sections: [
            CPListSection(items: [play, shuffle]),
            CPListSection(items: Array(songs), header: playlist.summary, sectionIndexTitle: nil),
        ])
        await push(template)
    }

    private func showArtist(_ artist: Artist) async {
        await showPages(title: artist.name, artist.albums) { $0.albumItem($1) }
    }

    /// Starts playback and brings up the system's Now Playing screen. Without a song to start at, the
    /// player picks the first song, or a random one when shuffling.
    private func start(_ tracks: [Track], from index: Int? = nil, shuffled: Bool = false, title: String?) async {
        let context = browseContext
        guard canUse(context), !tracks.isEmpty else { return }
        if let index, !tracks.indices.contains(index) { return }
        let request = UUID()
        playbackRequest = request
        let command = player.beginDeferredPlaybackCommand()
        // A CarPlay-only launch can show the cached library before server sign-in completes, and an
        // offline library reconnects when CarPlay connects; waiting for the drive also starts that.
        // Downloaded songs already have a local file and start immediately; the player's own
        // source is asked, as it is what plays them. A shuffled start may be any of the songs.
        let firstSongs = if let index { [tracks[index]] } else if shuffled || player.isShuffling { tracks } else { [tracks[0]] }
        if !model.isConnected, firstSongs.contains(where: { player.mediaSourceProvider?($0) == nil }) {
            await model.waitForDrive(upTo: .seconds(8))
        }
        guard canUse(context), playbackRequest == request, player.commandRevision == command else { return }
        if shuffled {
            player.shuffle(queue: tracks, title: title)
        } else {
            player.play(queue: tracks, startingAt: index, title: title)
        }
        if interface.topTemplate !== CPNowPlayingTemplate.shared {
            await push(CPNowPlayingTemplate.shared)
        }
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let context = browseContext
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isAlbumArtistButtonEnabled = false
        nowPlaying.updateNowPlayingButtons([
            CPNowPlayingShuffleButton { [weak self] _ in
                guard let self, self.canUse(context) else { return }
                self.player.toggleShuffle()
            },
            CPNowPlayingRepeatButton { [weak self] _ in
                guard let self, self.canUse(context) else { return }
                self.player.cycleRepeat()
            },
        ])
    }

    // MARK: Covers

    /// The cached cover, or the album's own gradient until the real one arrives.
    private func cover(for album: Album) -> UIImage {
        let version = library.coverVersion(for: album)
        let key = "\(library.coverURL(for: album)?.absoluteString ?? "")|\(album.id)|\(version)|\(CoverImageCache.thumbnailPixels)"
        if let cached = CoverImageCache.shared.cached(key) { return UIImage(cgImage: cached) }
        let size = CGSize(width: 180, height: 180)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(album.primaryColor).cgColor, UIColor(album.secondaryColor).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
    }

    /// Fetches the real cover from the server for a list item still showing its gradient.
    private func loadCover(for album: Album, into item: CPListItem) {
        let version = library.coverVersion(for: album)
        let key = "\(library.coverURL(for: album)?.absoluteString ?? "")|\(album.id)|\(version)|\(CoverImageCache.thumbnailPixels)"
        guard CoverImageCache.shared.cached(key) == nil, let url = library.coverURL(for: album) else { return }
        Task {
            if let image = await CoverImageCache.shared.image(url: url, key: key, maxPixelSize: CoverImageCache.thumbnailPixels) {
                item.setImage(UIImage(cgImage: image))
            }
        }
    }
}
#endif
