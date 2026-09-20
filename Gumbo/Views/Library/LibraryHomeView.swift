import GumboCore
import SwiftUI

/// "Recently added" facet: shelves of recent, played, per-genre and high resolution albums.
struct LibraryHomeView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        shelfHeader("Recently added", query: .recentlyAdded)
        AlbumCarousel(albums: Array(library.recentlyAdded.prefix(12)), cardWidth: 164 * Metrics.scale, cornerRadius: 12 * Metrics.scale, spacing: 14 * Metrics.scale, source: "recent")
            .padding(.top, 12)

        if !library.recentlyPlayed.isEmpty {
            shelfHeader("Recently played", query: .recentlyPlayed)
                .padding(.top, 26)
            AlbumCarousel(albums: Array(library.recentlyPlayed.prefix(12)), cardWidth: 136 * Metrics.scale, cornerRadius: 10 * Metrics.scale, spacing: 12 * Metrics.scale, source: "played")
                .padding(.top, 12)
        }

        ForEach(library.genreShelves) { genre in
            shelfHeader(genre.name, query: .genre(genre.name))
                .padding(.top, 26)
            AlbumCarousel(albums: Array(genre.albums.prefix(12)), cardWidth: 136 * Metrics.scale, cornerRadius: 10 * Metrics.scale, spacing: 12 * Metrics.scale, source: "genre:\(genre.name)")
                .padding(.top, 12)
        }

        if !library.hiResAlbums.isEmpty {
            shelfHeader("Lossless, high resolution", query: .highResolution)
                .padding(.top, 26)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(library.hiResAlbums.prefix(20)) { album in
                        let destination = AlbumDestination(album, source: "hires")
                        NavigationLink(value: destination) {
                            HiResAlbumRow(album: album, destination: destination)
                        }
                        .cardButton()
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .padding(.top, 12)
        }
    }

    private func shelfHeader(_ title: String, query: AlbumCollectionQuery) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                NavigationLink("See all", value: AlbumCollection(title: title, query: query))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                NavigationLink("See all", value: AlbumCollection(title: title, query: query))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }
}

/// Snapping horizontal row of square album cards.
struct AlbumCarousel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let albums: [Album]
    let cardWidth: CGFloat
    let cornerRadius: CGFloat
    let spacing: CGFloat
    var source = "shelf"

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(albums) { album in
                    let destination = AlbumDestination(album, source: source)
                    NavigationLink(value: destination) {
                        AlbumCard(album: album, width: cardWidth, cornerRadius: cornerRadius, destination: destination)
                    }
                    .cardButton()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        // Albums found by a scan ease into the shelf instead of popping.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: albums.map(\.id))
    }
}

struct AlbumCard: View {
    let album: Album
    let width: CGFloat
    var cornerRadius: CGFloat = 12
    var destination: AlbumDestination? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Nothing sits behind the artwork and the shadow is part of the zoom source itself, so the
            // spot stays empty while the zoom runs; the flying snapshot carries the same shadow.
            Group {
                if let destination {
                    ArtworkView(album: album, cornerRadius: cornerRadius)
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
                        .artworkSource(destination, cornerRadius: cornerRadius, shadow: .card)
                } else {
                    ArtworkView(album: album, cornerRadius: cornerRadius)
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
                }
            }
            .frame(width: width, height: width)
            .padding(.bottom, 8)
            FadingText(album.title)
                .font(width > 150 ? .subheadline.weight(.medium) : .footnote.weight(.medium))
            FadingText(album.artist)
                .font(width > 150 ? .footnote : .caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title), \(album.artist)")
    }
}

/// Wide row with format details, used for the high resolution shelf.
struct HiResAlbumRow: View {
    let album: Album
    var destination: AlbumDestination? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let destination {
                    ArtworkView(album: album, cornerRadius: 8).artworkSource(destination, cornerRadius: 8)
                } else {
                    ArtworkView(album: album, cornerRadius: 8)
                }
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                FadingText(album.title)
                    .font(.subheadline.weight(.medium))
                FadingText(album.artist)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                QualityBars(quality: album.quality, maxHeight: 9)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
