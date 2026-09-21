#if os(iOS)
import GumboCore
import Intents

/// SiriKit Media supplies song, artist and album fields for natural "Play … in Gumbo" requests.
final class SiriMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private var resolved: [String: VoiceMediaSelection] = [:]
    private var resolutionID = UUID()

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        let suppliedID = suppliedItems(in: intent).first?.identifier
        // Preserve a choice returned by this dialog, but clear unrelated requests' candidates.
        if suppliedID.flatMap({ resolved[$0] }) == nil {
            resolved.removeAll()
            resolutionID = UUID()
        }
        let request = resolutionID
        Task { @MainActor in
            do {
                let selections = try await selections(for: intent)
                guard request == resolutionID else { completion([.unsupported()]); return }
                guard !selections.isEmpty else { completion([.unsupported()]); return }
                let controller = try GumboVoiceRouter.requireController()
                guard selections.allSatisfy(controller.isCurrent) else { throw VoicePlaybackError.changed }
                // Keep only this dialog's candidates; never donate a catalogue or listening history.
                resolved = Dictionary(selections.map { (siriIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
                let items = selections.map(mediaItem)
                completion(items.count == 1 ? [.success(with: items[0])] : [.disambiguation(with: Array(items.prefix(10)))])
            } catch VoicePlaybackError.openApp {
                completion([.unsupported(forReason: .loginRequired)])
            } catch VoicePlaybackError.unsupported {
                completion([.unsupported(forReason: .unsupportedMediaType)])
            } catch {
                completion([.unsupported()])
            }
        }
    }

    func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Task { @MainActor in
            do {
                let selections = try await selections(for: intent)
                guard selections.count == 1, let selection = selections.first,
                      try GumboVoiceRouter.requireController().isCurrent(selection) else {
                    completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil)); return
                }
                completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
            } catch {
                completion(INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            }
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Task { @MainActor in
            do {
                let controller = try GumboVoiceRouter.requireController()
                let command = controller.beginRequest()
                // Replacing the current queue is supported; don't silently ignore "play next" or speed.
                guard intent.playbackQueueLocation == .unknown || intent.playbackQueueLocation == .now,
                      intent.playbackSpeed == nil || intent.playbackSpeed == 1 else {
                    throw VoicePlaybackError.unsupported
                }
                let selections = try await selections(for: intent)
                guard selections.count == 1, let selection = selections.first else { throw VoicePlaybackError.noMatch }
                let repeatMode: PlayerModel.RepeatMode? = switch intent.playbackRepeatMode {
                case .none: .off
                case .all: .all
                case .one: .one
                default: nil
                }
                try await controller.play(selection, command: command, shuffle: intent.playShuffled, repeatMode: repeatMode)
                completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
            } catch VoicePlaybackError.openApp {
                completion(INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            } catch {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }
    }

    private func selections(for intent: INPlayMediaIntent) async throws -> [VoiceMediaSelection] {
        let controller = try GumboVoiceRouter.requireController()
        let supplied = suppliedItems(in: intent)
        guard supplied.count <= 1 else { throw VoicePlaybackError.unsupported }
        if let identifier = supplied.first?.identifier, !identifier.isEmpty {
            if let selection = resolved[identifier] { return [selection] }
            if identifier.hasPrefix("siri:") { throw VoicePlaybackError.changed }
            let selections = try await controller.selections(for: [identifier])
            guard !selections.isEmpty else { throw VoicePlaybackError.noMatch }
            return selections
        }
        let search = intent.mediaSearch
        let type = search?.mediaType ?? supplied.first?.type ?? .unknown
        let kind: VoiceMediaKind = switch type {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        case .unknown, .music: .any
        default: throw VoicePlaybackError.unsupported
        }
        let name = search?.mediaName ?? supplied.first?.title
            ?? (kind == .artist ? search?.artistName : nil)
            ?? (kind == .album ? search?.albumName : nil) ?? ""
        // No arbitrary first-song fallback when the request did not identify music.
        return try await controller.resolve(VoiceMediaQuery(kind: kind, name: name,
                                                     artist: search?.artistName, album: search?.albumName))
    }

    private func mediaItem(_ selection: VoiceMediaSelection) -> INMediaItem {
        let type: INMediaItemType = switch selection.kind {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        case .any: .music
        }
        return INMediaItem(identifier: siriIdentifier(selection), title: selection.title, type: type,
                           artwork: nil, artist: selection.subtitle)
    }

    private func siriIdentifier(_ selection: VoiceMediaSelection) -> String {
        "siri:\(resolutionID.uuidString):\(selection.id)"
    }

    private func suppliedItems(in intent: INPlayMediaIntent) -> [INMediaItem] {
        if let items = intent.mediaItems, !items.isEmpty { return items }
        return intent.mediaContainer.map { [$0] } ?? []
    }
}
#endif
