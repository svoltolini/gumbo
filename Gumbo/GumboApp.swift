import BackgroundTasks
import CarPlay
import GumboCore
import GumboShared
import CloudKit
import SwiftUI
import UIKit
import Intents

/// Receives the wake-up for background downloads, silent pushes from iCloud, and hands scenes to
/// `SceneDelegate` so family invitation links reach the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var cloud: CloudSync?
    static var model: AppModel?
    /// The car's scene drives the same library, player and profiles as the phone's.
    static var library: LibraryStore?
    static var player: PlayerModel?
    static var profiles: ProfileStore?
    private let siriMediaHandler = SiriMediaIntentHandler()
    static let indexTaskID = "com.samuelvoltolini.gumbo.index"

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? siriMediaHandler : nil
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Silent pushes only; no permission prompt.
        application.registerForRemoteNotifications()
        // A scan interrupted by the phone locking carries on here when the system gives the app time.
        // The scheduler calls this on its own queue: the closure must not be tied to the main actor,
        // and the task is handed across to it explicitly.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.indexTaskID, using: nil) { @Sendable task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in Self.continueScan(task) }
        }
        return true
    }

    /// Runs a background processing task: pick the scan up where it stopped, and finish cleanly on expiry.
    private static func continueScan(_ task: BGTask) {
        task.expirationHandler = { @Sendable in
            Task { @MainActor in
                Self.model?.indexer.cancel()
            }
        }
        Task { @MainActor in
            guard let model else { task.setTaskCompleted(success: false); return }
            await model.waitForDrive(upTo: .seconds(20))
            guard model.stage == .ready, model.isConnected, !model.isDemo else { task.setTaskCompleted(success: false); return }
            DiagnosticsLog.shared.record("Continuing the scan in the background")
            if !model.isScanning { model.refreshIfStale(olderThan: 0) }
            while model.isScanning { try? await Task.sleep(for: .seconds(2)) }
            task.setTaskCompleted(success: true)
        }
    }

    /// Asks for background time to finish a scan that was running when the app left the screen.
    static func scheduleScanContinuation() {
        let request = BGProcessingTaskRequest(identifier: indexTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            DiagnosticsLog.shared.record("Asked to continue the scan in the background")
        } catch {
            DiagnosticsLog.shared.record("Background scan could not be scheduled: \(error.localizedDescription)")
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.backgroundCompletionHandler = completionHandler
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        await Self.cloud?.refresh(reason: "iCloud push")
        return .newData
    }
}

/// Family invitation links open here, whether the app was running or not.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { await AppDelegate.cloud?.accept(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { await AppDelegate.cloud?.accept(cloudKitShareMetadata) }
    }
}

@main
struct GumboApp: App {
    private static var isLayoutFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--sample-library")
            && ProcessInfo.processInfo.arguments.contains("--ui-preview")
        #else
        false
        #endif
    }
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var profiles: ProfileStore
    @State private var cloud: CloudSync
    @State private var library: LibraryStore
    @State private var model: AppModel
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager
    private let widgetFeed = WidgetFeed()
    private let watchBridge = WatchBridge()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let profiles = ProfileStore()
        let cloud = CloudSync()
        cloud.profiles = profiles
        profiles.sync = cloud
        if Self.isLayoutFixture {
            cloud.profiles = nil
            profiles.sync = nil
        }
        AppDelegate.cloud = cloud
        let library = LibraryStore()
        library.profiles = profiles
        let model = AppModel(library: library)
        model.profiles = profiles
        AppDelegate.model = model
        AppDelegate.library = library
        AppDelegate.profiles = profiles
        let player = PlayerModel()
        AppDelegate.player = player
        let downloads = DownloadManager()
        downloads.driveIDProvider = { [library] in library.catalogue.driveID }
        downloads.remoteSourceProvider = { [model] in model.downloadSource(for: $0) }
        downloads.fileRevisionProvider = { [library] source, id in
            guard library.catalogue.driveID == source else { return nil }
            return library.track(id: id).map(DownloadFileRevision.init)
        }
        model.onConnectionWillChange = { [weak downloads] in downloads?.revokeForegroundDownloads() }
        // Downloads from before profiles existed belong to the first profile.
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
        library.onServerTracksDeleted = { [library, downloads, player, watchBridge] sourceID, trackIDs in
            downloads.removeServerTracks(sourceID: sourceID, trackIDs: trackIDs)
            // Only those songs leave the queue; the music stops only if the playing one is among them.
            if library.catalogue.driveID == sourceID { player.removeFromQueue(ids: trackIDs) }
            watchBridge.serverTracksDeleted(sourceID: sourceID, trackIDs: trackIDs)
        }
        model.onVerifiedServerListing = { [watchBridge] sourceID, presentIDs in
            watchBridge.reconcileServerDeletions(sourceID: sourceID, presentTrackIDs: presentIDs)
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
        // A song on this iPhone plays from disk, whether or not the server is reachable.
        player.mediaSourceProvider = { [library, downloads] track in
            downloads.localURL(for: track).map(RemoteMediaSource.url) ?? library.mediaSource(for: track)
        }
        // A stream refused because the NAS ended its session plays again once the session is renewed.
        player.streamFailureRecovery = { [model] url in await model.recoverStream(from: url) }
        player.artworkProvider = { [library] album in
            library.coverURL(for: album).map { ($0, library.coverVersion(for: album)) }
        }
        player.sourceIDProvider = { [library] in library.catalogue.driveID }
        // Through the song as the library has it now: a queued copy keeps its album's old identity
        // after the album is renamed or regrouped.
        player.albumProvider = { [library] track in library.track(id: track.id).flatMap { library.album(for: $0) } ?? library.album(for: track) }
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
        profiles.onActivate = { [library, model, player, downloads, widgetFeed, watchBridge, profiles] profile in
            downloads.activeProfileID = profile.id
            library.loadProfileState()
            reconcileDownloads()
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
            widgetFeed.refresh()
            // The Watch grant sees every opening, so it knows the library was open here before a
            // sign-out or folder change closes it, whether or not a Watch is in reach.
            watchBridge.sync()
        }
        profiles.onDeactivate = { [model, player, library, downloads, widgetFeed, watchBridge] in
            downloads.revokeForegroundDownloads()
            player.stop()
            library.metadataWriter.cancel()
            // The picker must not have the player sheet, with its favourite and playlist buttons, over it.
            model.isNowPlayingPresented = false
            downloads.activeProfileID = "locked"
            library.loadProfileState()
            widgetFeed.refresh()
            watchBridge.revoke()
        }
        // The document changed on another device: show it.
        profiles.onRemoteState = { [library, model, player, profiles, widgetFeed] in
            library.loadProfileState()
            reconcileDownloads()
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
            widgetFeed.refresh()
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
        widgetFeed.start(library: library, player: player, downloads: downloads, profiles: profiles)
        // Sample layout fixtures do not contact iCloud or change their profile as account checks finish.
        if !Self.isLayoutFixture { cloud.start() }
        // A paired Apple Watch gets the active profile's playlists and its own way into the server.
        // Its grant covers the profile, source and folder, never the profile session, which is new
        // on every opening: relaunching must not make the Watch clear its downloads.
        let watchScope: () -> String? = { [library, model, profiles] in
            guard model.stage == .ready, let active = profiles.active else { return nil }
            return WatchGrant.scope(profileID: active.id, sourceID: library.catalogue.driveID, rootPath: library.catalogue.rootPath)
        }
        watchBridge.scopeProvider = watchScope
        watchBridge.profileProvider = { [profiles] in profiles.active?.id }
        watchBridge.knownProfileIDsProvider = { [profiles] in
            profiles.isProfileIndexReadable ? Set(profiles.profiles.map(\.id)) : nil
        }
        // A profile deleted elsewhere or retired from the family may be the one the Watch still
        // holds while nobody has it open here; its grant ends now rather than at the next sync.
        profiles.onProfilesRemoved = { [watchBridge] in watchBridge.sync() }
        // Signing out removes the server; the Watch's catalogue and sign-in for it go too, even when
        // the NAS was out of reach all this launch and its library never opened here.
        // Nothing queued from the old library may play on, from the app or the lock screen.
        model.onSignedOut = { [watchBridge, player] in
            player.stop()
            watchBridge.revoke()
        }
        watchBridge.provider = { [library, model, profiles] in
            guard let scope = watchScope(), let active = profiles.active else { return nil }
            let profileName = active.name
            let catalogue = library.watchCatalogue(serverName: model.connection?.name ?? "Gumbo", profileName: profileName)
            return (catalogue, model.watchCredentials(), scope)
        }
        watchBridge.audioFileProvider = { [model, library, profiles, downloads] playlist, watchTrack in
            guard let profileSession = profiles.sessionID, profiles.active?.id == playlist.profileID,
                  playlist.driveID == library.catalogue.driveID,
                  let track = library.track(id: watchTrack.id), track.path == watchTrack.path,
                  !library.isDemo else { throw CancellationError() }
            let connectionToken = model.playbackConnectionToken
            let revision = library.contentRevision
            let sourceID = library.catalogue.driveID
            let destination = FileManager.default.temporaryDirectory.appending(path: "gumbo-watch-audio-" + UUID().uuidString + "." + (watchTrack.path as NSString).pathExtension)
            do {
                if let local = downloads.localURL(for: track) {
                    try await Task.detached { try FileManager.default.copyItem(at: local, to: destination) }.value
                } else {
                    guard let drive = library.drive as? any RemoteFileDrive, let path = track.path,
                          let size = track.fileSize, size > 0 else { throw MetadataWriteError.notConnected }
                    _ = try await WatchAudioPreparation.copy(drive: drive, path: path, to: destination, expectedBytes: size)
                }
                guard !Task.isCancelled, profiles.sessionID == profileSession, profiles.active?.id == playlist.profileID,
                      model.playbackConnectionToken == connectionToken, library.contentRevision == revision,
                      library.catalogue.driveID == sourceID, library.track(id: track.id)?.path == track.path else { throw CancellationError() }
                return destination
            } catch { try? FileManager.default.removeItem(at: destination); throw error }
        }
        watchBridge.artworkProvider = { [library] catalogue in
            library.watchArtworkSources(for: catalogue)
        }
        // Play tapped on a widget cover: the system performs the intent inside the app, in the
        // background when it has to launch it for that.
        PlaybackIntentBridge.handler = { [library, player, model, downloads, widgetFeed, profiles] albumID in
            guard let sessionID = profiles.sessionID, let album = library.album(id: albumID) else { return }
            let driveID = library.catalogue.driveID
            let command = player.beginDeferredPlaybackCommand()
            if downloads.state(for: downloads.owner(for: album)) != .downloaded {
                await model.waitForDrive(upTo: .seconds(8))
            }
            guard !Task.isCancelled, profiles.sessionID == sessionID, library.catalogue.driveID == driveID,
                  player.commandRevision == command else { return }
            if player.album?.id == album.id, player.hasTrack {
                player.togglePlayPause()
            } else {
                player.play(album: album)
            }
            widgetFeed.refresh()
        }
        // Development shortcut: `--sample-library` opens the built-in catalogue without a server.
        if ProcessInfo.processInfo.arguments.contains("--sample-library") {
            model.useSampleLibrary()
            model.openLibrary()
            #if DEBUG && targetEnvironment(simulator)
            // Deterministic layout fixtures use ordinary profile admission and only the sample library.
            // These arguments have no effect in device or Release builds.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-preview") {
                if arguments.contains("--preview-slow-scan") {
                    model.sampleScanDuration = .seconds(60)
                }
                profiles.openAutomaticallyIfPossible()
                if let index = arguments.firstIndex(of: "--preview-tab"), index + 1 < arguments.count {
                    switch arguments[index + 1] {
                    case "search": model.selectedTab = .search
                    case "playlists": model.selectedTab = .playlists
                    case "downloads": model.selectedTab = .downloads
                    case "settings": model.selectedTab = .settings
                    default: break
                    }
                }
                if let index = arguments.firstIndex(of: "--preview-query"), index + 1 < arguments.count {
                    model.searchQuery = arguments[index + 1]
                }
                model.appearance = arguments.contains("--preview-dark") ? .dark : .light
            }
            #endif
        }
    }

    @State private var scanAliveTask: UIBackgroundTaskIdentifier = .invalid

    /// The half minute iOS grants after the app leaves the screen, spent finishing the current batch.
    private func keepScanAlive() {
        guard scanAliveTask == .invalid else { return }
        scanAliveTask = UIApplication.shared.beginBackgroundTask(withName: "scan") { endScanAliveTask() }
    }

    private func endScanAliveTask() {
        guard scanAliveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(scanAliveTask)
        scanAliveTask = .invalid
    }

    /// Where a widget or Live Activity link lands, whether the app was running or has just been launched for it.
    private func open(_ destination: WidgetLink.Destination?) {
        switch destination {
        case .album(let id):
            if let album = library.album(id: id) { model.showAlbum(album) }
        case .playlist(let id):
            if let playlist = library.playlist(id: id) { model.showPlaylist(playlist) }
        case .tab(let name):
            model.showTab(named: name)
        case .nowPlaying(let fallback):
            // After a cold start nothing is playing any more; the album or playlist the link came from stands in.
            if player.hasTrack { model.showNowPlaying() } else { open(fallback) }
        case nil:
            break
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .reauthenticationSheet()
                .downloadErrorAlert()
                .profileSaveErrorAlert()
                .scrollIndicators(.hidden)
                .onOpenURL { url in
                    // Something tapped on a Home Screen widget or on the download Live Activity.
                    open(WidgetLink.destination(from: url))
                }
                .environment(model)
                .environment(library)
                .environment(player)
                .environment(downloads)
                .environment(profiles)
                .environment(cloud)
                .tint(Palette.accent)
                .preferredColorScheme(model.appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                    downloads.setForegroundDownloadsActive(phase != .background)
                    if phase == .active || phase == .background { watchBridge.sync() }
                    if phase == .active, !Self.isLayoutFixture { Task { await cloud.refresh(reason: "foreground") } }
                    if phase == .background {
                        profiles.flushSave()
                        if model.isScanning {
                            keepScanAlive()
                            AppDelegate.scheduleScanContinuation()
                        }
                    }
                }
                // A long scan or tag write would stop the moment the phone locked; the screen stays on until it is done.
                .onChange(of: model.isScanning, initial: true) { _, scanning in
                    UIApplication.shared.isIdleTimerDisabled = (scanning || library.metadataWriter.isWriting) && model.keepsScreenOnWhileScanning
                    if !scanning { endScanAliveTask() }
                }
                .onChange(of: library.metadataWriter.isWriting) { _, writing in
                    UIApplication.shared.isIdleTimerDisabled = (writing || model.isScanning) && model.keepsScreenOnWhileScanning
                }
                .onChange(of: model.keepsScreenOnWhileScanning) { _, keeps in
                    UIApplication.shared.isIdleTimerDisabled = keeps && (model.isScanning || library.metadataWriter.isWriting)
                }
                .onChange(of: library.playlists) { watchBridge.sync() }
                .task(id: library.artworkRevision) {
                    // A scan can discover many covers together. Send only the settled batch.
                    do { try await Task.sleep(for: .milliseconds(400)) }
                    catch { return }
                    watchBridge.sync()
                }
                .onChange(of: model.stage) { watchBridge.sync() }
        }
    }
}
