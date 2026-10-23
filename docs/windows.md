# How windows behave

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
