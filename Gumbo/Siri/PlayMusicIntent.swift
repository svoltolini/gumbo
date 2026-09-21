import AppIntents
import GumboCore

struct GumboMusicEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music")
    static let defaultQuery = GumboMusicQuery()
    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    init(_ selection: VoiceMediaSelection) {
        id = selection.id; name = selection.title; detail = selection.subtitle
    }
}

struct GumboMusicQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [GumboMusicEntity] {
        try await GumboVoiceRouter.requireController().selections(for: identifiers).map(GumboMusicEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [GumboMusicEntity] {
        let selections = try await GumboVoiceRouter.requireController().resolve(VoiceMediaQuery(name: string))
        guard !selections.isEmpty else { throw VoicePlaybackError.noMatch }
        return selections.map(GumboMusicEntity.init)
    }

    // Do not proactively send the person's listening history or full library to Siri.
    func suggestedEntities() async throws -> [GumboMusicEntity] { [] }
}

struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Play a song, album, artist or playlist from your Gumbo library.")
    static let openAppWhenRun = true

    @Parameter(title: "Music", requestValueDialog: "Which song, album, artist or playlist?",
               requestDisambiguationDialog: "Which one would you like?")
    var music: GumboMusicEntity

    // Spotlight can expose an action only when its summary includes every required parameter.
    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$music)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try GumboVoiceRouter.requireController()
        let command = controller.beginRequest()
        guard let selection = try await controller.selections(for: [music.id]).first else { throw VoicePlaybackError.noMatch }
        try await controller.play(selection, command: command)
        return .result(dialog: "Opening \(selection.title) in Gumbo.")
    }
}

struct GumboMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMusicIntent(), phrases: [
            "Play music in \(.applicationName)",
            "Play \(\.$music) in \(.applicationName)"
        ], shortTitle: "Play Music", systemImageName: "play.fill")
    }
}
