import SwiftUI

#if os(macOS)
import AppKit
import ObjectiveC
import WebKit

/// No scroll bars in the app's own interface. SwiftUI's `scrollIndicators(.hidden)` does not reach the system scroller of a list, a grouped form, a table or a text editor on the Mac, so a scroll view
/// is told, each time it lays out, to have no scrollers. It still scrolls (wheel, trackpad, arrow and page keys, VoiceOver's scroll actions); only the bars are gone.
///
/// What it leaves alone, deliberately:
///  - the system's own panels (Open, Save, Color, Font), which are not the app's interface;
///  - everything, while VoiceOver or Switch Control is running (the scroller tells those users where they are in a list);
///  - anything inside a web view (a page draws its own scrollbars);
///  - a person who wants the bars back: `defaults write com.browsersetu.mac BrowserSetuShowScrollBars -bool YES`.
enum NoScrollBars {
    nonisolated(unsafe) private static var installed = false

    static let showScrollBarsKey = "BrowserSetuShowScrollBars"

    /// The rule, apart from AppKit so it can be tested.
    static func shouldHide(isSystemPanel: Bool, assistiveTechnologyRunning: Bool, insideWebView: Bool, personWantsScrollBars: Bool) -> Bool {
        !(isSystemPanel || assistiveTechnologyRunning || insideWebView || personWantsScrollBars)
    }

    static func shouldHide(_ scrollView: NSScrollView) -> Bool {
        let window = scrollView.window
        let isSystemPanel = window is NSSavePanel || window is NSColorPanel || window is NSFontPanel
        let workspace = NSWorkspace.shared
        var insideWebView = false
        var ancestor: NSView? = scrollView.superview
        while let view = ancestor { if view is WKWebView { insideWebView = true; break }; ancestor = view.superview }
        return shouldHide(isSystemPanel: isSystemPanel,
                          assistiveTechnologyRunning: workspace.isVoiceOverEnabled || workspace.isSwitchControlEnabled,
                          insideWebView: insideWebView,
                          personWantsScrollBars: UserDefaults.standard.bool(forKey: showScrollBarsKey))
    }

    /// Called once at launch.
    static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let replacement = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.bs_tileWithoutScrollers)) else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension NSScrollView {
    /// After the swap this is `tile()`: it runs the system's layout (the call below reaches the original), then removes the scrollers where the rules above allow.
    @objc func bs_tileWithoutScrollers() {
        bs_tileWithoutScrollers()
        guard hasVerticalScroller || hasHorizontalScroller, NoScrollBars.shouldHide(self) else { return }
        if hasVerticalScroller { hasVerticalScroller = false }
        if hasHorizontalScroller { hasHorizontalScroller = false }
    }
}
#endif
