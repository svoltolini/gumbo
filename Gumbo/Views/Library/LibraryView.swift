import GumboCore
import SwiftUI

/// Non-model destinations reachable from the navigation stacks.
nonisolated enum LibraryRoute: Hashable {
    case downloads
}

/// A titled list of albums, used by "See all" and genre drill-downs.
nonisolated struct AlbumCollection: Hashable {
    let title: String
    let query: AlbumCollectionQuery
}

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Namespace private var artworkNamespace
    /// The stack's pages. "Go to Album" appends a fresh page, so an album page further down keeps its own state.
    @State private var path = NavigationPath()
    /// The album "Go to Album" last pushed and the depth it landed at, so repeating it while that page is on top does nothing.
    @State private var openedAlbum: (id: String, depth: Int)?

    private var isEmptyLibrary: Bool { library.isEmpty && !model.isDemo }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pendingScanNotice
                    if isEmptyLibrary {
                        emptyState
                    } else {
                        if model.indexingFailure != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Library update incomplete", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                                Text("Your previous library has been kept. " + emptyDescription)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Retry Update") { model.rescan() }
                            }
                            .padding(20)
                        }
                        #if !os(macOS)
                        LibraryFacetHeader()
                            .padding(.bottom, 8)
                        #endif
                        Group {
                            switch model.facet {
                            case .recentlyAdded: LibraryHomeView()
                            case .artists: ArtistsListView()
                            case .genres: GenresView()
                            }
                        }
                        // The old facet fades out first; the new one then fades in while rising a little,
                        // so the two layouts never show on top of each other.
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)).animation(.easeOut(duration: 0.3).delay(0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.14))
                        ))
                    }
                }
                .padding(.bottom, 32)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.25), value: model.facet)
            }
            .pullToRefresh { [model] in
                // Release the pull gesture immediately. The toolbar owns scan progress so the
                // scroll view can settle and remain usable even on a slow connection.
                await model.rescan()
            }
            .gumboBackground(player.tint)
            .navigationTitle("Library")
            .libraryDestinations()
            // A request becomes a new page on the stack, then clears. Binding the destination to the
            // request instead would restyle an earlier "Go to Album" page still in the stack in place.
            .onChange(of: model.albumToOpen, initial: true) { _, album in
                guard let album else { return }
                model.albumToOpen = nil
                guard openedAlbum?.id != album.id || openedAlbum?.depth != path.count else { return }
                path.append(album)
                openedAlbum = (album.id, path.count)
            }
            .onChange(of: path.count) { _, depth in
                if let openedAlbum, depth < openedAlbum.depth { self.openedAlbum = nil }
            }
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan for New Music", systemImage: "arrow.clockwise") { model.rescan() }
                        .help("Look for music added to the folder since the last scan")
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    ScanStatusButton()
                }
                #endif
            }
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }

    private var emptyDescription: String {
        switch model.indexingFailure {
        case .missing: "The folder you chose no longer exists. You can pick another one in Settings."
        case .unreadable(_, let path): "Some folders in “\(LibraryIndexer.Failure.name(of: path))” couldn't be read. Check the account's permissions. \(Hints.tryAgain)"
        case .other(let message): message + " " + Hints.tryAgain
        // The failed folder may be a newly chosen one while the previous folder's library is still shown.
        case .noMusic(let path): "Add music to “\(LibraryIndexer.Failure.name(of: path))” and \(Hints.rescan), or pick another folder in Settings."
        case .none: "Add music to “\(library.catalogue.rootName)” and \(Hints.rescan), or pick another folder in Settings."
        }
    }

    /// A pull or a tap asked for a scan that can't start yet: why, and for an offline server the way back.
    @ViewBuilder
    private var pendingScanNotice: some View {
        if model.isScanRequestPending, let blocker = model.scanBlocker {
            VStack(alignment: .leading, spacing: 8) {
                switch blocker {
                case .offline:
                    Label("Music server offline", systemImage: "icloud.slash").font(.headline)
                case .connecting:
                    Label("Connecting to your music server", systemImage: "icloud").font(.headline)
                case .writingTags, .deletingFiles:
                    Label("Library update waiting", systemImage: "clock").font(.headline)
                }
                Text(blocker.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if blocker == .offline {
                    if let error = model.signInError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Reconnect") { model.rescan() }
                }
            }
            .padding(20)
        }
    }

    /// Shown while the folder holds no music, or the chosen folder is gone. Pulling down scans again.
    private var emptyState: some View {
        EmptyStateView(title: "No Music Found", systemImage: "music.note", message: emptyDescription)
    }
}

extension View {
    /// Destinations shared by every navigation stack that can open catalogue content.
    func libraryDestinations() -> some View {
        #if os(macOS)
        self
            .navigationDestination(for: Album.self) { MacAlbumDetailView(album: $0) }
            .navigationDestination(for: AlbumDestination.self) { MacAlbumDetailView(album: $0.album) }
            .navigationDestination(for: Artist.self) { MacArtistDetailView(artist: $0) }
            .navigationDestination(for: ArtistDestination.self) { MacArtistDetailView(artist: $0.artist) }
            .navigationDestination(for: AlbumCollection.self) { MacAlbumCollectionView(collection: $0) }
            .navigationDestination(for: CollectionDestination.self) { MacAlbumCollectionView(collection: $0.collection) }
            .navigationDestination(for: Playlist.self) { MacPlaylistDetailView(playlist: $0) }
            .navigationDestination(for: PlaylistDestination.self) { MacPlaylistDetailView(playlist: $0.playlist) }
            .navigationDestination(for: LibraryRoute.self) { _ in MacDownloadsView() }
        #else
        self
            .navigationDestination(for: Album.self) { AlbumView(album: $0) }
            .navigationDestination(for: AlbumDestination.self) { AlbumView(album: $0.album).artworkZoom(from: $0) }
            .navigationDestination(for: Artist.self) { ArtistView(artist: $0) }
            .navigationDestination(for: ArtistDestination.self) { ArtistView(artist: $0.artist).zoomDestination(id: $0.sourceID) }
            .navigationDestination(for: AlbumCollection.self) { AlbumCollectionView(collection: $0) }
            .navigationDestination(for: CollectionDestination.self) { AlbumCollectionView(collection: $0.collection).zoomDestination(id: $0.sourceID) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: PlaylistDestination.self) { PlaylistDetailView(playlist: $0.playlist).zoomDestination(id: $0.sourceID) }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .downloads: DownloadsView()
                }
            }
        #endif
    }
}

/// Facet chips placed at the top of each facet's content so they scroll with it.
struct LibraryFacetHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        FacetPicker(selection: $model.facet)
    }
}

/// Horizontal row of glass chips. Selecting one is a quick, clean flip: the ink fades in over 0.2 s and the
/// label colour switches halfway through, so the text stays readable and nothing slides or bounces.
struct FacetPicker: View {
    @Binding var selection: LibraryFacet

    var body: some View {
        #if os(tvOS)
        // The television's own segmented control: focus lifts a segment to white, the chosen one
        // stays a lighter grey, and the segments keep their distance. Glass chips fuse together
        // at this size and give the remote nothing to highlight.
        Picker("Section", selection: $selection) {
            ForEach(LibraryFacet.allCases) { facet in
                Text(facet.rawValue).tag(facet)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .sensoryFeedback(.selection, trigger: selection)
        #else
        chips
        #endif
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(LibraryFacet.allCases) { facet in
                        chip(for: facet)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(for facet: LibraryFacet) -> some View {
        let isSelected = facet == selection
        return Button {
            selection = facet
        } label: {
            Text(facet.rawValue)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Palette.onAccent : .primary)
                // Flip the label colour in a short window centred on the moment the ink is half way,
                // so it is never light-on-light or dark-on-dark.
                .animation(.easeInOut(duration: 0.05).delay(0.055), value: isSelected)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(Palette.accent)
                        .opacity(isSelected ? 1 : 0)
                        .animation(.easeInOut(duration: 0.22), value: isSelected)
                }
                .glassEffect(.regular, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AlbumCollectionView: View {
    let collection: AlbumCollection
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        List(library.albums(matching: collection.query)) { album in
            let destination = AlbumDestination(album, source: "collection")
            NavigationLink(value: destination) {
                AlbumRow(album: album, detail: "\(album.artist)\(album.year > 0 ? " · \(String(album.year))" : "")", destination: destination)
            }
        }
        .hiddenScrollBackground()
        .gumboBackground(player.tint)
        .navigationTitle(collection.title)
        .inlineTitle()
    }
}

/// Compact album line used in lists: 48pt art, title, one detail line.
struct AlbumRow: View {
    let album: Album
    let detail: String
    var destination: AlbumDestination? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let destination {
                    ArtworkView(album: album, cornerRadius: 6, size: .row).artworkSource(destination, cornerRadius: 6)
                } else {
                    ArtworkView(album: album, cornerRadius: 6, size: .row)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                LibraryRowText(album.title)
                    .font(.body.weight(.medium))
                LibraryRowText(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
