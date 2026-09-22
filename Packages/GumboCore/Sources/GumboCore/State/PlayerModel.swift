import AVFoundation
import MediaPlayer
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Streams tracks from the server with AVPlayer; simulates playback for the demo catalogue.
@Observable
public final class PlayerModel {
    public nonisolated enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
    }

    public nonisolated enum CollectionPlaybackState: Equatable, Sendable {
        case inactive, playing, paused, loading, failed

        /// A preparing song can be paused too, preventing a late ready callback from starting it.
        public var canPause: Bool { self == .playing || self == .loading }
    }

    public private(set) var queue: [Track] = []
    /// The queue as it was handed over, for turning shuffle back off.
    private var orderedQueue: [Track] = []
    /// Original position of each queued occurrence. The same song may appear more than once.
    private var queueOrigins: [Int] = []
    public private(set) var index = 0
    /// Shared by app, widget and CarPlay requests so a late server response cannot replace newer intent.
    public private(set) var commandRevision = UUID()
    public var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { settingsChanged?(repeatMode, isShuffling) } }
    }
    public private(set) var isShuffling = false
    /// Set by the app: the profile remembers repeat and shuffle.
    public var settingsChanged: ((RepeatMode, Bool) -> Void)?

    /// Takes the profile's saved repeat and shuffle without touching the queue.
    public func applySettings(repeatMode: RepeatMode, shuffle: Bool) {
        self.repeatMode = repeatMode
        isShuffling = shuffle
    }

    /// Clears everything: another profile is taking over.
    public func stop() {
        recordPlaybackCommand()
        teardown()
        queue = []
        orderedQueue = []
        queueOrigins = []
        index = 0
        album = nil
        queueTitle = nil
        playbackSourceID = nil
        isPlaying = false
        position = 0
        lastError = nil
        nowPlayingArtwork = nil
        artworkAlbumID = nil
        updateNowPlayingInfo()
    }
    /// Audio is actually rolling: false while a song loads or a seek settles. The lock screen's rate
    /// follows this; Play/Pause controls follow `isPlaybackRequested`.
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var album: Album?
    public private(set) var queueTitle: String?
    /// File IDs are only unique inside a server/account, never across libraries.
    public private(set) var playbackSourceID: String?
    public private(set) var lastError: String?
    /// Output level, 0 to 1. The phone leaves this at 1 and uses its own controls; the Mac has a slider.
    public var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    /// Resolves a stream URL for a track; nil means the file is not reachable right now.
    public var streamURLProvider: ((Track) -> URL?)?
    public var mediaSourceProvider: ((Track) -> RemoteMediaSource?)?
    /// Asked once when a song streaming from the server fails, with the address it used; true when
    /// a fresh address can be made, for example because the server session has been renewed, and
    /// the song then loads again from where it stopped.
    public var streamFailureRecovery: ((URL) async -> Bool)?
    public var sourceIDProvider: (() -> String)?
    /// Whether a track without a URL may pretend to play (the sample library) instead of reporting an error.
    public var allowsSimulation: (() -> Bool)?
    public var artworkProvider: ((Album) -> (url: URL, version: Int)?)?
    private var artworkCacheKey: String?
    public var albumProvider: ((Track) -> Album?)?
    public var didStartAlbum: ((Album) -> Void)?
    public var didStartTrack: ((Track) -> Void)?

    private var player: (any PlaybackTransport)?
    private let makePlayer: (URL) -> any PlaybackTransport
    private let publishNowPlaying: ([String: Any]?) -> Void
    private let usesSystemControls: Bool
    /// User intent survives item preparation, but pausing must prevent a late callback from starting audio.
    private var wantsToPlay = false
    private var playbackGeneration = UUID()
    private var seekGeneration = UUID()
    private var pendingStartPosition: TimeInterval?
    private var recoverySeekInFlight = false
    /// The server address the current song streams from, until its one recovery attempt is used.
    private var recoverableStream: URL?
    /// Why the current song's stream failed, held back while that attempt runs: the request to play
    /// stands meanwhile, and the failure shows only if the song cannot load again.
    private var pendingStreamFailure: String?
    private var hasRecordedTrackStart = false
    private var ticker: Task<Void, Never>?
    private var anchorDate: Date?
    private var anchorPosition: TimeInterval = 0
    private var isSimulated = false
    private var remoteCommandsReady = false
    private var interruptionObservers: [any NSObjectProtocol] = []
    private var interruptionResumeRevision: UUID?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkAlbumID: String?

    public init() {
        makePlayer = { AVPlaybackTransport(url: $0) }
        publishNowPlaying = { MPNowPlayingInfoCenter.default().nowPlayingInfo = $0 }
        usesSystemControls = true
    }

    /// Exercises the actual command and recovery paths without audio output or shared system controls.
    init(makePlayer: @escaping (URL) -> any PlaybackTransport, publishNowPlaying: @escaping ([String: Any]?) -> Void) {
        self.makePlayer = makePlayer
        self.publishNowPlaying = publishNowPlaying
        usesSystemControls = false
    }

    public var track: Track? { queue.indices.contains(index) ? queue[index] : nil }
    public var hasTrack: Bool { track != nil }
    /// The listener asked for music, so Play/Pause shows Pause and the Now Playing cover stays full size.
    /// Unlike `isPlaying` it holds while a song loads, a seek settles, the next song starts or a refused
    /// stream gets a fresh address, so slow servers, scrubbing and session renewal do not flash Play;
    /// a pause, a failure that cannot be recovered or the end of the queue clears it.
    public var isPlaybackRequested: Bool { wantsToPlay }

    public var duration: TimeInterval {
        if let duration = player?.duration { return duration }
        return track?.duration ?? 0
    }

    public var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    public var remaining: TimeInterval { max(0, duration - position) }
    /// Colour of the playing album as the library has it now, so cover colours read later still apply.
    public var tint: Color { (track.flatMap { albumProvider?($0) } ?? album)?.primaryColor ?? Palette.neutralTint }

    // MARK: Commands

    /// Reserves a command before an asynchronous server wait; compare the returned revision before playing.
    @discardableResult
    public func beginDeferredPlaybackCommand() -> UUID {
        recordPlaybackCommand()
        return commandRevision
    }

    private func recordPlaybackCommand() {
        commandRevision = UUID()
        interruptionResumeRevision = nil
    }

    public func play(album: Album, startingAt index: Int = 0) {
        play(queue: album.tracks, startingAt: index, title: nil)
    }

    public func play(queue: [Track], startingAt index: Int = 0, title: String?) {
        recordPlaybackCommand()
        guard !queue.isEmpty else { return }
        playbackSourceID = sourceIDProvider?()
        orderedQueue = queue
        queueTitle = title
        let start = min(max(0, index), queue.count - 1)
        if isShuffling {
            queueOrigins = [start] + queue.indices.filter { $0 != start }.shuffled()
            self.queue = queueOrigins.map { queue[$0] }
            load(index: 0, autoplay: true)
        } else {
            queueOrigins = Array(queue.indices)
            self.queue = queue
            load(index: start, autoplay: true)
        }
    }

    /// Starts this occurrence in the existing queue without rebuilding or reshuffling that queue.
    public func playQueuedTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        recordPlaybackCommand()
        load(index: index, autoplay: true)
    }

    /// Shuffles what comes after the current song, or restores the original order around it.
    public func toggleShuffle() {
        isShuffling.toggle()
        settingsChanged?(repeatMode, isShuffling)
        guard queueOrigins.indices.contains(index) else { return }
        let currentOrigin = queueOrigins[index]
        if isShuffling {
            queueOrigins = [currentOrigin] + queueOrigins.filter { $0 != currentOrigin }.shuffled()
            queue = queueOrigins.map { orderedQueue[$0] }
            index = 0
        } else if !orderedQueue.isEmpty {
            queue = orderedQueue
            queueOrigins = Array(orderedQueue.indices)
            index = currentOrigin
        }
    }

    public func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Does what the Play/Pause glyph shows: Pause during loading or a seek cancels the pending start.
    public func togglePlayPause() {
        isPlaybackRequested ? pause() : resume()
    }

    public func resume() {
        recordPlaybackCommand()
        resumePlayback()
    }

    private func resumePlayback() {
        guard hasTrack else { return }
        wantsToPlay = true
        if isSimulated {
            anchorPosition = position
            anchorDate = .now
            startTicker()
            isPlaying = true
            recordTrackStart()
        } else if let player, case .failed = player.status {
            load(index: index, autoplay: true, resumingAt: position, isRetry: true)
        } else if player == nil {
            // A reconnect or a completed download may now provide a URL. Resolve it again.
            load(index: index, autoplay: true, resumingAt: position, isRetry: true)
        } else {
            // Resumes in place. After a failed seek this is the retry, which replaces the old error as a
            // reload would, so album and playlist controls show Pause alongside the transport.
            lastError = nil
            playWhenReady()
        }
        updateNowPlayingInfo()
    }

    public func pause() {
        recordPlaybackCommand()
        pausePlayback()
    }

    /// The interruption path uses this without discarding its conditional resume token.
    private func pausePlayback() {
        wantsToPlay = false
        pendingStreamFailure = nil
        if isSimulated {
            syncSimulatedPosition()
            stopTicker()
            anchorDate = nil
        } else {
            player?.pause()
        }
        isPlaying = false
        updateNowPlayingInfo()
    }

    public func next() {
        recordPlaybackCommand()
        advance(by: 1, autoplay: wantsToPlay || position == 0)
    }

    public func previous() {
        recordPlaybackCommand()
        advance(by: -1, autoplay: wantsToPlay || position == 0)
    }

    public func seek(toFraction fraction: Double) {
        recordPlaybackCommand()
        let target = max(0, min(1, fraction)) * duration
        if isSimulated {
            position = target
            anchorPosition = target
            anchorDate = isPlaying ? .now : nil
        } else {
            position = target
            seekGeneration = UUID()
            recoverySeekInFlight = false
            pendingStartPosition = target
            playWhenReady()
        }
        updateNowPlayingInfo()
    }

    public func isCurrent(track: Track) -> Bool {
        self.track?.id == track.id && playbackSourceID == sourceIDProvider?()
    }

    /// Match file identity and source, including a paused song at the beginning of its queue.
    public func playbackState(for track: Track, sourceID: String) -> CollectionPlaybackState {
        guard playbackSourceID == sourceID, sourceIDProvider?() == sourceID,
              self.track?.id == track.id else { return .inactive }
        return currentPlaybackState
    }

    /// Album/playlist controls follow the current song, even when it started in another collection.
    public func playbackState(for tracks: [Track], sourceID: String) -> CollectionPlaybackState {
        guard let track, tracks.contains(where: { $0.id == track.id }) else { return .inactive }
        return playbackState(for: track, sourceID: sourceID)
    }

    /// Preserve queue, shuffle, position and the selected occurrence when resuming this collection.
    public func togglePlayback(of tracks: [Track], sourceID: String, title: String? = nil) {
        guard sourceIDProvider?() == sourceID, !tracks.isEmpty else { return }
        switch playbackState(for: tracks, sourceID: sourceID) {
        case .playing, .loading: pause()
        case .paused, .failed: resume()
        case .inactive: play(queue: tracks, title: title)
        }
    }

    private var currentPlaybackState: CollectionPlaybackState {
        if lastError != nil { return .failed }
        if isPlaying { return .playing }
        return wantsToPlay ? .loading : .paused
    }

    // MARK: Loading

    private func advance(by delta: Int, autoplay: Bool) {
        guard !queue.isEmpty else { return }
        load(index: (index + delta + queue.count) % queue.count, autoplay: autoplay)
    }

    /// The song played to its end: repeat it, move on, wrap around, or stop, depending on the repeat mode.
    private func trackEnded() {
        guard !queue.isEmpty else { return }
        switch repeatMode {
        case .one:
            load(index: index, autoplay: true)
        case .all:
            load(index: (index + 1) % queue.count, autoplay: true)
        case .off:
            if index + 1 < queue.count {
                load(index: index + 1, autoplay: true)
            } else {
                load(index: index, autoplay: false)
            }
        }
    }

    private func load(index: Int, autoplay: Bool, resumingAt savedPosition: TimeInterval = 0, isRetry: Bool = false, isRecovery: Bool = false) {
        let alreadyRecordedStart = isRetry && hasRecordedTrackStart
        teardown()
        self.index = index
        position = savedPosition.isFinite ? max(0, savedPosition) : 0
        lastError = nil
        wantsToPlay = autoplay
        hasRecordedTrackStart = alreadyRecordedStart
        guard let track else { return }
        let resolved = albumProvider?(track)
        if resolved?.id != album?.id, let resolved { didStartAlbum?(resolved) }
        album = resolved
        // CarPlay and lock-screen Play must also work after the first URL lookup failed.
        if usesSystemControls { setupRemoteCommands() }

        if let source = mediaSourceProvider?(track) ?? streamURLProvider?(track).map(RemoteMediaSource.url) {
            isSimulated = false
            if usesSystemControls { configureAudioSession() }
            let player: any PlaybackTransport
            switch source {
            case .url(let url): player = makePlayer(url)
            case .file: player = AVPlaybackTransport(source: source)
            }
            player.volume = volume
            self.player = player
            if case .url(let url) = source, !url.isFileURL, !isRecovery { recoverableStream = url }
            pendingStartPosition = position > 0 ? position : nil
            let generation = playbackGeneration
            player.positionChanged = { [weak self] seconds in
                guard let self, playbackGeneration == generation,
                      self.player?.status == .ready,
                      pendingStartPosition == nil, !recoverySeekInFlight else { return }
                position = seconds.isFinite ? max(0, seconds) : 0
            }
            player.ended = { [weak self] in
                guard let self, playbackGeneration == generation, wantsToPlay else { return }
                trackEnded()
            }
            player.statusChanged = { [weak self] in
                guard let self, playbackGeneration == generation else { return }
                playWhenReady()
            }
            playWhenReady()
        } else if allowsSimulation?() ?? true {
            isSimulated = true
            if autoplay {
                anchorPosition = position
                anchorDate = .now
                isPlaying = true
                startTicker()
                recordTrackStart()
            } else {
                isPlaying = false
            }
        } else {
            // Offline and not downloaded: say so rather than pretending to play.
            isSimulated = false
            isPlaying = false
            wantsToPlay = false
            lastError = "This song isn't downloaded and the server can't be reached."
        }
        refreshNowPlayingArtwork()
        updateNowPlayingInfo()
    }

    private func teardown() {
        playbackGeneration = UUID()
        seekGeneration = UUID()
        wantsToPlay = false
        isPlaying = false
        isSimulated = false
        pendingStartPosition = nil
        recoverySeekInFlight = false
        recoverableStream = nil
        pendingStreamFailure = nil
        if nowPlayingArtwork == nil { artworkAlbumID = nil }
        stopTicker()
        anchorDate = nil
        player?.invalidate()
        player = nil
    }

    /// A play request becomes playback only once the current item and any recovery seek are ready.
    private func playWhenReady() {
        guard let player else { return }
        switch player.status {
        case .loading:
            isPlaying = false
        case .failed(let message):
            isPlaying = false
            player.pause()
            // While a refused stream gets a fresh address the request stands, so controls keep
            // showing Pause and a tap pauses; the failure shows only once that attempt settles.
            let recovering = pendingStreamFailure != nil || (wantsToPlay && recoverStream(failure: message))
            if !recovering {
                wantsToPlay = false
                lastError = message
            }
        case .ready:
            if let requestedPosition = pendingStartPosition, !recoverySeekInFlight {
                let target = player.duration.map { min(requestedPosition, $0) } ?? requestedPosition
                position = target
                recoverySeekInFlight = true
                isPlaying = false
                player.pause()
                let generation = playbackGeneration
                let seek = seekGeneration
                player.seek(to: target) { [weak self] finished in
                    guard let self, playbackGeneration == generation, seekGeneration == seek else { return }
                    recoverySeekInFlight = false
                    // The item failed under the seek and a fresh address is being made: that recovery
                    // reloads at this same position, or shows the failure, so the request stands.
                    if !finished, pendingStreamFailure != nil { return }
                    if finished {
                        pendingStartPosition = nil
                        playWhenReady()
                    } else {
                        wantsToPlay = false
                        isPlaying = false
                        lastError = "Playback couldn't return to this position. Try playing again."
                        updateNowPlayingInfo()
                    }
                }
            } else if !recoverySeekInFlight, wantsToPlay, !isPlaying {
                lastError = nil
                player.play()
                isPlaying = true
                recordTrackStart()
            }
        }
        updateNowPlayingInfo()
    }

    /// A streamed song may have failed only because its address went out of date, as when the
    /// server ended the session it carried. Ask once; when a fresh address can be made, load the
    /// song again from the same place, unless the listener has asked for something else meanwhile.
    /// Returns false when there is nothing to ask, and the failure is reported straight away.
    private func recoverStream(failure: String) -> Bool {
        guard let url = recoverableStream, streamFailureRecovery != nil else { return false }
        recoverableStream = nil
        pendingStreamFailure = failure
        let generation = playbackGeneration
        let command = commandRevision
        let resumeAt = position
        Task { [weak self] in
            let recovered = await self?.streamFailureRecovery?(url) ?? false
            // A pause, stop, another song or the deadline has already settled what the controls show.
            guard let self, playbackGeneration == generation, let failure = pendingStreamFailure else { return }
            if recovered, commandRevision == command {
                pendingStreamFailure = nil
                load(index: index, autoplay: true, resumingAt: resumeAt, isRetry: true, isRecovery: true)
            } else {
                // Not recoverable, or a seek or a widget, CarPlay or Siri request took over without
                // starting a song: report the failure, and Play loads the song again.
                settleStreamFailure(failure)
            }
        }
        // A server that doesn't answer, rather than one that ended the session, must not leave Pause
        // showing with nothing playing for as long as its requests take to time out.
        let deadline = streamRecoveryDeadline
        Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self, playbackGeneration == generation, let failure = pendingStreamFailure else { return }
            settleStreamFailure(failure)
        }
        return true
    }

    /// How long a refused stream may wait for a fresh address before its failure shows. Play then
    /// loads the song again, with the renewed session if the renewal finished meanwhile.
    var streamRecoveryDeadline: Duration = .seconds(10)

    private func settleStreamFailure(_ failure: String) {
        pendingStreamFailure = nil
        wantsToPlay = false
        lastError = failure
        updateNowPlayingInfo()
    }

    private func recordTrackStart() {
        guard !hasRecordedTrackStart, let track else { return }
        hasRecordedTrackStart = true
        didStartTrack?(track)
    }

    private func configureAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        setupRemoteCommands()
    }

    // MARK: Lock screen, Control Center and headphone controls

    /// System interruption handling is separate from explicit Pause, which cancels an automatic resume.
    func interruptionBegan() {
        let shouldResume = wantsToPlay
        recordPlaybackCommand()
        interruptionResumeRevision = shouldResume ? commandRevision : nil
        pausePlayback()
    }

    func interruptionEnded(shouldResume: Bool) {
        let interruptedCommand = interruptionResumeRevision
        interruptionResumeRevision = nil
        guard shouldResume, interruptedCommand == commandRevision else { return }
        resumePlayback()
    }

    func outputDeviceRemoved() {
        // This must cancel a pending interruption resume even while the transport is already paused.
        pause()
    }

    /// Registers once for the system transport controls and for interruptions such as calls.
    private func setupRemoteCommands() {
        guard !remoteCommandsReady else { return }
        remoteCommandsReady = true
        let center = MPRemoteCommandCenter.shared()
        // The system may call these on any thread, so each one hops to the main actor before touching the player.
        func onMain(_ action: @escaping @MainActor (PlayerModel) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] _ in
                Task { @MainActor in
                    // Pause also cancels deferred widget/CarPlay starts before a track exists.
                    guard let self else { return }
                    action(self)
                }
                return .success
            }
        }
        center.playCommand.addTarget(handler: onMain { $0.resume() })
        center.pauseCommand.addTarget(handler: onMain { $0.pause() })
        center.togglePlayPauseCommand.addTarget(handler: onMain { $0.togglePlayPause() })
        center.nextTrackCommand.addTarget(handler: onMain { $0.next() })
        center.previousTrackCommand.addTarget(handler: onMain { $0.previous() })
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in
                guard let self, self.hasTrack, self.duration > 0 else { return }
                self.seek(toFraction: seconds / self.duration)
            }
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        #if !os(macOS)
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
        // Headphones unplugged: pause rather than blare from the speaker.
        interruptionObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, reason == .oldDeviceUnavailable else { return }
                self.outputDeviceRemoved()
            }
        })
        #endif
    }

    /// What the lock screen and Control Center show: title, artist, artwork, duration and position.
    private func updateNowPlayingInfo() {
        guard let track else {
            publishNowPlaying(nil)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: album?.artist ?? track.artist ?? "",
            MPMediaItemPropertyAlbumTitle: album?.title ?? queueTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let nowPlayingArtwork, artworkAlbumID == album?.id {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        publishNowPlaying(info)
    }

    /// Loads the album cover for the lock screen once per album.
    private func refreshNowPlayingArtwork() {
        guard let album else {
            nowPlayingArtwork = nil
            artworkAlbumID = nil
            artworkCacheKey = nil
            return
        }
        let artwork: (url: URL, version: Int)?
        if let artworkProvider { artwork = artworkProvider(album) }
        else { artwork = CoverStore.hasCover(for: album.id) ? (CoverStore.fileURL(for: album.id), 0) : nil }
        guard let artwork else { nowPlayingArtwork = nil; artworkAlbumID = nil; artworkCacheKey = nil; return }
        let url = artwork.url
        let key = "\(url.absoluteString)|\(artwork.version)|lockscreen"
        guard artworkCacheKey != key else { return }
        nowPlayingArtwork = nil
        artworkAlbumID = album.id
        artworkCacheKey = key
        let generation = playbackGeneration
        Task { [weak self] in
            guard let image = await CoverImageCache.shared.image(url: url, key: key, maxPixelSize: CoverImageCache.largePixels) else { return }
            guard let self, playbackGeneration == generation, artworkAlbumID == album.id, artworkCacheKey == key else { return }
            let size = CGSize(width: image.width, height: image.height)
            // Requested on a background thread by the system; only the CGImage crosses into the closure.
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
                #if canImport(UIKit)
                UIImage(cgImage: image)
                #else
                NSImage(cgImage: image, size: size)
                #endif
            }
            updateNowPlayingInfo()
        }
    }

    // MARK: Demo simulation

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func syncSimulatedPosition() {
        guard let anchorDate else { return }
        position = anchorPosition + Date.now.timeIntervalSince(anchorDate)
    }

    private func tick() {
        guard isPlaying, isSimulated else { return }
        syncSimulatedPosition()
        if position >= duration {
            trackEnded()
        }
    }
}
