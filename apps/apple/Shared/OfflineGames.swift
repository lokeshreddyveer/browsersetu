import SwiftUI

// Four small games for the error pages where the trouble is the connection itself. They are original, run entirely on this device (no network, nothing saved, no scores kept
// after the page goes), are only built when one is chosen, and stop the moment the page is closed. The rules are plain values, tested without any screen.

// MARK: - Rules

/// 2048: slide the tiles, equal tiles that meet join.
struct Game2048: Equatable {
    enum Direction { case up, down, left, right }
    private(set) var board: [[Int]] = Array(repeating: Array(repeating: 0, count: 4), count: 4)
    private(set) var score = 0

    var hasWon: Bool { board.joined().contains { $0 >= 2048 } }
    var isOver: Bool {
        for d in [Direction.up, .down, .left, .right] { var copy = self; if copy.slide(d) { return false } }
        return true
    }

    /// One row slid to the left: tiles close up, equal neighbours join once, and the score gained is what the joins made.
    static func slideRow(_ row: [Int]) -> (row: [Int], gained: Int) {
        let tiles = row.filter { $0 != 0 }
        var out: [Int] = [], gained = 0, i = 0
        while i < tiles.count {
            if i + 1 < tiles.count, tiles[i] == tiles[i + 1] { out.append(tiles[i] * 2); gained += tiles[i] * 2; i += 2 }
            else { out.append(tiles[i]); i += 1 }
        }
        return (out + Array(repeating: 0, count: row.count - out.count), gained)
    }

    /// Slides every tile; true when anything moved (a slide that moves nothing is not a move, and adds no tile).
    @discardableResult
    mutating func slide(_ direction: Direction) -> Bool {
        let before = board
        var gained = 0
        func apply(_ rows: [[Int]]) -> [[Int]] { rows.map { let r = Self.slideRow($0); gained += r.gained; return r.row } }
        switch direction {
        case .left: board = apply(board)
        case .right: board = apply(board.map { Array($0.reversed()) }).map { Array($0.reversed()) }
        case .up: board = transposed(apply(transposed(board)))
        case .down: board = transposed(apply(transposed(board).map { Array($0.reversed()) }).map { Array($0.reversed()) })
        }
        score += gained
        return board != before
    }

    private func transposed(_ m: [[Int]]) -> [[Int]] { (0..<4).map { c in (0..<4).map { r in m[r][c] } } }

    /// A 2 (or, one time in ten, a 4) in an empty square.
    mutating func addTile<G: RandomNumberGenerator>(using generator: inout G) {
        let empty = (0..<16).filter { board[$0 / 4][$0 % 4] == 0 }
        guard let spot = empty.randomElement(using: &generator) else { return }
        board[spot / 4][spot % 4] = Int.random(in: 0..<10, using: &generator) == 0 ? 4 : 2
    }

    static func new<G: RandomNumberGenerator>(using generator: inout G) -> Game2048 {
        var game = Game2048(); game.addTile(using: &generator); game.addTile(using: &generator); return game
    }
}

/// Tic-Tac-Toe against a computer that plays the obvious moves: it takes a win, blocks yours, then the centre, a corner, anything. It can be beaten.
struct TicTacToe: Equatable {
    enum Mark: String { case x = "X", o = "O" }
    private(set) var cells: [Mark?] = Array(repeating: nil, count: 9)
    static let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    var winner: Mark? {
        for line in Self.lines { if let m = cells[line[0]], cells[line[1]] == m, cells[line[2]] == m { return m } }
        return nil
    }
    var winningLine: [Int]? {
        Self.lines.first { line in cells[line[0]] != nil && cells[line[1]] == cells[line[0]] && cells[line[2]] == cells[line[0]] }
    }
    var isFull: Bool { !cells.contains { $0 == nil } }
    var isOver: Bool { winner != nil || isFull }

    @discardableResult
    mutating func play(_ index: Int, as mark: Mark) -> Bool {
        guard cells.indices.contains(index), cells[index] == nil, !isOver else { return false }
        cells[index] = mark
        return true
    }

    private func completing(_ mark: Mark) -> Int? {
        for line in Self.lines {
            let marks = line.map { cells[$0] }
            if marks.filter({ $0 == mark }).count == 2, let empty = line.first(where: { cells[$0] == nil }) { return empty }
        }
        return nil
    }

    func computerMove<G: RandomNumberGenerator>(as mark: Mark, using generator: inout G) -> Int? {
        let other: Mark = mark == .x ? .o : .x
        if let win = completing(mark) { return win }
        if let block = completing(other) { return block }
        if cells[4] == nil { return 4 }
        let corners = [0, 2, 6, 8].filter { cells[$0] == nil }
        if let corner = corners.randomElement(using: &generator) { return corner }
        return (0..<9).filter { cells[$0] == nil }.randomElement(using: &generator)
    }
}

/// Memory Match: eight pairs face down; turn two at a time.
struct MemoryGame: Equatable {
    struct Card: Equatable, Identifiable { var id: Int; var symbol: String; var faceUp = false; var matched = false }
    enum Outcome: Equatable { case ignored, firstTurned, matched, mismatch(Int, Int) }

    private(set) var cards: [Card]
    private(set) var moves = 0
    private var first: Int?
    static let symbols = ["star.fill", "heart.fill", "moon.fill", "sun.max.fill", "leaf.fill", "bolt.fill", "flame.fill", "drop.fill"]

    var isComplete: Bool { cards.allSatisfy(\.matched) }

    init<G: RandomNumberGenerator>(using generator: inout G) {
        let symbols = (Self.symbols + Self.symbols).shuffled(using: &generator)
        cards = symbols.enumerated().map { Card(id: $0.offset, symbol: $0.element) }
    }

    mutating func turn(_ index: Int) -> Outcome {
        guard cards.indices.contains(index), !cards[index].faceUp, !cards[index].matched else { return .ignored }
        cards[index].faceUp = true
        guard let other = first else { first = index; return .firstTurned }
        first = nil
        moves += 1
        if cards[other].symbol == cards[index].symbol { cards[other].matched = true; cards[index].matched = true; return .matched }
        return .mismatch(other, index)
    }

    /// Turns a mismatched pair back down.
    mutating func hide(_ a: Int, _ b: Int) {
        for i in [a, b] where cards.indices.contains(i) && !cards[i].matched { cards[i].faceUp = false }
    }
}

/// Snake on a small square board.
struct SnakeGame: Equatable {
    struct Point: Equatable, Hashable { var x: Int; var y: Int }
    enum Direction { case up, down, left, right
        var opposite: Direction { switch self { case .up: .down; case .down: .up; case .left: .right; case .right: .left } }
    }

    let size = 14
    private(set) var body: [Point] = [Point(x: 7, y: 7), Point(x: 6, y: 7), Point(x: 5, y: 7)]
    private(set) var direction = Direction.right
    private var queued: Direction?
    private(set) var food = Point(x: 11, y: 7)
    private(set) var score = 0
    private(set) var isOver = false

    /// A turn is taken at the next step, and turning straight back on itself is ignored.
    mutating func turn(_ new: Direction) {
        let reference = queued ?? direction
        if new != reference.opposite, new != reference { queued = new }
    }

    mutating func step<G: RandomNumberGenerator>(using generator: inout G) {
        guard !isOver else { return }
        if let queued { direction = queued; self.queued = nil }
        var head = body[0]
        switch direction { case .up: head.y -= 1; case .down: head.y += 1; case .left: head.x -= 1; case .right: head.x += 1 }
        let eats = head == food
        // The tail moves out of the way unless the snake grows, so following its own tail is allowed.
        let blocking = eats ? body : Array(body.dropLast())
        guard (0..<size).contains(head.x), (0..<size).contains(head.y), !blocking.contains(head) else { isOver = true; return }
        body.insert(head, at: 0)
        if eats {
            score += 1
            let free = (0..<(size * size)).map { Point(x: $0 % size, y: $0 / size) }.filter { !body.contains($0) }
            if let spot = free.randomElement(using: &generator) { food = spot } else { isOver = true }
        } else {
            body.removeLast()
        }
    }
}

// MARK: - The screen that offers them

/// The four games behind a small picker. Only the chosen game is built.
struct OfflineGamesView: View {
    enum Choice: String, CaseIterable, Identifiable {
        case snake = "Snake", twenty48 = "2048", ticTacToe = "Tic-Tac-Toe", memory = "Memory"
        var id: String { rawValue }
    }

    @State private var choice = Choice.snake
    var accent: Color = .accentColor

    var body: some View {
        VStack(spacing: 12) {
            Picker("Game", selection: $choice) { ForEach(Choice.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                .accessibilityLabel("Choose a game")
            Group {
                switch choice {
                case .snake: SnakeView(accent: accent)
                case .twenty48: TwentyFortyEightView(accent: accent)
                case .ticTacToe: TicTacToeView(accent: accent)
                case .memory: MemoryView(accent: accent)
                }
            }
            .id(choice)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.18), value: choice)
    }
}

private struct GameFrame<Content: View>: View {
    let status: String
    let restart: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("New Game", action: restart).buttonStyle(.borderless).font(.system(size: 13))
            }
            .frame(maxWidth: 300)
            content
        }
    }
}

private struct SnakeView: View {
    let accent: Color
    @State private var game = SnakeGame()
    @State private var running = false
    @FocusState private var focused: Bool

    var body: some View {
        GameFrame(status: game.isOver ? "Game over · \(game.score)" : (running ? "Score \(game.score)" : "Arrow keys or swipe to start"), restart: restart) {
            Canvas { context, size in
                let cell = size.width / CGFloat(game.size)
                func rect(_ p: SnakeGame.Point) -> CGRect { CGRect(x: CGFloat(p.x) * cell + 1, y: CGFloat(p.y) * cell + 1, width: cell - 2, height: cell - 2) }
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(.primary.opacity(0.06)))
                context.fill(Path(ellipseIn: rect(game.food).insetBy(dx: 2, dy: 2)), with: .color(.red.opacity(0.85)))
                for (i, p) in game.body.enumerated() { context.fill(Path(roundedRect: rect(p), cornerRadius: 4), with: .color(i == 0 ? accent : accent.opacity(0.6))) }
            }
            .frame(width: 280, height: 280)
            .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                turn(abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up))
            })
            .focusable().focused($focused)
            .onKeyPress(.upArrow) { turn(.up); return .handled }
            .onKeyPress(.downArrow) { turn(.down); return .handled }
            .onKeyPress(.leftArrow) { turn(.left); return .handled }
            .onKeyPress(.rightArrow) { turn(.right); return .handled }
            .accessibilityLabel("Snake. Score \(game.score).")
            .accessibilityHint("Use the arrow keys, or swipe, to steer.")
        }
        .onAppear { focused = true }
        // The loop belongs to this view: it stops when the view goes, and while the game is over.
        .task(id: running && !game.isOver) {
            guard running, !game.isOver else { return }
            var generator = SystemRandomNumberGenerator()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                if Task.isCancelled { break }
                game.step(using: &generator)
                if game.isOver { break }
            }
        }
    }

    private func turn(_ d: SnakeGame.Direction) { game.turn(d); running = true }
    private func restart() { game = SnakeGame(); running = false; focused = true }
}

private struct TwentyFortyEightView: View {
    let accent: Color
    @State private var game: Game2048
    @FocusState private var focused: Bool

    init(accent: Color) {
        self.accent = accent
        var generator = SystemRandomNumberGenerator()
        _game = State(initialValue: Game2048.new(using: &generator))
    }

    var body: some View {
        GameFrame(status: game.hasWon ? "You made 2048 · \(game.score)" : (game.isOver ? "No moves left · \(game.score)" : "Score \(game.score)"), restart: restart) {
            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: 6) { ForEach(0..<4, id: \.self) { c in tile(game.board[r][c]) } }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07)))
            .gesture(DragGesture(minimumDistance: 14).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                move(abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up))
            })
            .focusable().focused($focused)
            .onKeyPress(.upArrow) { move(.up); return .handled }
            .onKeyPress(.downArrow) { move(.down); return .handled }
            .onKeyPress(.leftArrow) { move(.left); return .handled }
            .onKeyPress(.rightArrow) { move(.right); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("2048. Score \(game.score).")
            .accessibilityHint("Use the arrow keys, or swipe, to slide the tiles.")
        }
        .onAppear { focused = true }
    }

    private func tile(_ value: Int) -> some View {
        Text(value == 0 ? "" : "\(value)")
            .font(.system(size: value >= 1024 ? 17 : 22, weight: .bold, design: .rounded))
            .foregroundStyle(value <= 4 ? Color.primary.opacity(0.8) : .white)
            .frame(width: 62, height: 62)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(value == 0 ? Color.primary.opacity(0.06) : accent.opacity(min(0.25 + Double(log2(Double(max(value, 2)))) * 0.07, 1))))
    }

    private func move(_ d: Game2048.Direction) {
        guard !game.isOver else { return }
        if game.slide(d) { var generator = SystemRandomNumberGenerator(); game.addTile(using: &generator) }
    }

    private func restart() { var generator = SystemRandomNumberGenerator(); game = Game2048.new(using: &generator); focused = true }
}

private struct TicTacToeView: View {
    let accent: Color
    @State private var game = TicTacToe()

    var body: some View {
        GameFrame(status: status, restart: { game = TicTacToe() }) {
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { c in
                            let i = r * 3 + c
                            Button { tap(i) } label: {
                                Text(game.cells[i]?.rawValue ?? "")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(game.cells[i] == .x ? accent : Color.primary.opacity(0.7))
                                    .frame(width: 82, height: 82)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(game.winningLine?.contains(i) == true ? accent.opacity(0.22) : Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Square \(i + 1), \(game.cells[i].map { $0 == .x ? "yours" : "the computer’s" } ?? "empty")")
                        }
                    }
                }
            }
        }
    }

    private var status: String {
        if let w = game.winner { return w == .x ? "You win" : "The computer wins" }
        return game.isFull ? "A draw" : "Your move (X)"
    }

    private func tap(_ i: Int) {
        guard game.play(i, as: .x) else { return }
        var generator = SystemRandomNumberGenerator()
        if !game.isOver, let reply = game.computerMove(as: .o, using: &generator) { game.play(reply, as: .o) }
    }
}

private struct MemoryView: View {
    let accent: Color
    @State private var game: MemoryGame
    @State private var locked = false

    init(accent: Color) {
        self.accent = accent
        var generator = SystemRandomNumberGenerator()
        _game = State(initialValue: MemoryGame(using: &generator))
    }

    var body: some View {
        GameFrame(status: game.isComplete ? "Done in \(game.moves) moves" : "Moves \(game.moves)", restart: restart) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 6), count: 4), spacing: 6) {
                ForEach(game.cards) { card in
                    Button { tap(card.id) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(card.faceUp || card.matched ? accent.opacity(card.matched ? 0.18 : 0.3) : Color.primary.opacity(0.1))
                            if card.faceUp || card.matched { Image(systemName: card.symbol).font(.system(size: 22)).foregroundStyle(accent) }
                        }
                        .frame(width: 62, height: 62)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(card.faceUp || card.matched ? "Card showing \(card.symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))" : "Card face down")
                }
            }
        }
    }

    private func tap(_ index: Int) {
        guard !locked else { return }
        switch game.turn(index) {
        case .mismatch(let a, let b):
            locked = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                game.hide(a, b)
                locked = false
            }
        default: break
        }
    }

    private func restart() { var generator = SystemRandomNumberGenerator(); game = MemoryGame(using: &generator); locked = false }
}
