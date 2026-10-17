import SwiftUI

/// Which optional buttons fit. Lower-priority actions move into the More menu as the window narrows.
struct ToolbarPriority: Equatable {
    var showBookmark: Bool, showDownloads: Bool, showOptional: Bool, showForward: Bool
    /// How many of the buttons the person added (workspaces, split view…) sit with the optional ones; they leave with them when the window is narrow.
    var extras = 0

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
    init(fitting window: CGFloat, leadingInset: CGFloat, extras: Int = 0) {
        let candidates = [ToolbarPriority(width: 1000), ToolbarPriority(width: 700), ToolbarPriority(width: 600),
                          ToolbarPriority(width: 450), ToolbarPriority(width: 300)].map { candidate -> ToolbarPriority in var c = candidate; c.extras = extras; return c }
        self = candidates.first { window >= $0.requiredWindow(leadingInset: leadingInset) } ?? candidates[candidates.count - 1]
    }

    func leadingWidth(inset: CGFloat) -> CGFloat {
        inset + Self.button + 2 + (4 + Self.button + (showForward ? Self.button : 0)) + 8
    }

    var trailingWidth: CGFloat {
        4 + Self.button + (showBookmark ? Self.button : 0) + (showDownloads ? Self.button : 0) + (showOptional ? CGFloat(3 + extras) * Self.button : 0) + 10
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
