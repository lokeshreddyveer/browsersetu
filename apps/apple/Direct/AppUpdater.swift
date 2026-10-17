import Sparkle
import SwiftUI

/// Keeps the downloadable Mac app current: checks the public release feed in the background and offers new versions. Updates are signed with a key only the
/// publisher holds, so only genuine releases install. This file is only in the downloadable build; the App Store build has no updater.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func start() { _ = controller }
}

struct CheckForUpdatesButton: View {
    var body: some View { Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() } }
}

struct UpdatesSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
            Button("Check Now…") { updater.checkForUpdates() }
        } header: { Text("Updates") } footer: {
            Text("Looks once a day at github.com for a new version and asks before installing it. Each update is signed; one that is not signed by Browser Setu's key is refused. Nothing about you is sent beyond the app's version.")
        }
    }
}
