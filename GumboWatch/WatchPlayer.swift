import AVFoundation
import Foundation
import MediaPlayer
import Observation
import GumboCore
import UIKit

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
    private var pendingFileKeys: Set<String> = []
    private var itemPositions: [ObjectIdentifier: Int] = [:]
    /// Whether the listener last asked to play; an interruption resumes only then.
    private var wantsToPlay = false
    private var interruptionResumeRevision: UInt64?
    private var interruptionObservers: [any NSObjectProtocol] = []

    private(set) var current: WatchTrack?
    private(set) var isPlaying = false
    private(set) var queueTitle: String?
    private(set) var lastError: String?

    private let player = AVQueuePlayer()
    private var queue: [(track: WatchTrack, url: URL)] = []
    private var itemTracks: [ObjectIdentifier: WatchTrack] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var commandsReady = false
    private var artwork: [String: Data] = [:]
    private var currentArtworkID: String?
    private var currentArtworkData: Data?
    private var currentArtwork: MPMediaItemArtwork?

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
        lastError = nil
        var order = files
        if shuffled {
            order.shuffle()
        } else if index > 0, index < order.count {
            order = Array(order[index...]) + Array(order[..<index])
        }
        pendingFileKeys = Set(order.map { $0.url.deletingPathExtension().lastPathComponent })
        setupRemoteCommands()
        guard await activateSession(for: command) else { return }
        guard !Task.isCancelled, authorization.isGranted,
              WatchDownloads.shared.allowsPlayback(order) else { return }
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
        wantsToPlay = true
        player.play()
    }

    /// Brings the audio session up, again after another app or an interruption took it. False when
    /// it couldn't, or a newer command replaced this one while the system connected the headphones.
    private func activateSession(for command: UInt64) async -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            guard try await session.activate(options: []) else {
                if intent.accepts(command) {
                    pendingActivation = false
                    pendingFileKeys = []
                    if !Task.isCancelled { lastError = "Audio couldn't start. Connect your headphones and try again." }
                }
                return false
            }
        } catch {
            if intent.accepts(command) {
                pendingActivation = false
                pendingFileKeys = []
                if !Task.isCancelled { lastError = "Audio couldn't start. \(error.localizedDescription)" }
            }
            return false
        }
        guard intent.accepts(command) else { return false }
        pendingActivation = false
        pendingFileKeys = []
        return true
    }

    func setAuthorization(_ value: WatchAuthorization) {
        if authorization != value {
            artwork = [:]
            stop()
        }
        authorization = value
    }

    func setArtwork(_ images: [String: Data]) {
        artwork = images
        updateNowPlaying()
    }

    func stopIfServerFilesWereDeleted(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        if (pendingActivation && !pendingFileKeys.isDisjoint(with: keys))
            || queue.contains(where: { keys.contains($0.url.deletingPathExtension().lastPathComponent) }) {
            stop()
        }
    }

    func stop() {
        intent.advance()
        wantsToPlay = false
        interruptionResumeRevision = nil
        pendingActivation = false
        pendingFileKeys = []
        player.pause()
        player.removeAllItems()
        queue = []
        itemTracks = [:]
        itemPositions = [:]
        current = nil
        queueTitle = nil
        isPlaying = false
        lastError = nil
        updateNowPlaying()
    }

    func dismissPlaybackError() { lastError = nil }

    private func pause() {
        intent.advance()
        wantsToPlay = false
        interruptionResumeRevision = nil
        pendingActivation = false
        pendingFileKeys = []
        player.pause()
    }

    /// Reactivates the session first: after an interruption or another app's audio, play() alone is silent.
    private func resume() {
        guard authorization.isGranted, player.currentItem != nil else { return }
        let command = intent.advance()
        wantsToPlay = true
        interruptionResumeRevision = nil
        pendingActivation = true
        pendingFileKeys = []
        Task {
            guard await activateSession(for: command), !Task.isCancelled,
                  authorization.isGranted, player.currentItem != nil else { return }
            player.play()
        }
    }

    /// A call, Siri or a timer pauses playback; it comes back only if nothing was pressed meanwhile.
    private func interruptionBegan() {
        let shouldResume = wantsToPlay && player.currentItem != nil
        pause()
        interruptionResumeRevision = shouldResume ? intent.value : nil
    }

    private func interruptionEnded(shouldResume: Bool) {
        let interrupted = interruptionResumeRevision
        interruptionResumeRevision = nil
        guard shouldResume, let interrupted, intent.accepts(interrupted) else { return }
        resume()
    }

    func togglePlayPause() {
        if pendingActivation || player.timeControlStatus == .playing { pause() } else { resume() }
    }

    func next() {
        intent.advance()
        pendingActivation = false
        pendingFileKeys = []
        player.advanceToNextItem()
    }

    func previous() {
        guard authorization.isGranted, let item = player.currentItem, let index = itemPositions[ObjectIdentifier(item)] else { return }
        let command = intent.advance()
        pendingActivation = false
        pendingFileKeys = []
        if player.currentTime().seconds > 3 || index == 0 {
            // A seek changes neither observed property, so Now Playing would keep counting from the old time.
            player.seek(to: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in self?.updateNowPlaying() }
            }
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
        // Remote command callbacks may arrive on a system queue, as with the shared player.
        func onMain(_ action: @escaping @MainActor (WatchPlayer) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
                return .success
            }
        }
        centre.playCommand.addTarget(handler: onMain { $0.resume() })
        centre.pauseCommand.addTarget(handler: onMain { $0.pause() })
        centre.togglePlayPauseCommand.addTarget(handler: onMain { $0.togglePlayPause() })
        centre.nextTrackCommand.addTarget(handler: onMain { $0.next() })
        centre.previousTrackCommand.addTarget(handler: onMain { $0.previous() })

        let notifications = NotificationCenter.default
        interruptionObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // Read the plain values first; the notification itself must not cross into the actor.
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self, let type else { return }
                switch type {
                case .began:
                    self.interruptionBegan()
                case .ended:
                    self.interruptionEnded(shouldResume: options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        })
        // Headphones gone: stay paused rather than resume later on another route.
        interruptionObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, reason == .oldDeviceUnavailable else { return }
                self.pause()
            }
        })
    }

    private func updateNowPlaying() {
        guard let track = current else {
            currentArtworkID = nil
            currentArtworkData = nil
            currentArtwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let data = track.albumID.flatMap { artwork[$0] }
        if track.albumID != currentArtworkID || data != currentArtworkData {
            currentArtworkID = track.albumID
            currentArtworkData = data
            currentArtwork = nil
            if let data, WatchArtwork.isThumbnail(data), let image = UIImage(data: data) {
                // MediaPlayer requests artwork on its own queue; never inherit the main actor.
                currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let currentArtwork { info[MPMediaItemPropertyArtwork] = currentArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
