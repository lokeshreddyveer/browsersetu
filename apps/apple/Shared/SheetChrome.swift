import SwiftUI

/// How every sheet is dismissed. On the Mac a sheet's toolbar puts a `.confirmationAction` button in a separate bar along the bottom, away from the title in the top bar, which looked like a stray
/// bar with a lone Done button. One control, in the top bar next to the title, with Escape as its shortcut; on iOS the usual confirmation place.
enum SheetChrome {
    static var dismissPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .confirmationAction
        #endif
    }

    static let doneIdentifier = "sheet-done"
}

extension View {
    /// The sheet's one Done button: Escape works as well as a click.
    func sheetDoneToolbar(_ label: String = "Done", action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: SheetChrome.dismissPlacement) {
                Button(label, action: action).keyboardShortcut(.cancelAction).accessibilityIdentifier(SheetChrome.doneIdentifier)
            }
        }
    }
}

// MARK: - The sheet's own Done

private struct SheetProvidesDoneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a sheet that already shows the standard Done in its top bar: an editor then leaves out a Done of its own (two buttons answering Escape).
    var sheetProvidesDone: Bool {
        get { self[SheetProvidesDoneKey.self] }
        set { self[SheetProvidesDoneKey.self] = newValue }
    }
}

// MARK: - Unsaved changes

/// What Done or Escape does on a sheet.
enum SheetDismissal {
    enum Outcome: Equatable { case close, askFirst }

    /// A sheet that holds nothing unsaved closes at once; one that does asks.
    static func outcome(isDirty: Bool) -> Outcome { isDirty ? .askFirst : .close }

    /// The choices offered: Save only where the editor has one direct save; Discard and Keep Editing always.
    static func choices(canSave: Bool) -> [String] { (canSave ? ["Save"] : []) + ["Discard Changes", "Keep Editing"] }
}

extension BrowserModel {
    /// Done or Escape on a sheet. A sheet that registered unsaved changes answers by itself (it asks, or closes); any other closes.
    func requestSheetDismiss() {
        if sheetGuardActive { sheetDismissRequest += 1 } else { sheet = nil }
    }
}

/// Makes an editor sheet ask before it throws away what was typed or drawn: Save (when the editor has a direct save; a failed save keeps the editor open and says why), Discard Changes, or
/// Keep Editing. With nothing unsaved it simply closes.
private struct UnsavedChangesGuard: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    let isDirty: Bool
    let save: (() -> String?)?
    @State private var asking = false
    @State private var saveProblem: String?

    func body(content: Content) -> some View {
        content
            .onAppear { model.sheetGuardActive = true }
            .onDisappear { model.sheetGuardActive = false }
            .onChange(of: model.sheetDismissRequest) { _, _ in
                switch SheetDismissal.outcome(isDirty: isDirty) {
                case .close: model.sheet = nil
                case .askFirst: asking = true
                }
            }
            .confirmationDialog("Close without saving?", isPresented: $asking, titleVisibility: .visible) {
                if let save {
                    Button("Save") { if let problem = save() { saveProblem = problem } else { model.sheet = nil } }.keyboardShortcut(.defaultAction)
                }
                Button("Discard Changes", role: .destructive) { model.sheet = nil }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("What you changed here has not been saved.")
            }
            .alert("Could not save", isPresented: Binding(get: { saveProblem != nil }, set: { if !$0 { saveProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text((saveProblem ?? "") + " The editor stays open so nothing is lost.")
            }
    }
}

extension View {
    /// `isDirty`: something typed or drawn would be lost. `save`: one direct save that returns nil on success or the reason it failed (omit it when saving needs more than one step).
    func guardsUnsavedChanges(isDirty: Bool, save: (() -> String?)? = nil) -> some View {
        modifier(UnsavedChangesGuard(isDirty: isDirty, save: save))
    }
}

#if os(macOS)
/// The top of a Mac sheet: its title on the left, the one Done on the right, a hairline under both. Escape is Done's shortcut.
struct SheetHeader: View {
    let title: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !title.isEmpty { Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1) }
                Spacer(minLength: 12)
                Button("Done", action: done).keyboardShortcut(.cancelAction).accessibilityIdentifier(SheetChrome.doneIdentifier)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
        }
        .background(Color.platformBackground)
        .accessibilityElement(children: .contain)
    }
}
#endif

extension View {
    /// Hides the floating Writing Tools button of a text editor (it sat half outside a sheet's edge and was cut off). The Writing Tools commands stay in the text's own context menu. Older systems have no such button.
    @ViewBuilder func quietWritingToolsButton() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) { writingToolsAffordanceVisibility(.hidden).writingToolsBehavior(.disabled) }
        else if #available(macOS 15.0, iOS 18.0, *) { writingToolsBehavior(.disabled) }
        else { self }
    }
}
