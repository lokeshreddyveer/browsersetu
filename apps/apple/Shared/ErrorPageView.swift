import SwiftUI

// The page a failed load shows: native SwiftUI laid over the page area (never HTML loaded into the web view, which would run in the failed site's own origin). One shared layout,
// a small illustration of its own for each kind of trouble, and only the recovery actions that make sense for that trouble.

extension BrowserErrorKind {
    /// A colour that says what sort of trouble it is: cool for the network, warm for slow or broken sites, red for security, green-blue for protection.
    var accent: Color {
        switch self {
        case .noInternet: Color(red: 0.36, green: 0.52, blue: 0.80)
        case .dnsFailure: Color(red: 0.45, green: 0.42, blue: 0.85)
        case .timedOut: Color(red: 0.93, green: 0.58, blue: 0.20)
        case .serverUnavailable: Color(red: 0.86, green: 0.62, blue: 0.16)
        case .pageMissing: Color(red: 0.25, green: 0.62, blue: 0.62)
        case .certificate: Color(red: 0.84, green: 0.27, blue: 0.27)
        case .protectionBlocked: Color(red: 0.20, green: 0.62, blue: 0.48)
        case .unsupportedContent: Color(red: 0.62, green: 0.40, blue: 0.80)
        case .processCrashed: Color(red: 0.62, green: 0.45, blue: 0.45)
        case .fileFailure: Color(red: 0.88, green: 0.50, blue: 0.28)
        case .syncFailure: Color(red: 0.28, green: 0.55, blue: 0.88)
        case .mediaFailure: Color(red: 0.84, green: 0.34, blue: 0.56)
        }
    }
}

struct ErrorPageView: View {
    let info: BrowserErrorInfo
    var canGoBack = false
    var isPublicWeb = false
    /// A contained panel inside a healthy page or screen (a failed video, a file that would not open, a sync problem) rather than a whole page.
    var embedded = false
    let perform: (BrowserErrorAction) -> Void

    @State private var showDetails = false
    @State private var playing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { info.kind.accent }
    private var animated: Bool { !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        GeometryReader { geo in
            // A page that fits is centred in the space; one that is taller (a narrow panel, a small window, the games open) scrolls. The scroll view is only there when it
            // is needed, which also lets the page be drawn without one (a picture of it, for checking).
            ViewThatFits(in: .vertical) {
                pageContent.frame(maxWidth: .infinity, minHeight: geo.size.height)
                ScrollView { pageContent.frame(maxWidth: .infinity) }
            }
        }
        .background { if !embedded { background } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-page-\(info.kind.rawValue)")
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["BS_ERROR_PLAY"] == "1", info.offersGames { playing = true } }
        #endif
    }

    private var pageContent: some View {
        VStack(spacing: embedded ? 12 : 18) {
            ErrorIllustration(kind: info.kind, accent: accent, animated: animated)
                .frame(width: embedded ? 72 : 96, height: embedded ? 72 : 96)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(info.headline ?? info.kind.title)
                    .font(.system(size: embedded ? 17 : 24, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(info.message)
                    .font(.system(size: embedded ? 13 : 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
            if info.offersGames {
                gamesSection
            }
            details
        }
        .frame(maxWidth: 460)
        .padding(embedded ? 16 : 28)
    }

    private var background: some View {
        ZStack {
            Color.platformBackground
            // A faint wash of the error's own colour at the top: enough to tell the kinds apart at a glance, never enough to compete with the words.
            RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear], center: .init(x: 0.5, y: 0.18), startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }

    // MARK: Actions

    private var actions: [BrowserErrorAction] {
        var list = info.actions(canGoBack: canGoBack, isPublicWeb: isPublicWeb)
        if info.offersGames { list.append(.playOffline) }
        return list
    }

    /// The main action on its own, large; the others in a row beneath it (or stacked, when the space is narrow).
    private var actionRow: some View {
        let list = actions
        let rest = Array(list.dropFirst())
        return VStack(spacing: 10) {
            if let first = list.first { actionButton(first, primary: true) }
            if !rest.isEmpty {
                FlowRow(spacing: 8) { ForEach(rest) { actionButton($0, primary: false) } }
                    .frame(maxWidth: 520)
            }
        }
    }

    @ViewBuilder private func actionButton(_ action: BrowserErrorAction, primary: Bool) -> some View {
        if primary {
            Button { run(action) } label: { Label(action.title, systemImage: action.symbol).frame(minWidth: 96) }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(embedded ? .regular : .large)
                // Return does the main thing (try again, go back, reload), unless a text field has the keyboard.
                .keyboardShortcut(embedded ? nil : .defaultAction)
                .accessibilityIdentifier("error-action-\(action.rawValue)")
        } else {
            Button { run(action) } label: { Label(action.title, systemImage: action.symbol) }
                .buttonStyle(.bordered).controlSize(.regular)
                .accessibilityIdentifier("error-action-\(action.rawValue)")
        }
    }

    private func run(_ action: BrowserErrorAction) {
        if action == .playOffline { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { playing.toggle() } } else { perform(action) }
    }

    @ViewBuilder private var gamesSection: some View {
        if playing {
            VStack(spacing: 8) {
                OfflineGamesView(accent: accent)
                Text("These run on this device and use no network.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

    // MARK: Technical details

    private var details: some View {
        VStack(spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showDetails.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("Technical Details")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showDetails ? 180 : 0))
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showDetails ? "expanded" : "collapsed")
            .accessibilityHint("Shows the error code and the address")
            if showDetails {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(info.technicalLines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 420)
        .accessibilityIdentifier("error-details")
    }
}

// MARK: - Illustrations

/// A small, plain picture for each kind of trouble. Where it moves it moves slowly and only a little, and it stands still with Reduce Motion or Low Power Mode.
struct ErrorIllustration: View {
    let kind: BrowserErrorKind
    let accent: Color
    var animated = true

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.12))
            art.frame(width: 60, height: 60)
        }
    }

    @ViewBuilder private var art: some View {
        switch kind {
        case .noInternet: WifiArcsArt(accent: accent, animated: animated)
        case .dnsFailure: GlobeArt(accent: accent)
        case .timedOut: ClockArt(accent: accent, animated: animated)
        case .serverUnavailable: ServerArt(accent: accent, animated: animated)
        case .pageMissing: badged("doc.text", badge: "questionmark")
        case .certificate: badged("lock.fill", badge: "exclamationmark.triangle.fill", badgeColor: .red)
        case .protectionBlocked: badged("shield.fill", badge: "hand.raised.fill", badgeColor: .white)
        case .unsupportedContent: badged("doc.text", badge: "exclamationmark.circle.fill")
        case .processCrashed: badged("macwindow", badge: "arrow.clockwise.circle.fill")
        case .fileFailure: badged("doc", badge: "xmark.circle.fill", badgeColor: .red)
        case .syncFailure: SyncArt(accent: accent)
        case .mediaFailure: badged("play.rectangle.fill", badge: "exclamationmark.triangle.fill", badgeColor: .orange)
        }
    }

    /// A large symbol with a small one at its corner.
    private func badged(_ symbol: String, badge: String, badgeColor: Color? = nil) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol).font(.system(size: 46, weight: .regular)).foregroundStyle(accent)
                .frame(width: 60, height: 60)
            Image(systemName: badge).font(.system(size: 20, weight: .semibold)).foregroundStyle(badgeColor ?? accent)
                .padding(2)
                .background(Circle().fill(Color.platformBackground))
                .offset(x: 6, y: 4)
        }
    }
}

/// No network: three arcs and a dot, with a slash across them. The arcs fade in and out one after another, once every two seconds.
private struct WifiArcsArt: View {
    let accent: Color
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = animated ? max(0, 1 - abs((t.truncatingRemainder(dividingBy: 2) * 1.5) - Double(i) * 0.5 - 0.5)) : 0.45
                    ArcShape(radius: 12 + CGFloat(i) * 9).stroke(accent.opacity(0.35 + 0.65 * min(phase, 1)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                Circle().fill(accent).frame(width: 7, height: 7).offset(y: 16)
                Capsule().fill(accent).frame(width: 4, height: 54).rotationEffect(.degrees(-45)).overlay(Capsule().stroke(Color.platformBackground, lineWidth: 2).rotationEffect(.degrees(-45)))
            }
            .offset(y: -6)
        }
    }

    private struct ArcShape: Shape {
        let radius: CGFloat
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY + 16), radius: radius, startAngle: .degrees(225), endAngle: .degrees(315), clockwise: false)
            return path
        }
    }
}

/// Name not found: a globe with a small node that is not joined to it.
private struct GlobeArt: View {
    let accent: Color
    var body: some View {
        ZStack {
            Image(systemName: "globe").font(.system(size: 42)).foregroundStyle(accent).offset(x: -4, y: -2)
            Circle().strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: 14, height: 14).offset(x: 22, y: 20)
            Path { p in p.move(to: CGPoint(x: 16, y: 16)); p.addLine(to: CGPoint(x: 24, y: 24)) }
                .stroke(accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4]))
                .frame(width: 60, height: 60)
        }
    }
}

/// Timed out: a clock whose minute hand turns once in twelve seconds.
private struct ClockArt: View {
    let accent: Color
    let animated: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Circle().strokeBorder(accent, lineWidth: 4)
                Capsule().fill(accent).frame(width: 3, height: 13).offset(y: -6.5).rotationEffect(.degrees(-35))
                Capsule().fill(accent).frame(width: 3, height: 19).offset(y: -9.5).rotationEffect(.degrees(t * 30))
                Circle().fill(accent).frame(width: 6, height: 6)
            }
            .frame(width: 46, height: 46)
        }
    }
}

/// The site isn't answering: a small rack of servers, one light slowly pulsing amber.
private struct ServerArt: View {
    let accent: Color
    let animated: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !animated)) { context in
            let pulse = animated ? 0.45 + 0.55 * abs(sin(context.date.timeIntervalSinceReferenceDate * 1.4)) : 0.8
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle().fill(i == 1 ? Color.orange.opacity(pulse) : accent.opacity(0.35)).frame(width: 6, height: 6)
                        Capsule().fill(accent.opacity(0.25)).frame(height: 3)
                    }
                    .padding(.horizontal, 8).frame(width: 46, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(accent, lineWidth: 2))
                }
            }
        }
    }
}

/// Sync: two devices with a broken, dashed line between them.
private struct SyncArt: View {
    let accent: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "laptopcomputer").font(.system(size: 24)).foregroundStyle(accent)
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
            Image(systemName: "iphone").font(.system(size: 24)).foregroundStyle(accent)
        }
    }
}


/// The same message as a small panel inside a page or screen that is otherwise working: a video that will not play, a file that will not open, a sync that did not finish.
/// Nothing around it is replaced.
struct ErrorInlineView: View {
    let info: BrowserErrorInfo
    var actions: [BrowserErrorAction] = []
    let perform: (BrowserErrorAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ErrorIllustration(kind: info.kind, accent: info.kind.accent, animated: false)
                .frame(width: 96, height: 96).scaleEffect(0.46).frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.headline ?? info.kind.title).font(.system(size: 13, weight: .semibold))
                Text(info.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(actions) { action in
                            Button { perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("error-inline-\(action.rawValue)")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(info.kind.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(info.kind.accent.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-inline-\(info.kind.rawValue)")
    }
}


/// Lays its children out left to right, starting a new centred line when one does not fit: a row of buttons that wraps instead of becoming one tall column.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func lines(for width: CGFloat, _ subviews: Subviews) -> [Line] {
        var lines = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let last = lines[lines.count - 1]
            if !last.indices.isEmpty, last.width + spacing + size.width > width { lines.append(Line()) }
            var line = lines.removeLast()
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines.append(line)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(for: width, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }
}
