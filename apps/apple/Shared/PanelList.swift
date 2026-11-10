import SwiftUI

/// The list a panel's sections sit in. On the Mac a plain `List` drew sections as bare rows with separators that did not line up and captions cut short; a grouped form gives the cards, spacing and wrapping the
/// other panels have. Everywhere else it is the usual list.
struct PanelList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        Form { content() }.formStyle(.grouped)
        #else
        List { content() }
        #endif
    }
}

/// A text field for a panel: inside a grouped form its title would become a label on the left with an empty box beside it; this keeps the title as the placeholder.
struct FormTextField: View {
    private let title: String
    private let text: Binding<String>
    private let axis: Axis

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title; self.text = text; self.axis = axis
    }

    var body: some View {
        TextField(title, text: text, prompt: Text(title), axis: axis).labelsHidden()
    }
}
