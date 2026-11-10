import XCTest
@testable import Browser_Setu

/// The collection of start-page pictures: which one shows, how rotation moves on, what is read back, and when an animated wallpaper may play.
final class WallpaperLibraryTests: XCTestCase {
    private func entry(_ name: String, _ appearance: WallpaperAppearance = .any) -> WallpaperEntry {
        var e = WallpaperEntry(); e.name = name; e.appearance = appearance; return e
    }

    private func state(_ entries: [WallpaperEntry], rotation: WallpaperRotation = .off, shuffle: Bool = false, selected: UUID? = nil, counter: Int = 0) -> WallpaperLibraryState {
        var s = WallpaperLibraryState(); s.entries = entries; s.rotation = rotation; s.shuffle = shuffle; s.selected = selected; s.counter = counter; return s
    }

    private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 86_400 + 3_600) }

    // MARK: Light and dark

    func testAPictureMadeForTheAppearanceBeatsOnesForEither() {
        let either = entry("either"), light = entry("light", .light), dark = entry("dark", .dark)
        let s = state([either, light, dark])
        XCTAssertEqual(WallpaperPicker.pick(s, dark: false)?.name, "light")
        XCTAssertEqual(WallpaperPicker.pick(s, dark: true)?.name, "dark")
    }

    func testAnUntaggedPictureChosenByHandNeverBeatsOnesTaggedForTheAppearance() {
        let either = entry("either"), light = entry("light", .light), dark = entry("dark", .dark)
        let s = state([light, dark, either], selected: either.id)
        XCTAssertEqual(WallpaperPicker.pick(s, dark: true)?.name, "dark", "found on screen: the last-added untagged picture hid both tagged ones")
        XCTAssertEqual(WallpaperPicker.pick(s, dark: false)?.name, "light")
        let rotating = state([light, dark, either], rotation: .everyTab, counter: 3)
        XCTAssertEqual(WallpaperPicker.pick(rotating, dark: true)?.name, "dark", "and rotation stays among the tagged ones")
    }

    func testWithNothingMadeForTheAppearanceTheEitherPicturesAreUsed() {
        let either = entry("either"), light = entry("light", .light)
        XCTAssertEqual(WallpaperPicker.pick(state([either, light]), dark: true)?.name, "either")
        XCTAssertNil(WallpaperPicker.pick(state([light]), dark: true), "a light-only collection shows nothing in dark mode, so the page falls back to its own background")
        XCTAssertNil(WallpaperPicker.pick(state([]), dark: false))
    }

    func testWithRotationOffTheChosenPictureStays() {
        let a = entry("a"), b = entry("b"), c = entry("c")
        let s = state([a, b, c], selected: b.id)
        for hour in 0..<5 { XCTAssertEqual(WallpaperPicker.pick(s, dark: false, now: day(0).addingTimeInterval(Double(hour) * 5_000))?.name, "b") }
        XCTAssertEqual(WallpaperPicker.pick(state([a, b, c], selected: UUID()), dark: false)?.name, "a", "a chosen picture that is gone falls back to the first")
    }

    // MARK: Rotation

    func testEachNewTabMovesOnOneAndWrapsAround() {
        let list = (0..<3).map { entry("p\($0)") }
        let names = (0..<7).map { WallpaperPicker.pick(state(list, rotation: .everyTab, counter: $0), dark: false)?.name }
        XCTAssertEqual(names, ["p0", "p1", "p2", "p0", "p1", "p2", "p0"])
        XCTAssertEqual(WallpaperPicker.pick(state(list, rotation: .everyTab, counter: -1), dark: false)?.name, "p2", "a counter that wrapped below zero still lands on a picture")
    }

    func testADailyRotationHoldsAllDayAndChangesTheNextDay() {
        let list = (0..<4).map { entry("p\($0)") }
        let s = state(list, rotation: .daily)
        let morning = day(0), evening = day(0).addingTimeInterval(8 * 3_600)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let a = WallpaperPicker.pick(s, dark: false, now: morning, calendar: cal), b = WallpaperPicker.pick(s, dark: false, now: evening, calendar: cal)
        XCTAssertEqual(a?.id, b?.id, "the same picture all day (UTC midday and eight hours later are the same day)")
        XCTAssertNotEqual(a?.id, WallpaperPicker.pick(s, dark: false, now: day(1), calendar: cal)?.id, "and the next one the day after")
    }

    func testAnHourlyRotationChangesWithTheHour() {
        let list = (0..<4).map { entry("p\($0)") }
        let s = state(list, rotation: .hourly)
        let now = day(0)
        XCTAssertNotEqual(WallpaperPicker.pick(s, dark: false, now: now)?.id, WallpaperPicker.pick(s, dark: false, now: now.addingTimeInterval(3_600))?.id)
        XCTAssertEqual(WallpaperPicker.pick(s, dark: false, now: now)?.id, WallpaperPicker.pick(s, dark: false, now: now.addingTimeInterval(10))?.id)
    }

    func testShuffleShowsEveryPictureOncePerPassAndIsRepeatable() {
        let list = (0..<5).map { entry("p\($0)") }
        let pass1 = (0..<5).compactMap { WallpaperPicker.pick(state(list, rotation: .everyTab, shuffle: true, counter: $0), dark: false)?.name }
        XCTAssertEqual(Set(pass1).count, 5, "each picture exactly once in the first pass")
        let again = (0..<5).compactMap { WallpaperPicker.pick(state(list, rotation: .everyTab, shuffle: true, counter: $0), dark: false)?.name }
        XCTAssertEqual(pass1, again, "the same counter gives the same picture")
        let pass2 = (5..<10).compactMap { WallpaperPicker.pick(state(list, rotation: .everyTab, shuffle: true, counter: $0), dark: false)?.name }
        XCTAssertEqual(Set(pass2).count, 5, "and every picture again in the second")
    }

    // MARK: Saved state

    func testTheCollectionSurvivesBeingSavedAndRead() throws {
        var s = state([entry("a", .dark), entry("b")], rotation: .daily, shuffle: true); s.selected = s.entries[1].id; s.counter = 7
        let read = try XCTUnwrap(WallpaperLibraryState.decode(s.encoded))
        XCTAssertEqual(read, s)
    }

    func testAnUnreadableOrMissingSettingGivesNilSoNothingIsCleanedUp() {
        XCTAssertNil(WallpaperLibraryState.decode(nil))
        XCTAssertNil(WallpaperLibraryState.decode(""))
        XCTAssertNil(WallpaperLibraryState.decode("not json"))
    }

    func testAStateWithMissingOrExtraKeysIsStillRead() throws {
        let read = try XCTUnwrap(WallpaperLibraryState.decode("{\"rotation\":\"hourly\",\"somethingNew\":1}"))
        XCTAssertEqual(read.rotation, .hourly); XCTAssertTrue(read.entries.isEmpty); XCTAssertFalse(read.shuffle)
        let withEntry = try XCTUnwrap(WallpaperLibraryState.decode("{\"entries\":[{\"name\":\"x\"}]}"))
        XCTAssertEqual(withEntry.entries.count, 1); XCTAssertEqual(withEntry.entries[0].appearance, .any)
    }

    func testTheCollectionIsCappedWhenRead() throws {
        var s = WallpaperLibraryState(); s.entries = (0..<(WallpaperLibraryState.maxEntries + 20)).map { entry("p\($0)") }
        XCTAssertEqual(try XCTUnwrap(WallpaperLibraryState.decode(s.encoded)).entries.count, WallpaperLibraryState.maxEntries)
    }

    // MARK: Gradient presets

    func testEveryPresetIsWellFormed() {
        XCTAssertEqual(Set(StartPreset.all.map(\.id)).count, StartPreset.all.count, "ids are unique")
        XCTAssertTrue(StartPreset.all.contains { $0.id == StartPreset.defaultID })
        for preset in StartPreset.all {
            XCTAssertGreaterThanOrEqual(preset.stops.count, 2, preset.name)
            XCTAssertEqual(preset.stops.map(\.at), preset.stops.map(\.at).sorted(), "\(preset.name): stops run in order")
            XCTAssertEqual(preset.stops.first?.at, 0); XCTAssertEqual(preset.stops.last?.at, 1)
            for stop in preset.stops { XCTAssertEqual(stop.hex.count, 6, "\(preset.name): \(stop.hex)") }
        }
        XCTAssertEqual(StartPreset.named("no-such-preset").id, StartPreset.all[0].id, "an unknown id gives the first preset")
        XCTAssertTrue(StartPreset.all.contains { !$0.isDark }, "there is a light one for dark ink")
    }

    // MARK: Animated wallpaper

    func testAnAnimatedWallpaperPlaysOnlyWhenEveryConditionHolds() {
        func may(on: Bool = true, has: Bool = true, priv: Bool = false, reduce: Bool = false, low: Bool = false, active: Bool = true, shown: Bool = true) -> Bool {
            AnimatedWallpaperRules.mayPlay(switchedOn: on, hasVideo: has, isPrivate: priv, reduceMotion: reduce, lowPower: low, windowActive: active, onScreen: shown)
        }
        XCTAssertTrue(may())
        XCTAssertFalse(may(on: false)); XCTAssertFalse(may(has: false)); XCTAssertFalse(may(priv: true)); XCTAssertFalse(may(reduce: true))
        XCTAssertFalse(may(low: true)); XCTAssertFalse(may(active: false)); XCTAssertFalse(may(shown: false))
    }

    @MainActor
    func testEveryWindowShowingTheSameVideoSharesOnePlayerAndItIsReleasedWhenTheLastLetsGo() async throws {
        // Found on the real app: three windows each looked like they wanted a different video (their own counters disagreed), so the one shared player was rebuilt on every
        // attach and the earlier windows were left holding a dead one. The identity is the file, so any number of windows share one.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString).mov")
        try Data(repeating: 7, count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = WallpaperPlayer.shared
        let before = player.playersMade
        player.attach(file); player.attach(file); player.attach(file)             // three windows
        XCTAssertEqual(player.playersMade - before, 1, "one player for all three")
        XCTAssertEqual(player.consumers, 3)
        player.detach(); player.detach()
        XCTAssertNotNil(player.player, "one window still shows it, so it stays")
        player.detach()
        XCTAssertEqual(player.consumers, 0)
        // Paused at once, released after a moment; a window that returns before then finds the same player.
        player.attach(file)
        XCTAssertEqual(player.playersMade - before, 1, "a quick return reuses the player that was still there")
        player.detach()
        try await Task.sleep(for: .milliseconds(2600))
        XCTAssertNil(player.player, "released once nobody had shown it for a moment")
    }

    @MainActor
    func testTheVideoIdentityChangesWithTheFileAndOnlyThen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString).mov")
        try Data(repeating: 1, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = WallpaperPlayer.identity(of: file)
        XCTAssertEqual(WallpaperPlayer.identity(of: file), first, "the same file gives the same identity, however many windows ask")
        try Data(repeating: 2, count: 400).write(to: file)
        XCTAssertNotEqual(WallpaperPlayer.identity(of: file), first, "a replaced loop is a different video")
    }

    func testTheTiltEffectIsSavedWithTheLook() {
        var look = StartLook(); look.motion = true
        XCTAssertTrue(StartLook.decode(look.encoded).motion)
        XCTAssertFalse(StartLook.decode("{\"focalX\":0.4}").motion, "a look saved before the effect existed has it off")
    }
}
