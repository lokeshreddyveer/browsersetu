import Foundation
import WebKit
@testable import Browser_Setu

/// Web view configurations for tests, each with an explicit website data store. A bare `WKWebViewConfiguration()` uses WebKit's default store, and the default store keeps
/// temporary files (`MediaCache`, `JavaScriptCoreDebug`) in the per-user temporary folder under the app's bundle id (`<DARWIN_USER_TEMP_DIR>/com.browsersetu.mac/WebKit`), the folder the
/// person's own Browser Setu uses; the relocated home does not cover it. A non-persistent store and an identifier store make neither (checked in the Stage 3 closure).
/// Choose by what the test verifies; a test that verifies the default store itself must say so and is not served by this file.
@MainActor
enum IsolatedWebKit {
    /// Nothing is kept after the store goes away. For tests of page scripts, filters, navigation, media and errors, where no website data has to survive.
    static func ephemeralConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    /// A persistent store of the test's own (a fresh identifier), for tests that need ordinary, non-private browsing: an extension's content scripts (WebKit keeps them out of
    /// non-persistent stores unless the extension may see private data) and code that behaves differently for a persistent store. Its data lives under the test process's relocated
    /// home (`~/Library/WebKit/<bundle id>/WebsiteDataStore/<identifier>`), never in the person's own.
    static func persistentConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID())
        return configuration
    }

    /// An extension controller's configuration with every store named. A controller's `defaultWebsiteDataStore` (extension contexts' own website data and cookies) is WebKit's default store
    /// unless set, even for a non-persistent or identified controller, and so are the web views it makes for extension pages. With an identifier, the controller's own state and its store
    /// persist under that identifier (inside the test process's relocated home), so a test can restart a manager on the same profile; without one, nothing is kept.
    /// An engine whose extension controller has every store named (see `extensionControllerConfiguration`), keyed to the profile's own test identity. Needed by tests whose model opens a
    /// non-persistent, non-private tab (a scratch tab, a temporary Glance session): WebKit gives such a tab the controller's default store, which is WebKit's default store unless named.
    static func engine() -> WebKitEngine {
        let engine = WebKitEngine()
        if #available(macOS 15.4, *) { engine.extensionControllerConfiguration = { extensionControllerConfiguration(identifier: ProfileIdentity.storeID(for: $0)) } }
        return engine
    }

    @available(macOS 15.4, *)
    static func extensionControllerConfiguration(identifier: UUID?) -> WKWebExtensionController.Configuration {
        let configuration = identifier.map { WKWebExtensionController.Configuration(identifier: $0) } ?? .nonPersistent()
        let store = identifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()      // a copy: change it, then give it back
        pages.websiteDataStore = store
        configuration.webViewConfiguration = pages
        return configuration
    }
}
