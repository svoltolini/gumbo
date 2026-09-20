import AVFoundation
import Foundation
import MediaPlayer
import Observation
import GumboCore

/// Plays a downloaded playlist from the watch's own storage, through whatever headphones the
/// system offers when the audio session comes up. The Now Playing screen and the crown are wired
/// through the system's remote commands and now-playing info.
@Observable
@MainActor
final class WatchPlayer {
    static let shared = WatchPlayer()
    private var authorization = WatchAuthorization(revision: 0, isGranted: false)
    private var intent = PlaybackIntentRevision()
    private var pendingActivation = false
    private var itemPositions: [ObjectIdentifier: Int] = [:]

    private(set) var current: WatchTrack?
    private(set) var isPlaying = false
    private(set) var queueTitle: String?

    private let player = AVQueuePlayer()
    private var queue: [(track: WatchTrack, url: URL)] = []
    private var itemTracks: [ObjectIdentifier: WatchTrack] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var commandsReady = false

    init() {
        // KVO arrives on whatever thread changed the player; hop to the main actor before touching state.
        observers.append(player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in self?.currentItemChanged(item) }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = self?.player.timeControlStatus == .playing
                self?.updateNowPlaying()
            }
        })
    }

    /// Starts the playlist from a song, in order or shuffled.
    func play(_ files: [(track: WatchTrack, url: URL)], title: String, startingAt index: Int = 0, shuffled: Bool = false) async {
        guard authorization.isGranted, !files.isEmpty,
              WatchDownloads.shared.allowsPlayback(files) else { return }
        let command = intent.advance()
        pendingActivation = true
        var order = files
        if shuffled {
            order.shuffle()
        } else if index > 0, index < order.count {
            order = Array(order[index...]) + Array(order[..<index])
        }
        setupRemoteCommands()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            _ = try await session.activate(options: [])
        } catch {
            if intent.accepts(command) { pendingActivation = false }
            return
        }
        guard !Task.isCancelled, intent.accepts(command), authorization.isGranted,
              WatchDownloads.shared.allowsPlayback(order) else { return }
        pendingActivation = false
        queue = order
        queueTitle = title
        player.removeAllItems()
        itemTracks = [:]
        itemPositions = [:]
        for (position, entry) in order.enumerated() {
            let item = AVPlayerItem(url: entry.url)
            itemTracks[ObjectIdentifier(item)] = entry.track
            itemPositions[ObjectIdentifier(item)] = position
            player.insert(item, after: nil)
        }
        player.play()
    }

    func setAuthorization(_ value: WatchAuthorization) {
        if authorization != value { stop() }
        authorization = value
    }

    func stop() {
        intent.advance()
        pendingActivation = false
        player.pause()
        player.removeAllItems()
        queue = []
        itemTracks = [:]
        itemPositions = [:]
        current = nil
        queueTitle = nil
        isPlaying = false
        updateNowPlaying()
    }

    private func pause() {
        intent.advance()
        pendingActivation = false
        player.pause()
    }

    private func resume() {
        guard authorization.isGranted, player.currentItem != nil else { return }
        intent.advance()
        pendingActivation = false
        player.play()
    }

    func togglePlayPause() {
        if pendingActivation || player.timeControlStatus == .playing { pause() } else { resume() }
    }

    func next() {
        intent.advance()
        pendingActivation = false
        player.advanceToNextItem()
    }

    func previous() {
        guard authorization.isGranted, let item = player.currentItem, let index = itemPositions[ObjectIdentifier(item)] else { return }
        let command = intent.advance()
        pendingActivation = false
        if player.currentTime().seconds > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            let files = queue
            let title = queueTitle ?? ""
            Task {
                guard intent.accepts(command) else { return }
                await play(files, title: title, startingAt: index - 1)
            }
        }
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        guard item === player.currentItem else { return }
        current = item.flatMap { itemTracks[ObjectIdentifier($0)] }
        updateNowPlaying()
    }

    private func setupRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        centre.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        centre.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        centre.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
