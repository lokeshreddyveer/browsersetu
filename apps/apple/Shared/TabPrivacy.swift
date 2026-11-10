import Foundation

/// What kind of tab this is, by who owns it and how long it lives. One place decides what each kind may keep, share or save, so no feature has to guess from
/// `isPrivate` alone. (Scratch and Glance tabs and guest windows are all "leave nothing behind" in the same way a private tab is, but they are not private tabs.)
enum TabContext: String, CaseIterable {
    case normal       // an ordinary tab of the profile
    case privateTab   // the person opened a private tab: its own session, nothing kept
    case guest        // a guest window: a temporary profile
    case scratch      // a scratch tab: disappears when closed
    case glance       // a quick preview over another page
}

/// Every thing a tab's content could be kept for, and the answer for each kind of tab. Add a new feature that stores, shares or indexes page content by adding a
/// capability here, so the decision is made (and tested) once.
struct TabPrivacy: Equatable {
    let context: TabContext

    /// Nothing about this tab's pages may be written anywhere that outlives it: history, page memory, zoom and icon lists, activity times, sessions.
    var keepsTraces: Bool { context == .normal }

    /// A sign-in typed here may be offered for saving, or an existing saved sign-in changed or forgotten.
    var canSaveLogins: Bool { keepsTraces }
    /// A page, passage or note from here may go into Research collections (which are saved, backed up and can be synced).
    var canSaveToResearch: Bool { keepsTraces }
    /// A copy made from here may enter the browser's clipboard history.
    var canRecordClipboard: Bool { keepsTraces }
    /// Time spent here may be counted in the activity log.
    var canRecordActivity: Bool { keepsTraces }
    /// The tab may be shared with, listed to, or driven by an automation or AI client.
    var canShareWithAutomation: Bool { keepsTraces }
    /// A style the person writes for this site is saved in settings (and synced), so it cannot be written from here.
    var canSaveSiteSettings: Bool { keepsTraces }
    /// Something about this page may be written to a file with no question asked. Even a normal tab asks before it saves a capture of a page; the others never do.
    var canWriteFilesWithoutAsking: Bool { keepsTraces }

    /// Why a capability is refused, in words for the person.
    var refusal: String {
        switch context {
        case .normal: ""
        case .privateTab: "Private tabs leave nothing behind, so this is not available there."
        case .guest: "A guest window leaves nothing behind, so this is not available there."
        case .scratch: "A scratch tab disappears when it closes, so this is not available there."
        case .glance: "A Glance preview leaves nothing behind, so this is not available there."
        }
    }
}

extension TabController {
    var privacy: TabPrivacy { TabPrivacy(context: context) }
}
