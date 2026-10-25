# How windows and tabs behave

One rule underneath all of it: **a window exists only because the person (or the app, on their behalf) asked for one.** A window the system makes by
itself is closed again before it is ever seen, and whatever it was made for is passed to the window in front.

| Action | What happens | Same as |
|---|---|---|
| Click a link that opens elsewhere (`target=_blank`), middle-click, ⌘-click | A new tab in the same window | Safari, Chrome |
| A page opens a sign-in or payment box with `window.open` after a click | A tab joined to the page that opened it; when it closes itself, the page comes back to the front | Safari, Chrome (which use a small window) |
| A page opens a box with no click | Blocked, with a pill to allow it once or for the site | Safari, Chrome |
| **A link opened from another app** (Mail, a chat, the Claude app, the Terminal) | **A new tab in the window in front. Never a new window.** If the app is not running it starts, restores its windows and opens the link as a tab in the first one | Safari, Chrome |
| ⌘N, File › New Window | One new window with one blank tab | everywhere |
| ⌘T | A new tab in the window in front | everywhere |
| Move Tab to New Window, or drag a tab out | One new window holding just that tab; the old window closes if it was its last | Safari, Chrome |
| New Guest Window | One window of private tabs; nothing kept | Chrome |
| Close a window | Its tabs close with it; Reopen Closed Window brings it back with its pages | Safari |
| Click the Dock icon when no window is open | One window | everywhere |
| Quit and open again | The same windows come back, each with its own tabs, **once**. At most 8 extra windows. No blank extra windows | Safari (Reopen windows) |

## Why the old behaviour was wrong

* The Mac app is a default browser, so every link another app opens reaches it as an "open URL" event. SwiftUI answers such an event by **making a
  new window for it**. That window started with its own blank tab, and the link then opened as a second tab beside it: a window holding "New Tab" and the
  sign-in page.
* macOS also remembers every open window and brings it back at the next start, on top of the app bringing back its own windows. Every start therefore
  opened the windows twice, and the windows the system brought back saved their blank state over the real list. The count grew at every restart.

## How it is done

* `WindowRegistry.requestWindow()` is called wherever the app opens a window on purpose. `claimRequest()` runs as a window appears; a window that finds no
  request is marked `isUnrequestedWindow`: it is kept invisible, given no blank tab, handed over the link, and closed.
* `handleExternal` sends a link to `WindowRegistry.externalTarget()`: the window in front, else the first window, never a guest window.
* The same link reaching two windows is acted on once (within 1.5 seconds).
* The system's own window restoration is off (`ApplePersistenceIgnoreState`, `isRestorable = false`, its saved-state folder deleted at start).
* The saved window list is only written after the first window has read it, and not while windows are still coming back.
* While the app quits, windows closing are not "the person closed this window", so nothing they held is forgotten.

Not yet checked by running the app: the SwiftUI behaviour above is described from how the code reads. See the checklist in the build 19 notes.


# Tabs

What the major browsers do, taken from Chromium's own source (`TabStripModelOrderController`) and Firefox's documented preferences
(`browser.tabs.insertRelatedAfterCurrent`, `browser.tabs.selectOwnerOnClose`), and Apple's Safari guide where it says anything. Browser Setu now does the same.

| Action | Rule | Now |
|---|---|---|
| **New tab** (⌘T, a typed address, a link from another app) | At the end of the strip | yes |
| **A tab opened from a page** (a link, ⌘-click, a script) in front | Straight after the tab that opened it | **was: at the end. Now: next to its opener** |
| The same in the background | After the tabs that page already opened, so several keep the order they were opened in | **new** |
| New tabs and **pinned** tabs | Pinned tabs stay first; nothing is inserted among them | yes |
| **Close the selected tab** | The tab that slides into its place (the one on its right); if it was last, the one on its left | **was: a position from the full list used on the visible one, which picked the wrong tab with other workspaces or groups open. Fixed** |
| Close a tab opened from another, before looking at anything else | Back to the tab that opened it | **new** |
| Look at any other tab first | That "back to the opener" is forgotten (Chromium: "to avoid confusing close sequences") | **new** |
| Next / previous tab (⇧⌘] and ⇧⌘[) | In strip order, wrapping around at the ends. Control-Tab is not bound in Browser Setu; Safari and Chrome use it too | partly |
| ⌘1 to ⌘8, ⌘9 | The 1st to 8th tab; ⌘9 the last tab | yes |
| Close the last tab | The window closes (a Mac browser's way); the first window of this app keeps one blank tab instead | unchanged |
| Reopen Closed Tab | The most recent first | yes |

Sources: [Chromium tab_strip_model.cc](https://chromium.googlesource.com/chromium/src/+/c991adfd9/chrome/browser/ui/tabs/tab_strip_model.cc),
[Chromium tab_strip_model_order_controller.cc](https://chromium.googlesource.com/chromium/src.git/+/69.0.3453.6/chrome/browser/ui/tabs/tab_strip_model_order_controller.cc),
[Apple: use tabs for webpages in Safari](https://support.apple.com/guide/safari/use-tabs-for-webpages-sfri11576/mac),
[MDN: window.open()](https://developer.mozilla.org/en-US/docs/Web/API/Window/open).

## Pop-ups (`window.open`)

By the web standard a `window.open` call with size or "no toolbar" features is a **pop-up window**, and one without them is a **tab**. Chrome and Safari open a
small window for the first kind and a tab for the second. Browser Setu opens **both as tabs** joined to the page that opened them, so a sign-in box can
still talk back to its page, and when the box closes itself the page comes back to the front. This is a deliberate difference: a tab is easier to find,
cannot hide behind the main window and cannot be mistaken for the page you were on.

---

# Testing notes

* **Leaked web-process helpers can make tests fail for no code reason.** WebKit gives each app a limited number of web-content processes. A test run that is stopped
  by force (a killed `xcodebuild`, a crashed test host) leaves its empty helper processes behind, and after a few such runs a new run starts to fail:
  page loads time out, "hundreds of tabs" tests take minutes, and the log fills with `ExceededProcessCountLimit`. Seven tests failed this way in one review
  and all passed (the 300-tab restart in 12 seconds instead of 284) once the leftovers were cleared. Before trusting a failing page-load test, run
  `pgrep -f com.apple.WebKit.WebContent | wc -l`; if it is in the hundreds with no app open, `pkill -KILL -f com.apple.WebKit.WebContent`.
* **The keyboard-driven UI tests need an idle Mac** (`scripts/run-ui-tests-when-idle.sh`). Twenty-one of them fail ("address bar not found", "multiple matching
  menu items") on this Mac, and they fail the same way at the commit from before the window and tab work, so they are not caused by it. They have not been
  made to pass and are not a reason to trust or distrust a change.
