import Foundation

// MARK: Which files of a torrent are wanted, and how urgently (DX-05)
//
// A person chooses files (and a priority for each); the engine turns that into which pieces are needed and in what order. Nothing here touches the disk or the network.
//
// The one subtle rule: a piece can hold bytes of two files (the end of one, the start of the next). A piece is needed when ANY selected file has bytes in it, because its hash can only be
// checked as a whole; the bytes it holds for files that are not selected are kept in the scratch file and never published. A piece's urgency is the highest priority of the SELECTED
// files that touch it: a skipped file adds none.

enum FilePriority: Int, Codable, CaseIterable, Sendable, Comparable {
    case skip = 0, low = 1, normal = 2, high = 3, maximum = 4
    static func < (a: FilePriority, b: FilePriority) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self { case .skip: "Skip"; case .low: "Low"; case .normal: "Normal"; case .high: "High"; case .maximum: "Maximum" }
    }
}

/// The order new pieces are taken in, among pieces of the same priority.
enum ScheduleMode: String, Codable, CaseIterable, Sendable {
    /// Rarest first (the swarm's health).
    case automatic
    /// Lowest piece number first. Lets a file be used from the start while it arrives; less efficient for the swarm.
    case sequential
    /// A window of pieces from a playback position first, then rarest first.
    case streaming
    var title: String {
        switch self { case .automatic: "Rarest first"; case .sequential: "In order"; case .streaming: "Streaming" }
    }
}

/// A person's choice for one torrent: a priority for each file by its stable index. A file without an entry is Normal when the whole torrent is chosen by default.
struct TorrentSelection: Codable, Equatable, Sendable {
    var priorities: [Int: FilePriority]
    var mode: ScheduleMode = .automatic
    /// Streaming: the file and byte position playback is at (nil: the start of the first file with the highest priority).
    var streamFile: Int?
    var streamPosition: Int64 = 0

    init(priorities: [Int: FilePriority], mode: ScheduleMode = .automatic) { self.priorities = priorities; self.mode = mode }

    /// Everything, at Normal.
    static func all(_ meta: TorrentMetainfo) -> TorrentSelection { TorrentSelection(priorities: Dictionary(uniqueKeysWithValues: meta.files.filter { !$0.isPadding }.map { ($0.index, FilePriority.normal) })) }

    /// Only these files, at Normal; every other file is skipped. (Padding is not a file: it never gets an entry.)
    static func only(_ indices: Set<Int>, in meta: TorrentMetainfo) -> TorrentSelection {
        TorrentSelection(priorities: Dictionary(uniqueKeysWithValues: meta.files.filter { !$0.isPadding }.map { ($0.index, indices.contains($0.index) ? FilePriority.normal : .skip) }))
    }

    func priority(of file: Int) -> FilePriority { priorities[file] ?? .skip }

    /// File indices with any priority above Skip that exist in the torrent.
    func selected(in meta: TorrentMetainfo) -> Set<Int> {
        let valid = Set(meta.files.filter { !$0.isPadding }.map(\.index))
        return Set(priorities.filter { $0.value > .skip && valid.contains($0.key) }.map(\.key))
    }

    /// Drops entries for files the torrent does not have (a damaged or stale saved choice).
    func normalized(for meta: TorrentMetainfo) -> TorrentSelection {
        var copy = self
        let valid = Set(meta.files.filter { !$0.isPadding }.map(\.index))          // an old saved choice that named a padding entry loads fine: the entry is dropped
        copy.priorities = priorities.filter { valid.contains($0.key) }
        if let f = streamFile, !valid.contains(f) { copy.streamFile = nil; copy.streamPosition = 0 }
        return copy
    }

    /// Sets one folder's files (those whose path starts with `prefix`) to a priority.
    mutating func setFolder(_ prefix: [String], to priority: FilePriority, in meta: TorrentMetainfo) {
        for f in meta.files where !f.isPadding && f.path.count > prefix.count && Array(f.path.prefix(prefix.count)) == prefix { priorities[f.index] = priority }
    }
}

/// What the scheduler needs, derived from a selection: the needed pieces and a weight for each piece.
struct TorrentPlan: Equatable, Sendable {
    var selected: Set<Int>
    /// Pieces that hold a byte of a selected file (a boundary piece shared with a skipped file counts).
    var needed: [Int]
    /// For every piece: the highest priority raw value of the selected files that touch it (0 when none).
    var weights: [Int]
    var mode: ScheduleMode
    /// The piece playback is at, for streaming.
    var anchorPiece: Int?
    /// Bytes of selected files.
    var selectedBytes: Int64

    init(_ selection: TorrentSelection, meta: TorrentMetainfo) {
        let valid = selection.normalized(for: meta)
        selected = valid.selected(in: meta)
        var w = [Int](repeating: 0, count: meta.pieceCount)
        var bytes: Int64 = 0
        let pl = meta.pieceLength
        for f in meta.files where selected.contains(f.index) && f.length > 0 {
            bytes += f.length
            let weight = valid.priority(of: f.index).rawValue
            let first = Int(f.offset / pl), last = Int((f.offset + f.length - 1) / pl)
            for p in first...last where p < w.count { if weight > w[p] { w[p] = weight } }
        }
        weights = w
        needed = (0..<w.count).filter { w[$0] > 0 }
        mode = valid.mode
        selectedBytes = bytes
        if valid.mode == .streaming {
            // The file playback is in; or else the selected file with the highest priority (the first one among equals).
            let candidates = meta.files.filter { selected.contains($0.index) && $0.length > 0 }
            let file = valid.streamFile.flatMap { i in meta.files.first { $0.index == i && $0.length > 0 } }
                ?? candidates.max { a, b in let pa = valid.priority(of: a.index), pb = valid.priority(of: b.index); return pa != pb ? pa < pb : a.index > b.index }
            if let f = file { anchorPiece = Int((f.offset + min(max(0, valid.streamPosition), max(0, f.length - 1))) / pl) }
        }
    }
}

/// One file's state, for the screens.
struct TorrentFileProgress: Identifiable, Equatable, Sendable {
    var id: Int { index }
    var index: Int
    var path: [String]
    var length: Int64
    var priority: FilePriority
    /// Bytes of this file that lie in verified pieces.
    var verified: Int64
    var isSelected: Bool { priority > .skip }
    var isComplete: Bool { length > 0 ? verified >= length : isSelected }
    var fraction: Double { length > 0 ? min(1, Double(verified) / Double(length)) : (isSelected ? 1 : 0) }
}

// MARK: Magnet "so" (BEP 53)

/// The file indices a magnet link asks for: `so=0,2,4,6-8` (zero-based, ranges inclusive). Malformed input is reported, not guessed at: it never means "everything".
enum MagnetSelection {
    static let maxItems = 4096
    static let maxIndex = TorrentMetainfo.Limit.maxFiles - 1

    enum Result: Equatable, Sendable {
        case indices(Set<Int>)
        case malformed(String)
    }

    static func parse(_ value: String) -> Result {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .malformed("The magnet link's file choice is empty.") }
        var out = Set<Int>()
        let items = text.split(separator: ",", omittingEmptySubsequences: false)
        guard items.count <= maxItems else { return .malformed("The magnet link's file choice is too long.") }
        for raw in items {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return .malformed("The magnet link's file choice has an empty entry.") }
            let parts = item.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            func number(_ s: String) -> Int? { s.count <= 6 && !s.isEmpty && s.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(s) : nil }
            switch parts.count {
            case 1:
                guard let n = number(parts[0]), n <= maxIndex else { return .malformed("“\(item)” is not a file number.") }
                out.insert(n)
            case 2:
                guard let a = number(parts[0]), let b = number(parts[1]), a <= b, b <= maxIndex else { return .malformed("“\(item)” is not a range of file numbers.") }
                for n in a...b { out.insert(n) }
            default:
                return .malformed("“\(item)” is not a file number or a range.")
            }
            if out.count > TorrentMetainfo.Limit.maxFiles { return .malformed("The magnet link asks for too many files.") }
        }
        return .indices(out)
    }

    /// The choice checked against the real file list: indices beyond the torrent are a problem, never ignored silently.
    static func apply(_ indices: Set<Int>, to meta: TorrentMetainfo) -> (selection: TorrentSelection, problem: String?) {
        let mapped = fileIndices(indices, in: meta)
        let valid = Set(meta.files.filter { !$0.isPadding }.map(\.index))
        let known = mapped.intersection(valid)
        let unknown = indices.subtracting(indices.filter { fileIndices([$0], in: meta).isEmpty == false })
        if known.isEmpty { return (TorrentSelection.only([], in: meta), "The magnet link asks for files this torrent does not have (it has \(meta.visibleFiles.count)). Choose the files you want.") }
        let problem = unknown.isEmpty ? nil : "The magnet link also named \(unknown.count) file number\(unknown.count == 1 ? "" : "s") this torrent does not have; the others are selected."
        return (TorrentSelection.only(known, in: meta), problem)
    }

    /// An already-known torrent receiving the same magnet: the named files not being downloaded are added at Normal; nothing else changes (BEP 53).
    static func merge(_ indices: Set<Int>, into current: TorrentSelection, meta: TorrentMetainfo) -> TorrentSelection {
        var copy = current
        for i in fileIndices(indices, in: meta) where current.priority(of: i) == .skip { copy.priorities[i] = .normal }
        return copy
    }

    /// What `so=` numbers mean. A version 1 torrent: positions in its file list, as before. A version 2 or hybrid torrent: positions among the real files (the file tree's order), because
    /// the alignment padding is not a file anyone can see. Numbers beyond the files give nothing.
    static func fileIndices(_ numbers: Set<Int>, in meta: TorrentMetainfo) -> Set<Int> {
        if meta.version == .v1 { return numbers.intersection(Set(meta.files.filter { !$0.isPadding }.map(\.index))) }
        let real = meta.visibleFiles
        return Set(numbers.compactMap { $0 >= 0 && $0 < real.count ? real[$0].index : nil })
    }
}
