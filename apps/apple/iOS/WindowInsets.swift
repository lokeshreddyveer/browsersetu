import SwiftUI
import UIKit

/// The room the screen keeps for the status bar and the home indicator, kept up to date. Read once while the window is still being made it can be zero, and every layout that
/// used it was then drawn as if the screen had no such edges for as long as nothing else made it draw again. Now it is read again as soon as the window is there, when the app comes
/// to the front, and when the phone is turned, and whatever shows it is redrawn when it changes.
@MainActor
final class WindowInsets: ObservableObject {
    static let shared = WindowInsets()
    @Published private(set) var top: CGFloat = 0
    @Published private(set) var bottom: CGFloat = 0
    @Published private(set) var leading: CGFloat = 0
    @Published private(set) var trailing: CGFloat = 0

    private init() {
        // Not read here: asking the window for its insets can lay the screen out, which asks for this object again while it is still being made.
        for delay in [0.0, 0.1, 0.4, 1.0, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() } }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(350))
                self?.refresh()
            }
        }
    }

    func refresh() {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        let insets = window?.safeAreaInsets ?? .zero
        if insets.top != top { top = insets.top }
        if insets.bottom != bottom { bottom = insets.bottom }
        if insets.left != leading { leading = insets.left }
        if insets.right != trailing { trailing = insets.right }
    }
}
