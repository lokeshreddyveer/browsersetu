#if APP_GROUP
import AppIntents
import SwiftUI
import WidgetKit

/// Buttons for Control Center and the Lock Screen. Each one opens the browser straight into an action through its URL scheme.
@available(iOS 18.0, *)
struct NewTabControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "BrowserSetuNewTabControl") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "browsersetu://command?id=new-tab")!)) {
                Label("New Tab", systemImage: "plus.square.on.square")
            }
        }
        .displayName("New Tab")
        .description("Opens a new tab ready for typing.")
    }
}

@available(iOS 18.0, *)
struct PrivateTabControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "BrowserSetuPrivateTabControl") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "browsersetu://command?id=new-private")!)) {
                Label("Private Tab", systemImage: "eye.slash")
            }
        }
        .displayName("Private Tab")
        .description("Opens a private tab that leaves nothing behind.")
    }
}

@available(iOS 18.0, *)
struct InboxControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "BrowserSetuInboxControl") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "browsersetu://command?id=inbox")!)) {
                Label("Inbox", systemImage: "tray")
            }
        }
        .displayName("Shared Inbox")
        .description("Opens the links you sent to Browser Setu from other apps.")
    }
}
#endif
