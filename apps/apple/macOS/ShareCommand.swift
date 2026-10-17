import AppKit

extension BrowserModel {
    /// Opens the system share menu for the page in front: AirDrop to a nearby iPhone or Mac, Messages, Mail, Notes and the rest.
    func shareActivePage() {
        guard let tab = active, let url = tab.url, !tab.isBlank, let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        // Opens just under the middle of the top edge, where the page's controls are.
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 48, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}
