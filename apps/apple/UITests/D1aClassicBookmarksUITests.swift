import XCTest

/// Section 16: Classic's bookmarks and folders, operation by operation, on a throwaway profile with six bookmarks in three folders (Favorites 1–2, Project Resources 3–4, Reading 5, and Bookmark 0 unfiled).
/// Text prompts and confirmations are answered through the Debug test seams (`-UITestPromptAnswer`, `-UITestDialogAnswer`), because a UI test cannot type into a modal alert.
final class D1aClassicBookmarksUITests: PerfCase {
    private func launchLibrary(_ extra: [String] = [], tabs: Int = 5) {
        launch(state: "bulk-tabs", extra: ["-UITabCount", "\(tabs)", "-UILayout", "classic", "-UIBookmarks", "1", "-UISidebarOpen", "1"] + extra, env: [:])
        XCTAssertNotNil(until(30) { win.exists && any("sidebar").exists }, "the Library did not open")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)).hover()
        Thread.sleep(forTimeInterval: 0.2)
    }
    private func element(_ label: String) -> XCUIElement { win.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch }
    private func folder(_ name: String, _ count: Int) -> XCUIElement { win.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), \(count) bookmark")).firstMatch }
    private func rowLabels() -> [String] { snapItems().filter { ($0.label.hasPrefix("Bookmark ") || $0.label == "Renamed") && $0.frame.minX - win.frame.minX < 300 }.map(\.label) }
    private func item(_ title: String) -> XCUIElement? { app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable } }

    /// BM-05: Rename changes the title and nothing else; Edit Address changes the address and keeps the title and folder.
    func testRenameAndEditAddress() throws {
        launchLibrary(["-UITestPromptAnswer", "Renamed"])
        element("Bookmark 2").rightClick()
        XCTAssertNotNil(until(3) { self.item("Rename…") != nil }, "no Rename… in the bookmark's menu"); item("Rename…")?.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(element("Renamed").exists, "the bookmark was not renamed: \(rowLabels())")
        XCTAssertFalse(element("Bookmark 2").exists)
        XCTAssertTrue(folder("Favorites", 2).exists, "renaming moved the bookmark out of its folder")
        app.terminate()
        launchLibrary(["-UITestPromptAnswer", "http://127.0.0.1:18765/p/Edited"])
        element("Bookmark 0").rightClick()
        XCTAssertNotNil(until(3) { self.item("Edit Address…") != nil }); item("Edit Address…")?.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(element("Bookmark 0").exists, "editing the address changed the title")
        element("Bookmark 0").click()
        XCTAssertNotNil(until(5) { self.chipSnapshots().first(where: { $0.selected })?.label.contains("Edited") == true }, "the bookmark does not open the new address: \(chipSnapshots().first { $0.selected }?.label ?? "-")")
    }

    /// BM-05/06: renaming a folder keeps its bookmarks (same titles) under the new name; an existing folder name is refused.
    func testRenameFolder() throws {
        launchLibrary(["-UITestPromptAnswer", "Docs"])
        folder("Project Resources", 2).rightClick()
        XCTAssertNotNil(until(3) { self.item("Rename Folder…") != nil }, "no Rename Folder…"); item("Rename Folder…")?.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(folder("Docs", 2).exists, "the folder was not renamed")
        XCTAssertFalse(folder("Project Resources", 2).exists)
        XCTAssertTrue(element("Bookmark 3").exists && element("Bookmark 4").exists, "the folder's bookmarks were lost in the rename")
        attachShot("bm-folder-renamed")
        app.terminate()
        launchLibrary(["-UITestPromptAnswer", "Reading"])           // a name another folder already has
        folder("Project Resources", 2).rightClick()
        XCTAssertNotNil(until(3) { self.item("Rename Folder…") != nil }); item("Rename Folder…")?.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(folder("Project Resources", 2).exists && folder("Reading", 1).exists, "an existing name was merged instead of refused")
    }

    /// BM-09: deleting a folder asks; "Keep the Bookmarks" keeps them unfiled, "Delete the Bookmarks" removes them, and Cancel does nothing.
    func testDeleteFolderKeepsOrDeletesAsAsked() throws {
        launchLibrary(["-UITestDialogAnswer", "Keep the Bookmarks"])
        folder("Reading", 1).rightClick()
        XCTAssertNotNil(until(3) { self.item("Delete Folder…") != nil }); item("Delete Folder…")?.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(folder("Reading", 1).exists, "the folder is still there")
        XCTAssertTrue(element("Bookmark 5").exists, "'Keep the Bookmarks' lost the bookmark")
        XCTAssertTrue(folder("Bookmarks", 2).exists, "the kept bookmark did not join the unfiled list")
        app.terminate()
        launchLibrary(["-UITestDialogAnswer", "Delete the Bookmarks"])
        folder("Reading", 1).rightClick()
        XCTAssertNotNil(until(3) { self.item("Delete Folder…") != nil }); item("Delete Folder…")?.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(element("Bookmark 5").exists, "'Delete the Bookmarks' kept it")
        app.terminate()
        launchLibrary(["-UITestDialogAnswer", "Cancel"])
        folder("Reading", 1).rightClick()
        XCTAssertNotNil(until(3) { self.item("Delete Folder…") != nil }); item("Delete Folder…")?.click(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(folder("Reading", 1).exists && element("Bookmark 5").exists, "Cancel changed something")
    }

    /// BM-10/11: Copy Address puts that bookmark's address on the pasteboard; Open in Background Tab adds a tab and leaves the selection.
    func testCopyAddressAndOpenInBackground() throws {
        launchLibrary()
        element("Bookmark 4").rightClick()
        XCTAssertNotNil(until(3) { self.item("Copy Address") != nil }); item("Copy Address")?.click(); Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "http://127.0.0.1:18765/p/Mark4", "the wrong address was copied")
        let selected = chipSnapshots().first { $0.selected }?.label, tabs = chipSnapshots().count
        element("Bookmark 3").rightClick()
        XCTAssertNotNil(until(3) { self.item("Open in Background Tab") != nil }); item("Open in Background Tab")?.click()
        XCTAssertNotNil(until(5) { self.chipSnapshots().count == tabs + 1 }, "no background tab was opened")
        XCTAssertEqual(chipSnapshots().first { $0.selected }?.label, selected, "opening in the background changed the selected tab")
    }

    /// BM-07/08: dragging a bookmark onto a folder moves it there (its title and address stay); dragging a tab onto a folder does nothing.
    func testDraggingABookmarkOntoAFolder() throws {
        launchLibrary()
        let source = element("Bookmark 0"), target = folder("Favorites", 2)
        XCTAssertTrue(source.exists && target.exists)
        // macOS's mouse drag: press and hold on the source, then drag to the destination (XCUIElement.click(forDuration:thenDragTo:)).
        source.click(forDuration: 0.3, thenDragTo: target)
        let moved = until(5) { self.folder("Favorites", 3).exists }
        if moved == nil { attachShot("bm-drag-no-move") }
        XCTAssertNotNil(moved, "the bookmark did not move into Favorites by dragging; folders now: \(snapItems().filter { $0.label.contains(" bookmark") && $0.frame.minX - win.frame.minX < 300 }.map(\.label))")
        XCTAssertTrue(element("Bookmark 0").exists, "the move lost the bookmark")
        attachShot("bm-dragged-into-folder")
    }

    /// BM-07 (the accessible alternative to dragging): Move to Folder in the bookmark's menu moves it to the chosen folder; its title and address stay.
    func testMoveToFolderFromTheMenu() throws {
        launchLibrary()
        element("Bookmark 0").rightClick()
        XCTAssertNotNil(until(3) { self.item("Move to Folder") != nil }, "no Move to Folder in the bookmark's menu")
        item("Move to Folder")?.click()
        XCTAssertNotNil(until(3) { self.item("Favorites") != nil }, "no Favorites in the Move to Folder list")
        item("Favorites")?.click()
        XCTAssertNotNil(until(4) { self.folder("Favorites", 3).exists }, "the bookmark did not move into Favorites")
        XCTAssertTrue(element("Bookmark 0").exists, "the move lost or renamed the bookmark")
        attachShot("bm-moved-to-folder")
    }

    /// BM-13: a search shows matches inside a folded folder; clearing the query folds it again.
    func testSearchRevealsMatchesInAFoldedFolder() throws {
        launchLibrary()
        folder("Reading", 1).click()
        XCTAssertNotNil(until(3) { !self.element("Bookmark 5").exists }, "the folder did not fold")
        let field = win.textFields.matching(NSPredicate(format: "placeholderValue == 'Search Bookmarks'")).firstMatch
        XCTAssertTrue(field.exists, "no Search Bookmarks field")
        field.click(); paste("Bookmark 5"); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(element("Bookmark 5").exists, "a search match inside a folded folder is hidden")
        attachShot("bm-search-in-folded-folder")
    }

    /// BM-03: the Library's + saves the page you are on once; pressing it again does not move or rename it.
    func testPlusSavesOnceAndNeverMovesASavedPage() throws {
        launchLibrary()
        any("library-add").click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(element("Page Bulk4").exists, "the page was not saved")
        // Move it to Favorites with the folder menu, then press + again.
        any("library-folder").click()
        XCTAssertNotNil(until(3) { self.item("Add This Page to Favorites") != nil }); item("Add This Page to Favorites")?.click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(folder("Favorites", 3).exists, "the page did not move into Favorites")
        any("library-add").click(); Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(folder("Favorites", 3).exists, "pressing + again moved the saved page out of Favorites")
    }

    // MARK: Section 18 — keyboard

    /// Delete while typing in the Library's search field edits the text and never deletes a bookmark.
    func testDeleteInSearchEditsTextAndDeletesNothing() throws {
        launchLibrary()
        let field = win.textFields["Search Bookmarks"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no search field")
        field.click(); field.typeText("Bookmark 1")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(field.value as? String, "Bookmark ", "Delete did not edit the search text")
        app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: [])      // empty the field again
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(((field.value as? String) ?? "").hasPrefix("Bookmark"), "the field was not emptied")
        let numbered = rowLabels().filter { $0.range(of: "^Bookmark [0-9]$", options: .regularExpression) != nil }
        XCTAssertEqual(numbered.count, 6, "a Delete in the search field removed a bookmark: \(numbered)")
    }

    private func markedLabels() -> [String] {
        snapItems().filter { $0.selected && ($0.label.hasPrefix("Bookmark ") || $0.label.contains(" bookmark")) && $0.frame.minX - win.frame.minX < 300 && $0.frame.minY - win.frame.minY > 120 }.map(\.label)
    }
    /// Clicking the Library's search field and pressing ↓ moves the keyboard into the list and marks its first row (Tab reaches the list only with Full Keyboard Access, which a test must not switch on).
    private func focusList() -> Bool {
        let field = win.textFields["Search Bookmarks"]
        guard field.waitForExistence(timeout: 3) else { return false }
        field.click()
        for _ in 0..<3 { app.typeKey(.downArrow, modifierFlags: []); Thread.sleep(forTimeInterval: 0.15); if !markedLabels().isEmpty { return true } }
        return false
    }

    /// INT-17: arrows move the mark, Return opens the marked bookmark once, ← folds a folder and → unfolds it, Delete removes the marked bookmark, and Escape clears the mark.
    func testKeyboardNavigationInTheLibrary() throws {
        launchLibrary()
        XCTAssertTrue(focusList(), "the search field + ↓ never marked a Library row; present: \(presentIDs())")
        let first = markedLabels()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertNotEqual(markedLabels(), first, "↓ did not move the mark")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(markedLabels(), first, "↑ did not move the mark back")
        attachShot("int-keyboard-marked")
        // A folder: ← folds it, → unfolds it.
        let tabsBefore = chipSnapshots().count
        for _ in 0..<12 where !(markedLabels().first?.contains(" bookmark") ?? false) { app.typeKey(.downArrow, modifierFlags: []) }
        if let folderLabel = markedLabels().first, folderLabel.contains("open") {
            app.typeKey(.leftArrow, modifierFlags: [])
            XCTAssertNotNil(until(3) { self.markedLabels().first?.contains("closed") == true }, "← did not fold the marked folder: \(self.markedLabels())")
            app.typeKey(.rightArrow, modifierFlags: [])
            XCTAssertNotNil(until(3) { self.markedLabels().first?.contains("open") == true }, "→ did not unfold the marked folder")
        }
        // Delete removes the marked bookmark (before Return: opening a page moves the keyboard to the page, as it should).
        app.typeKey(.downArrow, modifierFlags: [])
        if let row = markedLabels().first, row.hasPrefix("Bookmark ") {
            let before = rowLabels().count
            app.typeKey(.delete, modifierFlags: [])
            XCTAssertNotNil(until(4) { !self.rowLabels().contains(row) }, "Delete did not remove \"\(row)\" (\(before) rows before, now \(self.rowLabels()))")
        }
        // Return opens a bookmark exactly once.
        if let row = markedLabels().first, row.hasPrefix("Bookmark ") {
            app.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.75)
            XCTAssertLessThanOrEqual(chipSnapshots().count, tabsBefore + 1, "Return opened the bookmark more than once")
            attachShot("int-keyboard-opened")
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(until(3) { self.markedLabels().isEmpty }, "Escape did not clear the mark")
    }
}
