import GumboCore
import SwiftUI

/// Search tab: type to find artists, albums and songs; recent searches while the field is empty.
///
/// The page owns its field so it cannot leak over unrelated tabs while scrolling.
struct SearchView: View {
    /// What the search field asks for, wherever the platform draws it.
    static var prompt: Text { Text("Albums, artists, songs") }

    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Namespace private var artworkNamespace
    /// Recomputed for query changes or a published catalogue revision, preserving the search field and stack.
    @State private var results = SearchResults()
    @State private var completedRequest: LibrarySearchRequest?
    @State private var path = NavigationPath()

    private var query: String { model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: LibrarySearchRequest {
        LibrarySearchRequest(text: query, revision: library.contentRevision,
                             source: library.catalogue.driveID, root: library.catalogue.rootPath)
    }

    private var isSearching: Bool { completedRequest != request }
    private var hasCurrentContent: Bool {
        guard let completedRequest else { return false }
        return completedRequest.revision == request.revision
            && completedRequest.source == request.source && completedRequest.root == request.root
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            // Keep one scroll container while typing; swapping it for a spinner moves the search bar.
            List {
                if query.isEmpty {
                    recentSearches
                } else if hasCurrentContent {
                    resultSections
                        .disabled(isSearching)
                }
            }
            .groupedList()
            .overlay {
                if query.isEmpty && library.recentSearches.isEmpty {
                    EmptyStateView(title: "Search Your Library", systemImage: "magnifyingglass", message: "Find albums, artists and songs by name.")
                } else if !query.isEmpty && (!hasCurrentContent || results.isEmpty) {
                    if isSearching {
                        ProgressView("Searching…")
                    } else {
                        EmptyStateView(title: "No Results", systemImage: "magnifyingglass", message: "Nothing in your library matches “\(query)”.")
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !query.isEmpty && isSearching && hasCurrentContent && !results.isEmpty {
                    ProgressView().padding()
                        .accessibilityLabel("Updating search results")
                }
            }
            .hiddenScrollBackground()
            .gumboBackground(player.tint)
            .navigationTitle("Search")
            .pageSearchField(text: $model.searchQuery, prompt: Self.prompt) {
                library.noteSearch(model.searchQuery)
            }
            .libraryDestinations()
        }
        .onChange(of: query) { _, _ in path = NavigationPath() }
        .onChange(of: path.count) { old, new in
            if new > old { library.noteSearch(query) }
        }
        .task(id: request) {
            let pending = request
            guard !pending.text.isEmpty else {
                results = SearchResults()
                completedRequest = pending
                return
            }
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard library.contentSourceID == pending.source, library.contentRootPath == pending.root else { return }
            let found = await library.searchIndex.resultsInBackground(for: pending.text)
            guard !Task.isCancelled, pending == request else { return }
            results = found
            completedRequest = pending
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }

    @ViewBuilder
    private var recentSearches: some View {
        if !library.recentSearches.isEmpty {
            Section("Recent Searches") {
                FlowLayout(spacing: 8) {
                    ForEach(library.recentSearches, id: \.self) { term in
                        Button(term) {
                            model.searchQuery = term
                            library.noteSearch(term)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if !results.artists.isEmpty {
            Section("Artists") {
                ForEach(results.artists) { artist in
                    let destination = ArtistDestination(artist, source: "search")
                    NavigationLink(value: destination) {
                        HStack(spacing: 12) {
                            ArtistPortrait(artist: artist, size: .row)
                                .frame(width: 44, height: 44)
                                .zoomSource(id: destination.sourceID, shape: .circle(44))
                            VStack(alignment: .leading, spacing: 2) {
                                LibraryRowText(artist.name)
                                    .font(.body.weight(.medium))
                                Text(artist.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        if !results.albums.isEmpty {
            Section("Albums") {
                ForEach(results.albums) { album in
                    let destination = AlbumDestination(album, source: "search")
                    NavigationLink(value: destination) {
                        AlbumRow(album: album, detail: album.artist, destination: destination)
                    }
                }
            }
        }
        if !results.tracks.isEmpty {
            Section("Songs") {
                ForEach(results.tracks) { track in
                    Button {
                        library.noteSearch(query)
                        if let album = library.album(for: track) {
                            player.play(album: album, startingAt: track.index)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if let album = library.album(for: track) {
                                ArtworkView(album: album, cornerRadius: 6, highlight: false, size: .row)
                                    .frame(width: 44, height: 44)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                LibraryRowText(track.title)
                                    .font(.body.weight(player.isCurrent(track: track) ? .semibold : .regular))
                                LibraryRowText(library.album(for: track).map { "\($0.artist) · \($0.title)" } ?? track.artist ?? " ")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if dynamicTypeSize.isAccessibilitySize {
                                    Text(TimeText.clock(track.duration))
                                        .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            if !dynamicTypeSize.isAccessibilitySize {
                                Spacer(minLength: 8)
                                Text(TimeText.clock(track.duration))
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
