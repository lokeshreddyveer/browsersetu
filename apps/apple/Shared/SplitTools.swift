import Foundation
import SwiftUI

/// What two pages have and do not have in common, by their lines of text.
struct PageComparison: Equatable {
    var leftTitle: String
    var rightTitle: String
    var onlyLeft: [String]
    var onlyRight: [String]
    var shared: Int

    /// 0 to 1: shared lines out of all lines on either page.
    var similarity: Double {
        let total = shared + onlyLeft.count + onlyRight.count
        return total == 0 ? 1 : Double(shared) / Double(total)
    }
}

enum PageDiff {
    /// Meaningful lines of a page's text: trimmed, at least four characters, each once.
    static func lines(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.count >= 4, seen.insert(line).inserted { out.append(line) }
        }
        return out
    }

    static func compare(leftTitle: String, left: String, rightTitle: String, right: String) -> PageComparison {
        let a = lines(left), b = lines(right)
        let setA = Set(a), setB = Set(b)
        return PageComparison(leftTitle: leftTitle, rightTitle: rightTitle, onlyLeft: a.filter { !setB.contains($0) }, onlyRight: b.filter { !setA.contains($0) }, shared: setA.intersection(setB).count)
    }
}

@MainActor
extension BrowserModel {
    // MARK: Linked scrolling

    /// While on, scrolling one panel scrolls the others to the same place down the page. Pages of different lengths line up by proportion.
    func setLinkedPanes(_ on: Bool) {
        linkedPanes = on
        linkTask?.cancel()
        guard on else { return }
        linkTask = Task { @MainActor [weak self] in
            var last: [UInt64: Double] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.linkedPanes else { return }
                let panels = self.splitPanels
                guard panels.count > 1 else { last = [:]; continue }
                var now: [UInt64: Double] = [:]
                for p in panels { if let f = await p.engine.scrollFraction() { now[p.id] = f } }
                let moved = panels.filter { p in
                    guard let a = now[p.id], let b = last[p.id] else { return false }
                    return abs(a - b) > 0.004
                }
                // Exactly one panel moving is the one being scrolled; the rest follow it.
                if moved.count == 1, let driver = moved.first, let f = now[driver.id] {
                    for p in panels where p.id != driver.id {
                        await p.engine.setScrollFraction(f)
                        now[p.id] = await p.engine.scrollFraction() ?? f
                    }
                }
                last = now
            }
        }
    }

    // MARK: Links and layouts

    /// Loads the link in the next panel (the other one, with two). With no split open, a new panel opens beside the page.
    func openInOtherPane(_ url: URL, from tab: TabController) {
        let panels = splitPanels
        if panels.count > 1, let i = panels.firstIndex(where: { $0.id == tab.id }) {
            panels[(i + 1) % panels.count].load(url)
        } else {
            let fresh = openTab(url: url, isPrivate: tab.isPrivate, select: false, opener: tab)
            if splitTabID == nil { openSplit(with: fresh) } else { addThirdPanel(with: fresh) }
        }
    }

    /// Kept when a split closes, so "Reopen Last Split" can bring the same two pages back.
    func rememberSplit() {
        guard let left = active, !left.isPrivate, let leftURL = left.url, let right = splitTab, let rightURL = right.url else { return }
        let layout = SplitTemplate(name: "Last split", left: leftURL.absoluteString, right: rightURL.absoluteString, vertical: splitOrientation == .stacked)
        lastSplit = layout
        saveSetting("last_split", encodedMap(["list": [layout]]))
    }

    func reopenLastSplit() {
        guard let layout = lastSplit else { notice = "No split view has been closed yet."; return }
        openSplitTemplate(layout)
    }

    // MARK: Comparing

    /// Reads the text of the first two panels and shows what is the same and what differs.
    func comparePanels() async {
        let panels = orderedSplitPanels()
        guard panels.count > 1 else { notice = "Open two pages side by side first."; return }
        let left = await panels[0].engine.pageText() ?? "", right = await panels[1].engine.pageText() ?? ""
        guard !left.isEmpty || !right.isEmpty else { notice = "These pages have no text to compare."; return }
        comparison = PageDiff.compare(leftTitle: panels[0].displayTitle, left: left, rightTitle: panels[1].displayTitle, right: right)
        sheet = .compare
    }
}

struct ComparePagesView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if let c = model.comparison {
            List {
                Section {
                    LabeledContent("Alike", value: "\(Int((c.similarity * 100).rounded()))%")
                    LabeledContent("Lines in both", value: "\(c.shared)")
                } footer: { Text("Compared by lines of text, ignoring layout, pictures and the order of lines.") }
                Section("Only on “\(c.leftTitle)” (\(c.onlyLeft.count))") {
                    ForEach(Array(c.onlyLeft.prefix(200).enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(Color.red).textSelection(.enabled)
                    }
                }
                Section("Only on “\(c.rightTitle)” (\(c.onlyRight.count))") {
                    ForEach(Array(c.onlyRight.prefix(200).enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(Color.green).textSelection(.enabled)
                    }
                }
            }
        } else {
            ContentUnavailableView("Nothing to Compare", systemImage: "rectangle.split.2x1")
        }
    }
}
