import SwiftUI

/// A workspace organises tabs. It is not a profile: profiles isolate browsing data, workspaces never do.
struct Workspace: Codable, Identifiable, Equatable {
    var name: String
    var icon: String
    /// Optional layout preset raw value applied when switching to this workspace.
    var preset: String?
    /// Optional accent colour (an `AccentChoice` raw value) used while this workspace is open.
    var accent: String? = nil
    /// The window arrangement last used in this workspace, restored when it is opened again.
    var layout: LayoutSnapshot? = nil
    var id: String { name }

    static let iconChoices = ["person", "briefcase", "hammer", "book", "gamecontroller", "cart", "airplane", "heart", "star", "leaf", "music.note", "graduationcap"]
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case teal, blue, purple, green, orange, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .teal: Color(red: 0.05, green: 0.50, blue: 0.60)
        case .blue: Color(red: 0.25, green: 0.45, blue: 0.80)
        case .purple: Color(red: 0.52, green: 0.38, blue: 0.82)
        case .green: Color(red: 0.25, green: 0.60, blue: 0.40)
        case .orange: Color(red: 0.85, green: 0.48, blue: 0.20)
        case .graphite: Color(red: 0.42, green: 0.45, blue: 0.50)
        }
    }
}

enum StartBackground: String, CaseIterable, Identifiable {
    case gradient, plain
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SplitOrientation: String, CaseIterable, Identifiable {
    case sideBySide, stacked
    var id: String { rawValue }
}

/// Resident memory of this process in bytes (what Activity Monitor calls "Memory").
func currentMemoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

// MARK: - Accessibility-aware helpers

/// Replaces translucent materials with a solid surface when Reduce Transparency is on.
struct SurfaceBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.platformBackground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// `withAnimation`, except when the person has asked the system to reduce motion: then the change happens at once.
@discardableResult
func animated<R>(_ animation: Animation = .easeOut(duration: 0.2), _ body: () throws -> R) rethrows -> R {
    #if os(macOS)
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #else
    let reduce = UIAccessibility.isReduceMotionEnabled
    #endif
    return reduce ? try body() : try withAnimation(animation, body)
}

extension View {
    func surface(radius: CGFloat = Theme.cardRadius) -> some View { modifier(SurfaceBackground(radius: radius)) }
    func motion<V: Equatable>(_ animation: Animation = .easeOut(duration: 0.15), value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

// MARK: - Spacing and radius tokens

enum BrowserSpacing {
    static let xxs: CGFloat = 4, xs: CGFloat = 6, sm: CGFloat = 8, md: CGFloat = 12
    static let lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
}

enum BrowserRadius {
    static let small: CGFloat = 6, medium: CGFloat = 10, large: CGFloat = 14, panel: CGFloat = 18
}
