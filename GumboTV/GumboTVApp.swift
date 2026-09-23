import CloudKit
#if DEBUG && targetEnvironment(simulator)
@testable import GumboCore
#else
import GumboCore
#endif
import SwiftUI
import UIKit

private enum TVLayoutFixture {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--sample-library")
            && ProcessInfo.processInfo.arguments.contains("--ui-preview")
        #else
        false
        #endif
    }
}

/// Silent iCloud pushes keep the television's profiles and playlists current.
final class TVAppDelegate: NSObject, UIApplicationDelegate {
    static var cloud: CloudSync?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !TVLayoutFixture.isEnabled { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        await Self.cloud?.refresh(reason: "iCloud push")
        return .newData
    }
}

@main
struct GumboTVApp: App {
    @UIApplicationDelegateAdaptor(TVAppDelegate.self) private var appDelegate
    @State private var profiles: ProfileStore
    @State private var cloud: CloudSync
    @State private var library: LibraryStore
    @State private var model: AppModel
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let profiles: ProfileStore
        let cloud: CloudSync
        let library = LibraryStore()
        let model: AppModel
        #if DEBUG && targetEnvironment(simulator)
        if TVLayoutFixture.isEnabled {
            let directory = FileManager.default.temporaryDirectory.appending(path: "GumboTVPreview-" + UUID().uuidString)
            let defaults = UserDefaults(suiteName: "Gumbo.TVPreview." + UUID().uuidString)!
            profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults)
            cloud = CloudSync(services: CloudServices(identity: { .noAccount }, sharedZones: { [] }, createZone: { _ in },
                subscribe: {}, changes: { _, _ in CloudChangePage(records: []) }, modify: { _, _, _ in CloudModifyResult() }),
                persistence: CloudPersistence(directory: directory.appending(path: "cloud")))
            model = AppModel(library: library, defaults: defaults, services: ConnectionServices(), restoresSession: false)
        } else {
            profiles = ProfileStore()
            cloud = CloudSync()
            model = AppModel(library: library)
        }
        #else
        profiles = ProfileStore()
        cloud = CloudSync()
        model = AppModel(library: library)
        #endif
        cloud.profiles = profiles
        profiles.sync = TVLayoutFixture.isEnabled ? nil : cloud
        TVAppDelegate.cloud = cloud
        library.profiles = profiles
        model.profiles = profiles
        let player = PlayerModel()
        // Nothing is kept on a television; the manager only exists so the shared screens have one.
        let downloads = DownloadManager()
        downloads.driveIDProvider = { [library] in library.catalogue.driveID }
        downloads.remoteSourceProvider = { [model] in model.downloadSource(for: $0) }
        downloads.fileRevisionProvider = { [library] source, id in
            guard library.catalogue.driveID == source else { return nil }
            return library.track(id: id).map(DownloadFileRevision.init)
        }
        model.onConnectionWillChange = { [weak downloads] in downloads?.revokeForegroundDownloads() }
        // Signing out or leaving the sample library clears the player: nothing queued from the old
        // library may play on, from the app or the system's Now Playing controls.
        model.onSignedOut = { [player] in player.stop() }
        downloads.activeProfileID = profiles.lastActiveID ?? profiles.owner?.id ?? "default"
        // Persist download membership changes to iCloud via the profile state (TV doesn't keep files, but membership syncs).
        downloads.onMembershipChanged = { [profiles] driveID, albumIDs, playlistIDs in
            profiles.updateLibrary(driveID) { library in
                library.downloadedAlbums = albumIDs
                library.downloadedPlaylists = playlistIDs
            }
        }
        library.onAlbumRenamed = { [downloads] oldID, newID in downloads.reassignAlbum(from: oldID, to: newID) }
        library.onServerTracksDeleted = { [library, downloads, player] sourceID, trackIDs in
            downloads.removeServerTracks(sourceID: sourceID, trackIDs: trackIDs)
            if library.catalogue.driveID == sourceID, player.queue.contains(where: { trackIDs.contains($0.id) }) {
                player.stop()
            }
        }

        player.mediaSourceProvider = { [library, downloads] track in downloads.localURL(for: track).map(RemoteMediaSource.url) ?? library.mediaSource(for: track) }
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
        profiles.onActivate = { [library, model, player, downloads] profile in
            downloads.activeProfileID = profile.id
            library.loadProfileState()
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
        if !TVLayoutFixture.isEnabled { cloud.start() }
        // Development shortcuts: the sample catalogue, a locked picker, and something playing.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--sample-library") {
            model.useSampleLibrary()
            model.openLibrary()
            if TVLayoutFixture.isEnabled {
                profiles.openAutomaticallyIfPossible()
                model.appearance = .light
            }
        }
        if arguments.contains("--locked") { profiles.lock() }
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .reauthenticationSheet()
                .profileSaveErrorAlert()
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
                    if phase == .active && !TVLayoutFixture.isEnabled { Task { await cloud.refresh(reason: "foreground") } }
                    if phase == .background { profiles.flushSave() }
                }
        }
    }
}
