import GumboCore
import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct GumboWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @State private var store = WatchStore()
    @State private var player = WatchPlayer.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .tint(Palette.accent)
                .environment(store)
                .environment(WatchDownloads.shared)
                .environment(player)
                .task {
                    // Development shortcut: `--sample-library` shows the demo playlists without a phone.
                    if ProcessInfo.processInfo.arguments.contains("--sample-library") {
                        store.loadSample()
                    }
                }
        }
    }
}

/// Wakes the download session back up when the system relaunches the app for finished transfers,
/// and keeps the app awake for WatchConnectivity until the phone's queued content has arrived.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    private var connectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var connectivityObservers: [NSKeyValueObservation] = []

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKURLSessionRefreshBackgroundTask {
                WatchDownloads.shared.reconnect(identifier: refresh.sessionIdentifier) {
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask, WCSession.isSupported() {
                connectivityTasks.append(connectivity)
                observeConnectivity()
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        completeConnectivityTasksIfIdle()
    }

    /// A revocation, catalogue or relayed song may still be queued; the task is kept until it is delivered.
    private func observeConnectivity() {
        guard connectivityObservers.isEmpty else { return }
        let session = WCSession.default
        // KVO arrives on WatchConnectivity's queue; hop to the main actor before touching the tasks.
        connectivityObservers.append(session.observe(\.activationState) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.completeConnectivityTasksIfIdle() }
        })
        connectivityObservers.append(session.observe(\.hasContentPending) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.completeConnectivityTasksIfIdle() }
        })
    }

    private func completeConnectivityTasksIfIdle() {
        // The store applies what arrived in main-actor tasks; let those run before the app is suspended.
        Task { @MainActor in
            let session = WCSession.default
            guard !self.connectivityTasks.isEmpty, session.activationState == .activated, !session.hasContentPending else { return }
            let tasks = self.connectivityTasks
            self.connectivityTasks = []
            self.connectivityObservers = []
            for task in tasks { task.setTaskCompletedWithSnapshot(false) }
        }
    }
}
