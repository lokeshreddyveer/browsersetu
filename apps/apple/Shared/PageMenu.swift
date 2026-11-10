import SwiftUI

/// The extra choices Browser Setu adds to the page's right-click menu, beyond WebKit's own and the link choices.
enum PageMenuAction {
    case searchSelection, researchSelection, translateSelection
    case copyCleanLink
    case openImageInTab
    case playerControls, pictureInPicture
    case screenshot, fullPageScreenshot, pagePDF, reader, readingList, backToTop
    case autoScroll, editPageText
    case repositoryFiles
    case findMedia, collectImages, linkGrabber, exploreSite
}

/// Scripts for the two page tools that live in the page itself. Both are their own switch: running one again turns it off, so nothing has to be remembered here.
enum PageToolScripts {
    /// Scrolls the page down smoothly at `speed` points a second, and stops at the foot of the page, when the person scrolls, clicks or types, or when the page is hidden
    /// (animation frames do not run in a hidden page). Running it again while it is going stops it.
    static let autoScroll = """
    if (window.__bsAuto) { window.__bsAuto.stop(); return 'off'; }
    let last = null, owed = 0, frame = 0, going = true;
    const events = ['wheel', 'touchstart', 'keydown', 'mousedown'];
    function stop() {
        going = false; cancelAnimationFrame(frame);
        events.forEach(function (e) { window.removeEventListener(e, stop, true); });
        window.__bsAuto = null;
    }
    function step(now) {
        if (!going) return;
        if (last === null) last = now;
        owed += Math.max(0, speed) * Math.min((now - last) / 1000, 0.25); last = now;
        const whole = Math.floor(owed);
        if (whole >= 1) { window.scrollBy(0, whole); owed -= whole; }
        const el = document.scrollingElement || document.documentElement;
        if (window.innerHeight + window.scrollY >= el.scrollHeight - 1) { stop(); return; }
        frame = requestAnimationFrame(step);
    }
    events.forEach(function (e) { window.addEventListener(e, stop, { capture: true, passive: true }); });
    window.__bsAuto = { stop: stop };
    frame = requestAnimationFrame(step);
    return 'on';
    """

    /// Lets the person click into the page and change its words (to tidy a screenshot, or to try a wording). Nothing is saved to the site; reloading undoes it.
    static let editText = """
    const on = document.designMode !== 'on';
    document.designMode = on ? 'on' : 'off';
    return on ? 'on' : 'off';
    """
}

/// What was under the pointer when the menu was opened, asked of the page when a choice is made (the menu itself cannot say).
struct PageMenuTarget {
    var link: URL?
    var image: URL?
    var selection: String?

    /// The page's answer to "what is at this point": a dictionary of optional strings. Anything that is not a web address is dropped.
    init(_ answer: [String: Any]?) {
        func web(_ key: String) -> URL? {
            guard let text = answer?[key] as? String, let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else { return nil }
            return url
        }
        link = web("link")
        image = web("image")
        let selected = (answer?["selection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selection = selected.isEmpty ? nil : String(selected.prefix(2000))
    }

    init() {}
}

/// Which choices belong in the menu, for what the system's own menu shows (its items carry fixed identifiers).
enum PageMenuChoices {
    /// A choice, or (with `children`) a submenu that groups several.
    struct Choice: Equatable { var title: String; var symbol: String; var action: PageMenuAction?; var children: [Choice] = [] }

    /// `ids` are the identifiers of WebKit's own menu items. A menu has at most four or five of ours, so it stays short.
    static func choices(for ids: [String], repositoryPage: Bool = false, downloadTools: Bool = false) -> [Choice] {
        func has(_ part: String) -> Bool { ids.contains { $0.contains(part) } }
        let selection = has("SearchWeb") || has("LookUp") || has("Translate")
        let link = has("OpenLink") || has("CopyLink")
        let image = has("CopyImage") || has("DownloadImage") || has("OpenImageInNewWindow")
        let media = has("MediaPlayPause") || has("CopyMediaLink") || has("ToggleMediaControls")
        let page = has("GoBack") || has("Reload")
        var result: [Choice] = []
        if selection {
            result.append(Choice(title: "Search the Web for Selection", symbol: "magnifyingglass", action: .searchSelection))
            result.append(Choice(title: "Save Selection to Research", symbol: "books.vertical", action: .researchSelection))
            result.append(Choice(title: "Translate Selection", symbol: "character.bubble", action: .translateSelection))
        }
        if link { result.append(Choice(title: "Copy Link Without Tracking", symbol: "link", action: .copyCleanLink)) }
        if image {
            result.append(Choice(title: "Open Image in New Tab", symbol: "photo", action: .openImageInTab))
            if downloadTools { result.append(Choice(title: "Collect All Images on This Page", symbol: "square.stack.3d.down.right", action: .collectImages)) }
        }
        if media {
            result.append(Choice(title: "Player Controls…", symbol: "play.rectangle", action: .playerControls))
            result.append(Choice(title: "Picture in Picture", symbol: "pip.enter", action: .pictureInPicture))
        }
        // The page itself: only when nothing more specific was clicked.
        if page && !selection && !link && !image && !media {
            if repositoryPage { result.append(Choice(title: "Download Files from This Page…", symbol: "shippingbox", action: .repositoryFiles)) }
            if downloadTools {
                result.append(Choice(title: "Download from This Page", symbol: "arrow.down.circle", action: nil, children: [
                    Choice(title: "Find Media…", symbol: "play.rectangle.on.rectangle", action: .findMedia),
                    Choice(title: "Collect Images", symbol: "photo.on.rectangle", action: .collectImages),
                    Choice(title: "LinkGrabber…", symbol: "link.badge.plus", action: .linkGrabber),
                    Choice(title: "Explore This Website…", symbol: "globe", action: .exploreSite),
                ]))
            }
            result.append(Choice(title: "Screenshot and Edit…", symbol: "camera.viewfinder", action: .screenshot))
            result.append(Choice(title: "Auto Scroll", symbol: "arrow.down.to.line", action: .autoScroll))
            result.append(Choice(title: "Back to Top", symbol: "arrow.up.to.line", action: .backToTop))
            result.append(Choice(title: "More Page Tools", symbol: "ellipsis.circle", action: nil, children: [
                Choice(title: "Full-Page Screenshot and Edit…", symbol: "rectangle.expand.vertical", action: .fullPageScreenshot),
                Choice(title: "Save Page as PDF and Mark Up…", symbol: "doc.richtext", action: .pagePDF),
                Choice(title: "Edit Text on the Page", symbol: "pencil.line", action: .editPageText),
                Choice(title: "Reader View", symbol: "doc.plaintext", action: .reader),
                Choice(title: "Add to Reading List", symbol: "book", action: .readingList),
            ]))
        }
        return result
    }
}

@MainActor
extension BrowserModel {
    /// A choice from the page's right-click menu, in the tab it was made in.
    func pageMenu(_ action: PageMenuAction, target: PageMenuTarget, in tab: TabController) {
        switch action {
        case .searchSelection:
            guard let text = target.selection, let url = searchURL(for: String(text.prefix(300))) else { return }
            _ = openTab(url: url, isPrivate: tab.isPrivate, opener: tab, container: tabMeta[tab.id]?.container)
        case .researchSelection: Task { await addSelectionToResearch() }
        case .translateSelection: Task { await translateSelection() }
        case .copyCleanLink:
            guard let link = target.link else { return }
            let cleaned = TrackingParameters.clean(link) ?? link
            copyToPasteboard(cleaned.absoluteString)
            notice = cleaned != link ? "Copied the link without tracking parameters." : "Copied the link."
        case .openImageInTab:
            guard let image = target.image else { return }
            _ = openTab(url: image, isPrivate: tab.isPrivate, opener: tab, container: tabMeta[tab.id]?.container)
        case .playerControls: sheet = .pageTools
        case .pictureInPicture: togglePictureInPicture()
        case .screenshot: Task { await startScreenshot(fullPage: false) }
        case .fullPageScreenshot: Task { await startScreenshot(fullPage: true) }
        case .pagePDF: Task { await annotatePageScreenshot() }
        case .autoScroll: toggleAutoScroll()
        case .editPageText: tab.engine.runPageScript(PageToolScripts.editText, arguments: [:])
        case .reader: Task { await tab.toggleReader() }
        case .readingList: Task { await addToReadingList() }
        case .backToTop: tab.engine.scrollToEdge(bottom: false)
        case .findMedia: discoverMediaOnCurrentPage(in: tab)
        case .collectImages: Task { await collectImagesFromCurrentPage(in: tab) }
        case .linkGrabber: openLinkGrabber()
        case .exploreSite: exploreCurrentSite(in: tab)
        case .repositoryFiles: openProviders(address: tab.url?.absoluteString, fromPrivate: tab.isPrivate)
        }
    }
}

@MainActor
extension BrowserModel {
    /// Starts the page scrolling down at the speed chosen in Settings, or stops it if it is already going.
    func toggleAutoScroll() {
        active?.engine.runPageScript(PageToolScripts.autoScroll, arguments: ["speed": autoScrollSpeed])
    }
}

#if os(macOS)
/// The small pill on the Mac: an arrow and "Top", at the left of the page, for a few seconds after the page has been moved back toward the top.
struct MacBackToTopPill: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button { model.goBackToTop() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                Text("Top").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to top")
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}
#endif

/// Settings for what this file adds.
struct PageExtrasSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Page Menu and Back to Top") {
            Toggle("Extra choices in the page's right-click menu", isOn: $model.pageMenuExtras)
            Text("Search the web for a selection, save it to Research, copy a link without tracking, open the player, take a screenshot. Nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Auto scroll speed", value: "\(Int(model.autoScrollSpeed)) points a second")
                Slider(value: $model.autoScrollSpeed, in: 20...400, step: 10)
                    .accessibilityLabel("Auto scroll speed")
            }
            Text("Start it from the page's right-click menu or the Tools menu. It stops at the foot of the page, and as soon as you scroll, click or type.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Back-to-top button", isOn: $model.backToTopPill)
            Text("A small button that appears for a few seconds after you scroll back up a long page.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
