import SwiftUI
import UniformTypeIdentifiers

/// The sections of the Library sidebar (Classic, Minimal, One Row). Each one is a view of data the app already keeps: bookmarks and history in the profile's database, the Reading List and the saved
/// sessions in the model. The Library owns none of it.
enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks = "Bookmarks", history = "History", readingList = "Reading List", sessions = "Sessions"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .bookmarks: "book"; case .history: "clock"; case .readingList: "eyeglasses"; case .sessions: "rectangle.stack" }
    }
}

/// A bar along the foot of a Library section, the same look in each: a hairline and a row of actions.
private struct LibraryFootBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 6) { content() }.padding(.horizontal, 12).frame(height: 38)
        }
    }
}

private func secondClickOfADoubleClick() -> Bool {
    if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown, event.clickCount >= 2 { return true }
    return false
}

/// The Reading List in the Library: the same items, search and commands as the Reading List sheet (unread dot, offline copy, remove), listed compactly.
struct LibraryReadingList: View {
    var accessory: AnyView?
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""

    var body: some View {
        let items = model.searchReading(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in row(item) }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        // On the list only: an identifier on the whole section would hide the identifiers of the buttons in its foot bar.
        .accessibilityIdentifier("library-reading-list")
        .overlay {
            if model.readingList.isEmpty { ContentUnavailableView("Nothing Saved Yet", systemImage: "books.vertical") }
            else if items.isEmpty { ContentUnavailableView("No Results", systemImage: "magnifyingglass") }
        }
        .embeddedSearch(embedded: true, text: $query, prompt: "Search Reading List", accessory: accessory)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryFootBar {
                Button { Task { await model.addToReadingList() } } label: {
                    Label("Add This Page", systemImage: "plus").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).disabled(model.active?.isBlank ?? true).help("Save the page in front to the Reading List").accessibilityIdentifier("library-reading-add")
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ item: ReadingItem) -> some View {
        Button {
            if secondClickOfADoubleClick() { return }
            model.openReadingItem(item)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(item.read ? Color.clear : Theme.accent).frame(width: 7, height: 7).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: item.read ? .regular : .semibold)).lineLimit(1)
                    Text("\(item.site) · \(item.added.formatted(.relative(presentation: .named)))" + (item.hasOfflineCopy ? " · offline" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.url)
        .accessibilityLabel("\(item.title), \(item.read ? "read" : "unread")")
        .contextMenu {
            Button(item.read ? "Mark as Unread" : "Mark as Read") { model.toggleRead(item) }
            if item.hasOfflineCopy { Button("Open the Website") { model.openReadingItem(item, online: true) } }
            Divider()
            Button("Remove", role: .destructive) { model.removeReadingItem(item) }
        }
    }
}

/// The saved sessions in the Library: name, number of tabs and date, from the saved records. Opening one adds its tabs to this window (it replaces nothing); deleting one asks first.
struct LibrarySessions: View {
    var accessory: AnyView?
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        let list = query.isEmpty ? model.savedSessions : model.savedSessions.filter { $0.name.localizedCaseInsensitiveContains(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(list) { session in row(session) }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .accessibilityIdentifier("library-sessions")
        .overlay {
            if model.savedSessions.isEmpty { ContentUnavailableView("No Saved Sessions", systemImage: "tray") }
            else if list.isEmpty { ContentUnavailableView("No Results", systemImage: "magnifyingglass") }
        }
        .embeddedSearch(embedded: true, text: $query, prompt: "Search Sessions", accessory: accessory)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryFootBar {
                Button { saveCurrent() } label: {
                    Label("Save These Tabs", systemImage: "plus").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).disabled(model.tabs.allSatisfy { $0.isBlank || $0.isPrivate })
                .help("Save the open tabs of this workspace as a session (private tabs are never saved)").accessibilityIdentifier("library-session-save")
                Spacer(minLength: 0)
                Menu {
                    Button("Export Sessions…") { exporting = true }.disabled(model.savedSessions.isEmpty)
                    Button("Import Sessions…") { importing = true }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 28, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More session actions")
            }
        }
        .fileExporter(isPresented: $exporting, document: SessionsDocument(sessions: model.savedSessions), contentType: .json, defaultFilename: "Browser Setu Sessions") { result in
            if case .success = result { model.notice = "Sessions exported." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { model.notice = "That file could not be read."; return }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let sessions = try? decoder.decode([SavedSession].self, from: data) else { model.notice = "That is not a Browser Setu sessions file."; return }
            let added = model.importSessions(sessions)
            model.notice = added == 0 ? "No new sessions in that file." : "Imported \(added) session\(added == 1 ? "" : "s")."
        }
    }

    private func saveCurrent() {
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "Save Session", message: "Name this set of tabs.", placeholder: "Research, Trip, Work…", prefill: false),
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.saveSession(named: name) }
        }
    }

    private func row(_ session: SavedSession) -> some View {
        Button {
            if secondClickOfADoubleClick() { return }
            model.openSession(session)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s") · \(session.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens its tabs in this window, beside the tabs you have")
        .accessibilityLabel("\(session.name), \(session.tabs.count) tabs")
        .contextMenu {
            Button("Open") { model.openSession(session) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete(session) }
        }
    }

    private func confirmDelete(_ session: SavedSession) {
        Task { @MainActor in
            let choice = await Dialogs.choose(title: "Delete the session “\(session.name)”?", message: "The saved list of \(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s") is removed. Pages you have open stay open.", buttons: ["Delete", "Cancel"])
            if choice == 0 { model.deleteSession(session) }
        }
    }
}
