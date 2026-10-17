import UIKit

/// The shortcuts shown when the app icon is pressed and held: New Tab and Search. They arrive through the scene (so they work from a cold
/// start too) and are handed to the browser once it is running.
enum QuickAction {
    static let newTab = "com.browsersetu.quick.newtab"
    static let search = "com.browsersetu.quick.search"
    /// Set when the app was started by a shortcut, before the browser exists.
    static var pending: String?
    /// Set by the browser once it is running.
    static var handler: ((String) -> Void)?

    static func deliver(_ type: String) {
        if let handler { handler(type) } else { pending = type }
    }
}

final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickAction.pending = item.type }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        QuickAction.deliver(shortcutItem.type)
        completionHandler(true)
    }
}
