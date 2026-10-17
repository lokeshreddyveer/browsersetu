import SwiftUI

@main
struct BrowserSetuiOSApp: App {
    @StateObject private var model = BrowserModel(engine: WebKitEngine(), root: Self.debugRoot)
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate

    private static var debugRoot: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "UITestRoot").map { $0.hasPrefix("/") ? $0 : NSTemporaryDirectory() + $0 }
        #else
        nil
        #endif
    }

    /// Hides a private tab in the app switcher: while the app is not in front, a blur sits over it.
    @ViewBuilder private var privateCover: some View {
        if scenePhase != .active, model.blurPrivateSwitcher, model.active?.isPrivate == true {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                .overlay { Image(systemName: "eye.slash.fill").font(.system(size: 40)).foregroundStyle(.secondary) }
                .transition(.identity)
        }
    }

    private static func run(quick type: String, model: BrowserModel) {
        switch type {
        case QuickAction.newTab: _ = model.newTab()
        case QuickAction.search: model.openSearchPanel()
        default: break
        }
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(model)
                .task {
                    await model.start()
                    QuickAction.handler = { type in Self.run(quick: type, model: model) }
                    if let pending = QuickAction.pending { QuickAction.pending = nil; Self.run(quick: pending, model: model) }
                }
                .onOpenURL { model.handleExternal($0) }
                .overlay { privateCover }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.saveNow() } }
        .commands { IOSBrowserCommands(model: model) }
    }
}
