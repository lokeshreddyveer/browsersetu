import SwiftUI

/// Which toolbar buttons the person has switched on, so a hidden button takes no room when the bar works out what fits.
struct ToolbarVisibility: Equatable {
    var sidebar = true, backForward = true, share = true, newTab = true, overview = true, bookmark = true, downloads = true
    /// Extension buttons drawn at the right of the bar (pinned actions and the extensions menu).
    var extensionButtons = 0
    static let all = ToolbarVisibility()
}

/// Which optional buttons fit. Lower-priority actions move into the More menu as the window narrows.
struct ToolbarPriority: Equatable {
    var showBookmark: Bool, showDownloads: Bool, showOptional: Bool, showForward: Bool
    /// How many of the buttons the person added (workspaces, split view…) sit with the optional ones; they leave with them when the window is narrow.
    var extras = 0
    /// Which buttons are switched on. The default is all of them, which is also the most room any of them can take.
    var visible = ToolbarVisibility.all

    init(width: CGFloat) {
        showForward = width >= 400
        showBookmark = width >= 560
        showDownloads = width >= 640
        showOptional = width >= 920
    }
}

extension ToolbarPriority {
    private static let button: CGFloat = 28

    /// Chooses the most controls that still leave the address field room, dropping them in a fixed order:
    /// share/new tab/overview, downloads, bookmark, forward. Back and More never leave.
    init(fitting window: CGFloat, leadingInset: CGFloat, extras: Int = 0, visible: ToolbarVisibility = .all) {
        let candidates = [ToolbarPriority(width: 1000), ToolbarPriority(width: 700), ToolbarPriority(width: 600),
                          ToolbarPriority(width: 450), ToolbarPriority(width: 300)].map { candidate -> ToolbarPriority in
            var c = candidate; c.extras = extras; c.visible = visible; return c
        }
        self = candidates.first { window >= $0.requiredWindow(leadingInset: leadingInset) } ?? candidates[candidates.count - 1]
    }

    /// Only what is switched on takes room: a hidden sidebar button or back/forward pair leaves none.
    func leadingWidth(inset: CGFloat) -> CGFloat {
        inset + (visible.sidebar ? Self.button + 2 : 0) + (visible.backForward ? 4 + Self.button + (showForward ? Self.button : 0) : 0) + 8
    }

    /// The buttons on the right: More (never hidden), the extension buttons, bookmark, downloads, and, when there is room, share, new tab, tab overview and the added buttons.
    var trailingWidth: CGFloat {
        let optional = [visible.share, visible.newTab, visible.overview].filter { $0 }.count + extras
        return 4 + Self.button * CGFloat(1 + visible.extensionButtons)
            + (visible.bookmark && showBookmark ? Self.button : 0) + (visible.downloads && showDownloads ? Self.button : 0)
            + (showOptional ? CGFloat(optional) * Self.button : 0) + 10
    }

    private static let minimumField: CGFloat = 220

    func requiredWindow(leadingInset: CGFloat) -> CGFloat {
        2 * max(leadingWidth(inset: leadingInset), trailingWidth) + 24 + Self.minimumField
    }

    /// Wide enough to be comfortable, never wide enough to touch the controls on either side.
    func fieldWidth(window: CGFloat, leadingInset: CGFloat) -> CGFloat {
        let free = window - 2 * max(leadingWidth(inset: leadingInset), trailingWidth) - 24
        return max(160, min(640, min(window * 0.5, free)))
    }
}
