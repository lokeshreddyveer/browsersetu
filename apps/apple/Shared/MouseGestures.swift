import Foundation

/// Mouse gestures: hold the middle button, drag a short path, and let go. "L" (left) goes back, "DR" (down, then right) closes the tab, and so on. The path is turned into letters
/// here, with no reference to a screen, so it can be tested.
enum MouseGesture {
    /// How far the pointer must move in one direction before it counts as a stroke, in points.
    static let minStep: CGFloat = 36
    static let maxStrokes = 4

    /// The strokes of a path as letters (L, R, U, D). Points have the y axis growing downward, as a screen does. Small wobble is ignored, and the same direction twice in a row is one stroke.
    static func strokes(of points: [CGPoint], minStep: CGFloat = minStep) -> String {
        guard var anchor = points.first else { return "" }
        var out: [Character] = []
        for p in points.dropFirst() {
            let dx = p.x - anchor.x, dy = p.y - anchor.y
            guard max(abs(dx), abs(dy)) >= minStep else { continue }
            let letter: Character = abs(dx) >= abs(dy) ? (dx < 0 ? "L" : "R") : (dy < 0 ? "U" : "D")
            if out.last != letter { out.append(letter) }
            anchor = p
            if out.count >= maxStrokes { break }
        }
        return String(out)
    }

    static let defaults: [String: VimAction] = [
        "L": .back, "R": .forward, "D": .newTab, "DR": .closeTab, "DL": .reopenTab, "U": .scrollTop, "UD": .reload, "UR": .nextTab, "UL": .previousTab, "RD": .scrollBottom,
    ]

    /// The map as saved text ("DR closeTab" per line). Anything that is not a known action or a sequence of 1 to 4 letters is dropped, and if nothing is left the defaults are used.
    static func decode(_ text: String?) -> [String: VimAction] {
        var out: [String: VimAction] = [:]
        for line in (text ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let action = VimAction(rawValue: String(parts[1])), (1...maxStrokes).contains(parts[0].count), parts[0].allSatisfy({ "LRUD".contains($0) }) else { continue }
            out[String(parts[0])] = action
        }
        return out.isEmpty ? defaults : out
    }

    static func encode(_ map: [String: VimAction]) -> String { map.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.rawValue)" }.joined(separator: "\n") }

    /// "←", "↓→": the letters as arrows, for showing.
    static func arrows(_ sequence: String) -> String {
        let names: [Character: String] = ["L": "←", "R": "→", "U": "↑", "D": "↓"]
        return sequence.compactMap { names[$0] }.joined()
    }

    /// What a map does for a path: the action, or nil when nothing is bound to it. A longer path that starts with a bound one is not the shorter one (the exact path is needed).
    static func action(for points: [CGPoint], in map: [String: VimAction]) -> (sequence: String, action: VimAction)? {
        let s = strokes(of: points)
        return map[s].map { (s, $0) }
    }
}

/// A press that turned out not to be a drag: the middle click (or press) goes on to the page as if nothing had been in the way.
enum MouseGestureOutcome: Equatable { case notAGesture, gesture(String) }

extension BrowserModel {
    /// Called while a gesture is being drawn and when it ends. While drawing, the action the strokes would do is shown; on release it is done.
    func mouseGestureProgress(_ sequence: String, finished: Bool) {
        let action = mouseGestureMap[sequence]
        if !finished {
            gestureHint = sequence.isEmpty ? nil : MouseGesture.arrows(sequence) + "  " + (action?.title ?? "no action")
            return
        }
        if let action { gestureHint = MouseGesture.arrows(sequence) + "  " + action.title; workbench.perform(action) }
        else { gestureHint = sequence.isEmpty ? nil : MouseGesture.arrows(sequence) + "  no action" }
        hintTask?.cancel()
        hintTask = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { gestureHint = nil } }
    }

    func setMouseGestureMap(_ map: [String: VimAction]) {
        mouseGestureMap = map.isEmpty ? MouseGesture.defaults : map
        saveSetting("mouse_gesture_map", MouseGesture.encode(mouseGestureMap))
    }
}
