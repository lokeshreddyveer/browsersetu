# macOS layouts

Every layout Browser Setu offers on the Mac, what it is made of, and where it lives in the code. All of them share one tab list, one session, one set of WebViews and one settings store; a layout only decides where the existing pieces are drawn. Switching layouts never navigates, reloads or replaces a tab.

The design source pack (`BrowserSetu_Master_Design_Source_Pack_v2`, doc 04) describes eight curated experiences plus Minimal and Custom. The app has twelve presets: those ten (One Row is `inline` in code) and the two Reversed variants, which were built before the pack and are not described in it.

| Preset (`LayoutPreset`) | Title | Family | Navigation and address | Tabs | Sidebar |
|---|---|---|---|---|---|
| `classic` | Classic | Everyday | Top toolbar | Strip under the toolbar | Library only |
| `classicReversed` | Classic Reversed | Everyday | Top toolbar | Strip above the toolbar | Library only |
| `minimal` | Minimal | Everyday | Top toolbar | Compact strip under the toolbar | Library only |
| `minimalReversed` | Minimal Reversed | Everyday | Top toolbar | Compact strip above the toolbar | Library only |
| `inline` | One Row | Everyday | Active tab is the address field | Same row | Library only |
| `sidebar` | Sidebar | Organized | In the sidebar header | Sidebar | Docked, hide to edge, rail |
| `hybrid` | Hybrid | Organized | Top toolbar over the page column | Sidebar | Docked, hide to edge, rail |
| `floating` | Floating | Immersive | Floating pill | Sidebar from the window edge | Edge reveal |
| `canvas` | Canvas | Immersive | ⌘L or the handle | ⇧⌘A (tab overview) | None |
| `researchDesk` | Research Desk | Productivity | Top toolbar, acts on the focused panel | Compact rail (expandable) | Rail |
| `workspaceDeck` | Workspace Deck | Productivity | Top toolbar | Sidebar, under a list of every workspace | Docked |
| `custom` | Custom | Advanced | Chosen | Chosen | Chosen |

## The two Reversed layouts (not in the design pack)

Classic Reversed and Minimal Reversed are Classic and Minimal with the tab strip above the toolbar. They share everything else with their originals. Tabs drawn in the title-bar band hold the window still while the pointer is over a tab (`TitleBarTabHold`), so a tab can be dragged without dragging the window. They are left out of the first-run gallery and the double-click layout cycle; they are in Settings, the toolbar context menu and the command palette.

## The four layouts added from the design pack

**Hybrid** (`hybrid`): the Sidebar layout's panel (`SidebarLayoutPanel` with `hybrid: true`) beside the page, under the full toolbar (`MainColumn`'s `TopBar`). There is no address field in the sidebar. The toolbar's own sidebar and workspace buttons are left out while the sidebar carries them (`showsOnToolbar`), and come back when it is hidden. The sidebar hides to the window edge and docks again exactly as in the Sidebar layout (`usesSidebarPin`). It is the same composition as Custom with vertical tabs and a separate toolbar, now named.

**Canvas** (`canvas`): no toolbar, no pill and no sidebar at the edge (`peekEnabled` and `LayoutState` exclude it). A small handle at the top (`CanvasHandle`) stays faint (32 % opacity) until the pointer is near; its menu has the address, the open tabs, a new tab, Bookmarks, History, Downloads, Settings and Leave Canvas. ⌘L opens Floating's address field; ⇧⌘A shows the tab overview (the search panel needs a sidebar, which Canvas does not have). Leave Canvas returns to the layout it was entered from (`layoutBeforeCanvas`, Classic if unknown).

**Research Desk** (`researchDesk`): the existing split view (`ContentPanels`, `SplitLayout`, `SplitControls`) with the tabs as a compact rail. Choosing it pairs the tab in front with the next tab (`openResearchSplitIfPossible`); with one tab it opens nothing, and pairs as soon as a second tab exists (`deskSplitPending`). Each panel is a card with a header (favicon, title, site, a lock or private mark) and a close button that takes the page out of the split while keeping its tab (`ResearchPanelHeader`, `removeFromSplit`); its menu can show another open tab there (`replaceSplitPanel`), swap, or change direction. ⌃⌘] moves the focus to the next panel (`focusNextPanel`); dividers resize by drag, double-click to equalise, or VoiceOver's adjust action. In a window too narrow for two pages side by side, the focused page is shown alone with a switcher for the others; no page is closed or reloaded. Clicking a panel focuses it and the toolbar acts on it (the focused panel is the active tab). The rail choice it replaced is given back when another layout is chosen; the split is kept.

**Workspace Deck** (`workspaceDeck`): the Hybrid composition with every workspace listed at the top of the sidebar (`WorkspaceDeckList`) instead of the compact selector. The heading has Add, Find and Manage; the list is bounded (fewer rows in a short window) and scrolls, with a search field from nine workspaces on. Rows show the icon, the name, a count of the tabs the list shows, and a check mark on the open one; arrow keys move between them, Return or Space opens one, Option-arrows reorder, and a tab dropped on a row moves there. A labelled Profile row sits apart from the workspaces (a workspace is not a profile). "Name · Tabs" heads the selected workspace's Essentials, pins, groups and tabs. Choosing a row calls `switchWorkspace` (the first visible tab is selected, as before) and never changes the profile or the data store; a workspace's remembered layout does not take the window out of the Deck. Next and Previous Workspace are in the Workspace menu (⌃⇧⌘] and ⌃⇧⌘[). The overview is titled with the workspace.

## Shared rules that apply to every layout

- Full screen keeps the layout's own toolbar and tabs (`LayoutRules.autoHidesToolbar`); only Custom's auto-hide option hides the toolbar. ⌃⌘F is routed to the browser window itself (`BrowserFullScreen`).
- The vertical navigator (Sidebar, Hybrid, Workspace Deck): the workspace selector, tab search and Essentials stay fixed; pinned tabs, open tabs and groups scroll together. Essentials take one row when there are few, at most two (one in a panel under 520 pt), and scroll inside themselves beyond that.
- Tab clicks, menus, drag and drop, hover previews and keyboard behaviour come from one shared modifier (`tabInteractions`) in every layout.
