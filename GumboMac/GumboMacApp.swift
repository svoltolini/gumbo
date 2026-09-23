import AppKit
import CloudKit
import GumboCore
import SwiftUI

/// Silent iCloud pushes and family invitation links. Playback keys stay in the library views.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static var cloud: CloudSync?
    static var player: PlayerModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Silent pushes only; no permission prompt.
        NSApplication.shared.registerForRemoteNotifications()
    }

    /// Closing the window leaves the music playing; the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await Self.cloud?.accept(metadata) }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        Task { await Self.cloud?.refresh(reason: "iCloud push") }
    }
}

@main
struct GumboMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var profiles: ProfileStore
    @State private var cloud: CloudSync
    @State private var library: LibraryStore
    @State private var model: AppModel
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager
    @State private var navigation = MacNavigation()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let profiles = ProfileStore()
        let cloud = CloudSync()
        cloud.profiles = profiles
        profiles.sync = cloud
        MacAppDelegate.cloud = cloud
        let library = LibraryStore()
        library.profiles = profiles
        let model = AppModel(library: library)
        model.profiles = profiles
        let player = PlayerModel()
        MacAppDelegate.player = player
        let downloads = DownloadManager()
        downloads.driveIDProvider = { [library] in library.catalogue.driveID }
        downloads.remoteSourceProvider = { [model] in model.downloadSource(for: $0) }
        downloads.fileRevisionProvider = { [library] source, id in
            guard library.catalogue.driveID == source else { return nil }
            return library.track(id: id).map(DownloadFileRevision.init)
        }
        model.onConnectionWillChange = { [weak downloads] in downloads?.revokeForegroundDownloads() }
        if !UserDefaults.standard.bool(forKey: "downloads.ownersScoped"), let owner = profiles.owner {
            downloads.adoptLegacyOwners(into: owner.id)
            UserDefaults.standard.set(true, forKey: "downloads.ownersScoped")
        }
        downloads.activeProfileID = profiles.lastActiveID ?? profiles.owner?.id ?? "default"
        // Songs owned only by profiles not on this device count as unused, but the local profile list
        // is trusted only once iCloud has been consulted; before that, or while it fails, nothing is judged.
        downloads.knownProfileIDsProvider = { [profiles, cloud] in
            switch cloud.status {
            case .synced, .noAccount: Set(profiles.profiles.map(\.id))
            case .off, .syncing, .failed: []
            }
        }
        // Persist download membership changes to iCloud via the profile state.
        downloads.onMembershipChanged = { [profiles] driveID, albumIDs, playlistIDs in
            profiles.updateLibrary(driveID) { library in
                library.downloadedAlbums = albumIDs
                library.downloadedPlaylists = playlistIDs
            }
        }
        // An album renamed in its files keeps its downloads under its new identity.
        library.onAlbumRenamed = { [downloads] oldID, newID in downloads.reassignAlbum(from: oldID, to: newID) }
        // A deleted playlist takes its download with it; songs taken out of one stop being kept for it.
        library.onPlaylistWillBeDeleted = { [downloads] playlist in downloads.removeDeleted(downloads.owner(for: playlist)) }
        library.onPlaylistSongsRemoved = { [downloads] playlist, trackIDs in
            downloads.releaseRemovedSongs(of: downloads.owner(for: playlist), keeping: trackIDs)
        }
        library.onServerTracksDeleted = { [library, downloads, player] sourceID, trackIDs in
            downloads.removeServerTracks(sourceID: sourceID, trackIDs: trackIDs)
            if library.catalogue.driveID == sourceID, player.queue.contains(where: { trackIDs.contains($0.id) }) {
                player.stop()
            }
        }

        // Membership restored from iCloud meets the files already in the downloads folder: songs still
        // here are reused rather than fetched again, and anything no download uses is surfaced. Runs
        // whenever either side changes: a profile opening, its document arriving, or the catalogue loading.
        let reconcileDownloads: () -> Void = { [library, profiles, downloads] in
            guard profiles.active != nil, !library.catalogue.isEmpty else { return }
            let driveID = library.catalogue.driveID
            let state = profiles.libraryState(for: driveID)
            downloads.reconcile(albums: state.downloadedAlbums, playlists: state.downloadedPlaylists, driveID: driveID,
                                album: { library.album(id: $0) }, playlist: { library.playlist(id: $0) })
        }
        library.onContentChanged = reconcileDownloads
        // A song on this Mac plays from disk, whether or not the server is reachable.
        player.mediaSourceProvider = { [library, downloads] track in
            downloads.localURL(for: track).map(RemoteMediaSource.url) ?? library.mediaSource(for: track)
        }
        // A stream refused because the NAS ended its session plays again once the session is renewed.
        player.streamFailureRecovery = { [model] url in await model.recoverStream(from: url) }
        player.artworkProvider = { [library] album in
            library.coverURL(for: album).map { ($0, library.coverVersion(for: album)) }
        }
        player.sourceIDProvider = { [library] in library.catalogue.driveID }
        player.albumProvider = { [library] track in library.album(for: track) }
        player.allowsSimulation = { [library] in library.isDemo }
        player.didStartAlbum = { [library] album in library.notePlayed(album) }
        player.didStartTrack = { [library] track in library.notePlayed(track) }
        _profiles = State(initialValue: profiles)
        _cloud = State(initialValue: cloud)
        _library = State(initialValue: library)
        _model = State(initialValue: model)
        _player = State(initialValue: player)
        _downloads = State(initialValue: downloads)
        // A profile opening loads its data everywhere; switching away stops the music first.
        profiles.onActivate = { [library, model, player, downloads, profiles] profile in
            downloads.activeProfileID = profile.id
            library.loadProfileState()
            reconcileDownloads()
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
        }
        profiles.onDeactivate = { [player, library, downloads] in
            downloads.revokeForegroundDownloads()
            player.stop()
            library.metadataWriter.cancel()
            downloads.activeProfileID = "locked"
            library.loadProfileState()
        }
        profiles.onRemoteState = { [library, model, player, profiles] in
            library.loadProfileState()
            reconcileDownloads()
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
        }
        cloud.familyInfoProvider = { [model] in model.familyInfo }
        cloud.onFamilyInfo = { [model, weak cloud] info in
            model.familyArrived(info, isOwner: cloud?.currentUserRecordName != nil && cloud?.isOwner == true)
        }
        model.onFamilyAccessChanged = { [cloud] in Task { await cloud.refresh(reason: "family access changed") } }
        player.settingsChanged = { [profiles] repeatMode, shuffle in
            profiles.updateSettings {
                $0.repeatMode = repeatMode.rawValue
                $0.shuffle = shuffle
            }
        }
        profiles.openAutomaticallyIfPossible()
        GumboVoiceRouter.install(model: model, library: library, profiles: profiles, player: player, downloads: downloads)
        cloud.start()
        // Development shortcut: `--sample-library` opens the built-in catalogue without a server.
        if ProcessInfo.processInfo.arguments.contains("--sample-library") {
            model.useSampleLibrary()
            model.openLibrary()
        }
    }

    var body: some Scene {
        Window("Gumbo", id: "main") {
            wired(MacRootView().reauthenticationSheet().downloadErrorAlert().profileSaveErrorAlert())
                .onAppear { MacSetupSnapshots.runIfRequested(model: model) }
                .onChange(of: MacNavigationScope(profileID: profiles.activeID, sessionID: profiles.sessionID, sourceID: library.catalogue.driveID), initial: true) { _, scope in
                    navigation.synchronizeScope(profileID: scope.profileID, sessionID: scope.sessionID, sourceID: scope.sourceID)
                    model.albumToOpen = nil
                    model.playlistToOpen = nil
                }
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                    if phase == .active { Task { await cloud.refresh(reason: "foreground") } }
                    if phase == .background { profiles.flushSave() }
                }
        }
        .defaultSize(width: model.stage == .ready ? 1240 : 1040, height: model.stage == .ready ? 800 : 720)
        // Setup and the library both fill restored or resized windows, with their own minimum sizes.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            MacCommands(navigation: navigation, player: player, model: model)
        }

        Settings {
            wired(Group {
                if profiles.isLocked {
                    ProfilePickerView()
                } else {
                    MacSettingsView()
                        .id(profiles.sessionID)
                        .id(library.catalogue.driveID + "|" + library.catalogue.rootPath)
                }
            }.profileSaveErrorAlert())
                .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
        }
    }

    /// Every scene sees the same stores.
    private func wired<Content: View>(_ content: Content) -> some View {
        content
            .environment(model)
            .environment(library)
            .environment(player)
            .environment(downloads)
            .environment(profiles)
            .environment(cloud)
            .environment(navigation)
            .tint(Palette.accent)
            .preferredColorScheme(model.appearance.colorScheme)
    }
}
