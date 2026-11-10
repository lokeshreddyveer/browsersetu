import Foundation

// MARK: The files of a torrent as a tree (DX-05)
//
// Built once from the torrent's file list (stable indices, the torrent's own order). A folder's state is computed from its files, so choosing a folder chooses everything under it and the
// box shows mixed when only some are chosen. Nothing here is a view: the screens ask for the rows that are visible, which keeps a torrent of thousands of files cheap to show.

struct TorrentFileTree: Sendable {
    struct Node: Sendable {
        var name: String
        var path: [String]
        var children: [Int] = []          // positions in `nodes`, in the torrent's order
        var fileIndex: Int?                // nil for a folder
        var size: Int64 = 0
        var files: [Int] = []              // indices of the files at or under this node
    }

    enum State: Equatable, Sendable { case none, some, all }

    struct Row: Identifiable, Equatable, Sendable {
        var id: String
        var depth: Int
        var name: String
        var path: [String]
        var fileIndex: Int?
        var size: Int64
        var fileCount: Int
        var chosenCount: Int
        var isFolder: Bool { fileIndex == nil }
        var state: State { chosenCount == 0 ? .none : (chosenCount == fileCount ? .all : .some) }
    }

    private(set) var nodes: [Node] = []
    let fileCount: Int
    static let maxRows = 5000

    init(_ meta: TorrentMetainfo) {
        fileCount = meta.files.filter { !$0.isPadding }.count
        nodes = [Node(name: "", path: [])]
        var byPath: [String: Int] = ["": 0]
        for f in meta.files where !f.isPadding {
            var parent = 0
            for (depth, part) in f.path.enumerated() {
                let isFile = depth == f.path.count - 1
                let path = Array(f.path.prefix(depth + 1))
                // A file and a folder may share a name only in a damaged torrent; the key keeps them apart.
                let key = (isFile ? "f:" : "d:") + path.joined(separator: "\u{1}") + (isFile ? "#\(f.index)" : "")
                if let existing = byPath[key] { parent = existing }
                else {
                    nodes.append(Node(name: part, path: path, fileIndex: isFile ? f.index : nil))
                    let position = nodes.count - 1
                    byPath[key] = position
                    nodes[parent].children.append(position)
                    parent = position
                }
                nodes[parent].size += f.length
                nodes[parent].files.append(f.index)
            }
            nodes[0].size += f.length
            nodes[0].files.append(f.index)
        }
    }

    /// The rows that are shown: folders expanded as asked, or, when a search is typed, the matching files in a flat list (with their folders in the name).
    func rows(expanded: Set<String>, selection: TorrentSelection, filter: String, meta: TorrentMetainfo) -> [Row] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func chosen(_ files: [Int]) -> Int { files.reduce(0) { $0 + (selection.priority(of: $1) > .skip ? 1 : 0) } }
        if !query.isEmpty {
            var out: [Row] = []
            for f in meta.files where !f.isPadding && f.relativePath.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                out.append(Row(id: "f:\(f.index)", depth: 0, name: f.relativePath, path: f.path, fileIndex: f.index, size: f.length, fileCount: 1, chosenCount: selection.priority(of: f.index) > .skip ? 1 : 0))
                if out.count >= Self.maxRows { break }
            }
            return out
        }
        var out: [Row] = []
        func walk(_ position: Int, depth: Int) {
            for child in nodes[position].children {
                guard out.count < Self.maxRows else { return }
                let n = nodes[child]
                out.append(Row(id: n.fileIndex.map { "f:\($0)" } ?? "d:" + n.path.joined(separator: "\u{1}"), depth: depth, name: n.name, path: n.path, fileIndex: n.fileIndex,
                               size: n.size, fileCount: n.files.count, chosenCount: n.fileIndex != nil ? (selection.priority(of: n.fileIndex!) > .skip ? 1 : 0) : chosen(n.files)))
                if n.fileIndex == nil, expanded.contains(n.path.joined(separator: "\u{1}")) { walk(child, depth: depth + 1) }
            }
        }
        walk(0, depth: 0)
        return out
    }

    /// The files at or under a folder path (or the one file), by index.
    func files(under path: [String]) -> [Int] {
        var position = 0
        for part in path {
            guard let next = nodes[position].children.first(where: { nodes[$0].name == part && nodes[$0].fileIndex == nil }) else { return [] }
            position = next
        }
        return nodes[position].files
    }

    /// Chooses (at Normal) or skips every file under a folder.
    func set(folder path: [String], chosen: Bool, in selection: inout TorrentSelection) {
        for i in files(under: path) { selection.priorities[i] = chosen ? (selection.priority(of: i) > .skip ? selection.priority(of: i) : .normal) : .skip }
    }

    /// Sets the priority of every file under a folder.
    func set(folder path: [String], priority: FilePriority, in selection: inout TorrentSelection) {
        for i in files(under: path) { selection.priorities[i] = priority }
    }

    /// Sets these files (a search's matches) to chosen or skipped.
    static func set(files: [Int], chosen: Bool, in selection: inout TorrentSelection) {
        for i in files { selection.priorities[i] = chosen ? (selection.priority(of: i) > .skip ? selection.priority(of: i) : .normal) : .skip }
    }

    /// The bytes of the chosen files.
    static func chosenBytes(_ selection: TorrentSelection, meta: TorrentMetainfo) -> Int64 {
        meta.files.reduce(0) { $0 + (!$1.isPadding && selection.priority(of: $1.index) > .skip ? $1.length : 0) }
    }
}
