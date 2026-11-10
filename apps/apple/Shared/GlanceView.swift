import SwiftUI

/// Mounts the Glance preview when there is one. A separate view so the window redraws when the preview comes and goes (the coordinator is a nested object).
struct GlanceLayer: View {
    @ObservedObject var glance: GlanceCoordinator

    var body: some View {
        Group {
            if glance.session != nil, let tab = glance.tab {
                GlanceView(glance: glance, tab: tab)
                    .transition(.opacity)
                    .zIndex(8)
            }
        }
        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: glance.session)
    }
}

/// The preview of a link, as a peek: on an iPhone a sheet that rises from the bottom with a grab handle, on a Mac a card over the page it came from. Drag the header down (or tap
/// outside, or press Escape) to put it away; drag it up, or press Open, to make it a real tab. The header has the site, one clear Open button and a menu with the rest.
/// It follows the theme.
struct GlanceView: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var glance: GlanceCoordinator
    @ObservedObject var tab: TabController
    /// False until it has been drawn once, so it can come in; false again just before it goes, so it can leave.
    @State private var shown = false
    @GestureState private var drag: CGFloat = 0
    #if os(iOS)
    @ObservedObject private var icons = FaviconStore.shared
    #endif

    private var title: String { tab.displayTitle.isEmpty ? (tab.url?.host ?? "Preview") : tab.displayTitle }
    private var host: String { tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "" }

    var body: some View {
        GeometryReader { proxy in
            let phone = proxy.size.width < 600
            let height = phone ? proxy.size.height * 0.93 : proxy.size.height * 0.88
            ZStack(alignment: phone ? .bottom : .center) {
                // Behind the card the page it came from is dimmed, a little less as the card is pulled down.
                Color.black.opacity(shown ? 0.36 * (1 - Double(min(max(drag, 0) / 420, 1))) : 0)
                    .ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                card(phone: phone)
                    .frame(width: phone ? proxy.size.width : min(1000, proxy.size.width * 0.84), height: height)
                    .offset(y: shown ? (phone ? (drag > 0 ? drag : drag * 0.3) : 0) : (phone ? height + 40 : 0))
                    .scaleEffect(phone || shown ? 1 : 0.96)
                    .opacity(phone || shown ? 1 : 0)
                    .ignoresSafeArea(edges: phone ? .bottom : [])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: phone ? .bottom : .center)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(title)")
        .accessibilityAddTraits(.isModal)
        .onAppear {
            tick(.light)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { shown = true }
        }
        #if os(macOS)
        .onExitCommand { close() }
        #endif
    }

    private func card(phone: Bool) -> some View {
        VStack(spacing: 0) {
            header(phone: phone)
            ZStack(alignment: .top) {
                EngineViewHost(view: tab.hostView).tabErrorOverlay(tab, compact: true)
                if tab.isLoading { ProgressView(value: tab.progress).progressViewStyle(.linear).tint(Theme.accent).transition(.opacity) }
            }
        }
        .themedBar(fallback: .regularMaterial)
        .clipShape(phone ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous))
                         : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .overlay {
            (phone ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous))
                   : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))).stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 26, y: 8)
    }

    private func header(phone: Bool) -> some View {
        VStack(spacing: 0) {
            if phone { Capsule().fill(Color.primary.opacity(0.28)).frame(width: 38, height: 5).padding(.top, 8).padding(.bottom, 2).accessibilityHidden(true) }
            HStack(spacing: 8) {
                if tab.canGoBack {
                    Button { tab.goBack() } label: { Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 34).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Back")
                }
                site
                Spacer(minLength: 4)
                Button { expand() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .semibold))
                        Text("Open").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .foregroundStyle(Color.white)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel("Open as a tab")
                Menu {
                    Button(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") { tab.isLoading ? tab.stop() : tab.reload() }
                    if tab.canGoForward { Button("Forward", systemImage: "chevron.right") { tab.goForward() } }
                    if let url = tab.url {
                        Button("Copy Link", systemImage: "link") { copyToPasteboard(url.absoluteString); model.notice = "Link copied." }
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        if !tab.isPrivate { Button("Open in a Private Tab", systemImage: "eye.slash") { model.openTab(url: url, isPrivate: true); glance.dismiss() } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 17, weight: .regular)).frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More")
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).symbolRenderingMode(.hierarchical).frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 46)
        }
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        // Dragged down the sheet goes away, dragged up it becomes a tab. On the header only, so the page's own scrolling is never fought.
        .gesture(phone ? DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                if value.translation.height > 110 || value.predictedEndTranslation.height > 340 { close() }
                else if value.translation.height < -100 || value.predictedEndTranslation.height < -340 { expand() }
            } : nil)
    }

    private var site: some View {
        HStack(spacing: 8) {
            siteIcon
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: tab.isSecure ? "lock.fill" : "lock.open").font(.system(size: 9)).foregroundStyle(tab.isSecure ? Color.secondary : Color.orange)
                    Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if tab.isPrivate { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(Theme.privateAccent) }
                }
            }
        }
    }

    @ViewBuilder private var siteIcon: some View {
        #if os(iOS)
        if let url = tab.url, let image = icons.image(forURL: url.absoluteString, points: 22) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
        #else
        Image(systemName: "globe").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22, height: 22)
        #endif
    }

    /// Puts it away with a short slide, then ends the preview.
    private func close() {
        tick(.soft)
        withAnimation(.easeIn(duration: 0.2)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { glance.dismiss() }
    }

    private func expand() {
        tick(.medium)
        glance.promote()
    }

    private enum Tick { case soft, light, medium }
    private func tick(_ kind: Tick) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: kind == .soft ? .soft : (kind == .light ? .light : .medium)).impactOccurred()
        #endif
    }
}
