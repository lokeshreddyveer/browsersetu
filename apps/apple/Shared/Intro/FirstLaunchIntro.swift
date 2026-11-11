import SwiftUI

// The first-launch film (GlobeFilm.swift). An exclusive root state: intro -> setup -> browser. While it plays nothing else is in the view tree (FirstLaunchGate), so no browser chrome can show through it and no browser UI is built beneath it.
// The film-engine work (Shared/Intro/Film, docs/intro-frame-spec.md, docs/intro-asset-contract.md) is kept for a future artwork-based film; it is not used by this one.

/// The setup screens' colours, sampled from the rendered dark setup assistant. Nothing else is used in the film.
enum IntroPalette {
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.059)          // #09090F
    static let deep = Color(red: 0.082, green: 0.086, blue: 0.102)         // #15161A  surface
    static let panel = Color(red: 0.106, green: 0.114, blue: 0.141)        // #1B1D24
    static let accent = Color(red: 0.224, green: 0.494, blue: 0.588)       // #397E96
    static let accentLight = Color(red: 0.561, green: 0.816, blue: 0.890)  // #8FD0E3  ice teal
    static let accentDark = Color(red: 0.122, green: 0.345, blue: 0.439)   // #1F5870  deep teal
    static let purple = Color(red: 0.278, green: 0.180, blue: 0.353)       // #472E5A
    static let tealGlow = Color(red: 0.180, green: 0.298, blue: 0.353)     // #2E4C5A  teal haze
    static let cream = Color(red: 0.875, green: 0.953, blue: 0.973)        // #DFF3F8  highlight
    static let secondary = Color(red: 0.549, green: 0.553, blue: 0.569)    // #8C8D91
}

/// Swaps the browser for the film on a brand-new install, and the film for the browser when it ends. Exclusive: only one of them is in the tree.
struct FirstLaunchGate<Content: View>: View {
    @EnvironmentObject var model: BrowserModel
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            if model.showIntro {
                FirstLaunchIntro { model.finishIntro() }.transition(.opacity)
            } else if model.showWhatsNew {
                WhatsNewView { model.finishWhatsNew() }.transition(.opacity)
            } else {
                content().transition(.opacity)
            }
        }
        .background(IntroPalette.ink)
        .animation(.easeInOut(duration: 0.7), value: model.showIntro)
        .animation(.easeInOut(duration: 0.7), value: model.showWhatsNew)
    }
}

struct FirstLaunchIntro: View {
    var onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false
    /// For review: BS_INTRO_AT=<seconds> freezes the film on that moment and never ends it.
    private let frozenAt: Double? = ProcessInfo.processInfo.environment["BS_INTRO_AT"].flatMap(Double.init)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let frozenAt {
                Canvas { ctx, size in GlobeFilm.draw(&ctx, size, frozenAt) }
            } else if reduceMotion {
                // Reduced motion: the finished picture, held briefly, then setup. No travelling arc, no storm.
                Canvas { ctx, size in GlobeFilm.draw(&ctx, size, GlobeFilm.duration - 0.2) }
            } else {
                TimelineView(.animation) { tl in
                    Canvas { ctx, size in GlobeFilm.draw(&ctx, size, tl.date.timeIntervalSince(start)) }
                }
            }
            if frozenAt == nil {
                Button(action: finish) {
                    Text("Skip").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 8).padding(.trailing, 14)
                .accessibilityLabel("Skip introduction")
            }
        }
        .background(IntroPalette.ink)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser Setu. A storm gathers over the world; an arc of light sweeps around it and the storm glides past; a dome of glass closes, and a browser window with a shield stays calm beneath it.")
        .task {
            guard frozenAt == nil else { return }
            start = Date()
            try? await Task.sleep(for: .seconds(reduceMotion ? 1.4 : GlobeFilm.duration))
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}
