#if os(iOS) || os(macOS)
import SwiftUI
#if os(iOS)
import Intents
import UIKit
#endif

struct SiriSettingsView: View {
    #if os(iOS)
    @State private var authorization = INPreferences.siriAuthorizationStatus()
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        Form {
            Section {
                Label("Your music, by voice", systemImage: "waveform")
                    .font(.headline)
                #if os(iOS)
                Text("Ask Siri to play a song, album, artist or playlist in Gumbo Music.")
                Text("“Play [song name] by [artist] in Gumbo Music.”")
                    .foregroundStyle(.secondary)
                #else
                Text("Say “Play music in Gumbo Music,” then name a song, album, artist or playlist. You can also add Play Music to a shortcut in the Shortcuts app.")
                #endif
            }
            #if os(iOS)
            Section {
                switch authorization {
                case .authorized:
                    Label("Siri is enabled", systemImage: "checkmark.circle")
                case .notDetermined:
                    Button("Enable Siri") {
                        INPreferences.requestSiriAuthorization { status in
                            Task { @MainActor in authorization = status }
                        }
                    }
                case .denied, .restricted:
                    Text("Allow Gumbo to work with Siri in your device’s Settings.")
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                @unknown default: Text("Check Siri access in your device’s Settings.")
                }
            }
            #endif
            Section("Before you ask") {
                Text("Set up your music server and open your profile in Gumbo first. If your profile is locked, open it in the app before asking Siri.")
                Text("Keep your server reachable, or download the music to this device for offline listening.")
            }
            Section("Privacy") {
                Text("Apple handles your voice request. Gumbo matches it against the library on this device and returns only matching music names to Siri. Gumbo does not send Siri your NAS password, music files, full library or listening history.")
            }
        }
        .groupedForm()
        .navigationTitle("Siri & Shortcuts")
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization = INPreferences.siriAuthorizationStatus() }
        }
        #endif
    }
}
#endif
