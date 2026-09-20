import GumboCore
import SwiftUI
import WatchKit

/// Playlists on one page, the system's Now Playing on the next, the way music apps read on the wrist.
struct WatchRootView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WatchPlayer.self) private var player

    var body: some View {
        content
            .alert("Playback couldn't start", isPresented: Binding(
                get: { player.lastError != nil },
                set: { if !$0 { player.dismissPlaybackError() } }
            )) {
                Button("OK") { player.dismissPlaybackError() }
            } message: {
                Text(player.lastError ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if store.catalogue == nil {
            SetupHintView()
        } else {
            TabView {
                NavigationStack {
                    PlaylistsListView()
                }
                NowPlayingView()
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

/// Shown until the phone has sent its playlists.
struct SetupHintView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "iphone.and.applewatch")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Open Gumbo on your iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Your playlists arrive here by themselves.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Explore Sample Library") { store.loadSample() }
                    .font(.caption)
                Button("Sync now") { store.requestSync() }
                    .font(.caption)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
    }
}
