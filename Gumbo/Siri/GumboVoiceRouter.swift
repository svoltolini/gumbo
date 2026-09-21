import AppIntents
import GumboCore
import Foundation

/// Installed during app initialization, including a launch requested by Siri in the background.
@MainActor enum GumboVoiceRouter {
    static var controller: VoicePlaybackController?

    static func install(model: AppModel, library: LibraryStore, profiles: ProfileStore, player: PlayerModel, downloads: DownloadManager) {
        controller = VoicePlaybackController(context: {
            guard model.stage == .ready, !profiles.isLocked, let profile = profiles.active,
                  let session = profiles.sessionID, model.pendingServer == nil,
                  library.contentSourceID == library.catalogue.driveID,
                  library.contentRootPath == library.catalogue.rootPath else { return nil }
            return VoicePlaybackContext(sourceID: library.catalogue.driveID, rootPath: library.catalogue.rootPath,
                                        profileID: profile.id, sessionID: session, connectionToken: model.playbackConnectionToken,
                                        contentRevision: library.contentRevision)
        }, content: {
            (library.albums, library.playlists + [library.favouritesPlaylist, library.favouritesMixPlaylist,
                                                library.recentlyPlayedPlaylist, library.libraryShufflePlaylist])
        }, isDownloaded: { downloads.localURL(for: $0) != nil }, isConnected: {
            model.isDemo || (model.isConnected && library.drive != nil)
        }, waitForConnection: {
            await model.waitForDrive(upTo: .seconds(6))
        }, beginCommand: {
            player.beginDeferredPlaybackCommand()
        }, currentCommand: {
            player.commandRevision
        }, play: { tracks, title, shuffle, repeatMode in
            player.applySettings(repeatMode: repeatMode ?? player.repeatMode, shuffle: shuffle ?? player.isShuffling)
            player.play(queue: tracks, title: title)
            return player.lastError == nil
        })
        // Register after the query's controller is ready. Suggested entities remain empty;
        // this advertises the action without donating the user's catalogue or history.
        GumboMusicShortcuts.updateAppShortcutParameters()
    }

    static func requireController() throws -> VoicePlaybackController {
        guard let controller else { throw VoicePlaybackError.openApp }
        return controller
    }
}
