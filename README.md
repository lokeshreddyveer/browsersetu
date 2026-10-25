# Browser Setu

A native, security-first web browser for **macOS** and **iPhone/iPad**. It renders with the system's own WebKit, keeps everything on your device, and
puts a small Rust core (tabs, address-bar logic, permission and navigation rules, per-profile SQLite storage) under a SwiftUI interface.

> **Status: release candidate, in the production-hardening phase (0.3.3, build 20).** It is a real, working browser with a large automated test suite (about 750 tests), but
> it is **not yet called production grade**: that needs the evidence in [`docs/RELEASE-BAR.md`](docs/RELEASE-BAR.md) to be complete and recorded. [`docs/capabilities.md`](docs/capabilities.md)
> lists every feature as *Checked*, *Built* (compiled, not exercised end to end) or *Parked* (switched off), with the evidence and the limits. Read both before you rely on anything.

## Download

- **Mac (Apple Silicon, macOS 14 or later):** the notarized DMG on the [Releases](../../releases) page. The downloadable build updates itself (see
  [Updates](#updates)).
- **iPhone and iPad (iOS 17 or later):** TestFlight. Ask the author for an invitation.

### Coming from another browser

| Bring over | From | How |
|---|---|---|
| Bookmarks | any browser that exports bookmarks as an HTML file (Safari, Chrome, Edge, Brave and Firefox all do) | Settings › Bookmarks › Import Bookmarks… |
| Passwords | Chrome, Firefox, Apple Passwords, Safari | the CSV file each one exports, in Settings › Passwords › Import Passwords…; insecure (plain http) entries are skipped and duplicates are not added twice |
| History | Chrome (the "Browser History" file from Google Takeout), Safari (File › Export Browsing History) | Settings › Passwords › Import History… |
| Extensions | Chrome Web Store | add by address; Manifest V3 extensions run where WebKit supports them (see Extensions) |

Nothing is read from another browser's folders: you hand over the files yourself. This is only what the app does today; Firefox history, and Arc's own tabs and Spaces, are not imported.

There is no Windows, Linux or Android version.

## What you get

Everything below is in the app today. Each part says what it does and how it works. Where something is untested or limited, it says so; the full ledger, with
the evidence for each item, is [`docs/capabilities.md`](docs/capabilities.md). Mac-only and iPhone-only parts are marked.

**Contents:** [First minutes](#first-minutes) · [Layouts, windows and tabs](#layouts-windows-and-tabs) · [Address bar, search and commands](#address-bar-search-and-commands) ·
[Keyboard shortcuts](#keyboard-shortcuts) · [Privacy and security](#privacy-and-security) · [Passwords](#passwords) · [Extensions](#extensions) ·
[Reading, research and page tools](#reading-research-and-page-tools) · [Downloads, PDFs and documents](#downloads-pdfs-and-documents) · [Developer tools and automation](#developer-tools-and-automation) ·
[Themes, start page and settings](#themes-start-page-and-settings) · [Accessibility](#accessibility) · [Sync, backup and other devices](#sync-backup-and-other-devices) · [iPhone and iPad](#iphone-and-ipad)

### First minutes

0. **First launch asks a few questions** (a one-minute setup): the look and theme, the layout, your search engine, which protections you want, and whether to offer to save passwords. Every answer applies at once and can be changed later; "Run Setup Again" is in the command palette.
1. **Open it.** A blank tab shows the start page: a search field, your favorites, a card to carry on where you were, and places you go often. Type to search or enter an address.
2. **Press ⌘K** for the command palette. Almost everything in this list is a command there, so you never have to remember where a thing lives.
3. **Choose a look** in Settings › Appearance: a layout (Classic, Sidebar, Minimal, Floating, One Row), a theme, and the buttons you want in the toolbar. **⌥⇧⌘0** always restores the standard layout.
4. **Privacy is on from the first page.** Ads and trackers are blocked, links are cleaned, plain-HTTP addresses are upgraded, and nothing leaves the device unless the [table below](#what-leaves-your-device) says so.

### Layouts, windows and tabs

- **Layouts (Mac).** Classic (tabs across the top, standard toolbar), Sidebar (tabs down the side, address bar in the sidebar), Minimal (one slim tab row), Floating (no bar: a pill shows
  the site, a search button opens the address bar, tabs slide in from the edge), One Row (tabs as icons beside the address field) and Custom. Each is a preset over a few switches
  (sidebar side, rail, auto-hide, single toolbar), so you can also set them one by one. A small handle appears whenever something essential would otherwise only show at a window edge.
- **Toolbar buttons (Mac).** In Classic, Minimal and One Row you choose the buttons in Settings › Appearance › Toolbar: sidebar, back and forward, reload, share, bookmark, new tab, tab overview,
  downloads, **workspaces**, **profile**, **split view**, history, bookmarks, find and the command palette. The bar fits as many as the window is wide and drops the optional ones in a fixed order;
  the More menu always has the rest.
- **Tabs.** Pinned tabs, groups with colours, drag to reorder, close with a middle click, tab overview with search and sorting, session restore with lazy loading, and Reopen Closed Tab.
  Give any tab a name, a colour or a note; see which tab opened which in a tree; group all tabs by website; find and close duplicates; open a **scratch tab** that keeps no history and
  leaves nothing behind.
- **Workspaces.** Switch whole sets of tabs (Work, Research, Personal…) with the workspace button, the Workspace menu or the sidebar. Each workspace can have its own accent colour,
  its own layout (applied when you open it) and, if you like, its own set of extensions. Deleting one moves its tabs to Personal. Settings › Tabs lists them as rows with swatches.
- **Several windows (Mac).** ⌘N opens another window; each has its own tabs, layout and workspace and they are all brought back at the next start. Right-click a tab › Move to Window, or **drag a tab
  from one window's tab bar or sidebar onto another's**: it moves with its page, history and place, and a window left with no tabs closes. **File › New Guest Window** (⌥⇧⌘N) opens private tabs only,
  keeps nothing and is not restored.
- **A link from another app opens as a tab, never a new window (Mac).** Click a link in Mail, a chat or the Claude app and it opens as a new tab in the window in front; if Browser Setu is not running it starts and opens the link as a tab in the first window. A window exists only because you (or the app on your behalf) asked for one, so there is no stray window holding a blank "New Tab" beside your link. At the next start your windows come back **once**, each with its own tabs, at most eight extra. The full list of how each action behaves is in [docs/windows.md](docs/windows.md).
- **Tabs open and close the way other browsers do.** A tab opened from a page (a link, ⌘-click, a script) sits right next to the tab that opened it, several background tabs keep the order they were opened in, and a New Tab goes to the end. Pinned tabs always stay first. Closing the selected tab brings forward the tab on its right (the one on its left if it was last), or the tab it was opened from if you have not looked at anything else since. The rules, with their sources, are in [docs/windows.md](docs/windows.md).
- **Split view (Mac).** Two to four pages in one window: two share it **exactly 50-50**, three are one tall page with two stacked beside it, four are a **2×2 grid**; or stack them instead of side by side.
  Start it from the Split View button in the toolbar, the Split View menu, the More menu, or right-click a tab › Open in Split View (then Add to Split View as a Panel). Drag the divider between two panels
  to resize them (double-click it to make them equal again), click a panel to make it the active one, swap panels or close the split from the same places. Every page in a panel stays loaded and is
  never put to sleep. Save the pair as a template to reopen it later.
- **Right-click everywhere (Mac).** The sidebar (also when it hides at the edge), the toolbar, the tab strip, a new tab page and a link on a page each have a menu of their own: new tab, private tab, search tabs, new group or workspace,
  which sidebar section to show, its side, collapse to icons, auto-hide, layout, density, Break, Page Actions, and for a link **Open in New Tab, Background Tab, Split View or Private Tab**. Settings › Tabs › Right-Click Menus switches any item off.
- **Customize the buttons by dragging (Mac).** Right-click the row of buttons at the foot of the sidebar › Customize Buttons: the row becomes editable in place, with a tray of the others above it. Drag one in, along the row to reorder it,
  or out to remove it. 18 are available (History, Downloads, Bookmarks, Reading List, New Tab, Find, Command Palette, Break, Split View, Timeline, Saved Sessions, Privacy Dashboard, Settings, Profile…); seven fit in the row, the rest sit under "…".
  The buttons inside the address bar are arranged the same way (right-click the bar › Arrange Buttons).
- **Tab tree, stacks and previews.** Turn on the tab tree and a tab opened from a link sits under its parent, with an arrow that folds the branch; closing a parent moves its tabs up a level. Stacks put one website's tabs together in the
  sidebar, with a count that folds them. Rest the pointer on a tab for a preview card.
- **Web panels.** Add a small https site (chat, notes, music) in Settings › Tabs; its icon sits in the sidebar footer and opens it as a card over the page's edge, with the browser's own protections (it is a hidden tab). One button turns it into a tab.
- **Settings as a panel or a tab.** A switch in the Settings header chooses: its own window, or a tab with a gear in the tab list. It remembers your choice, including for ⌘, and the menu bar.
- **Drag and drop.** A tab you drag shows a small glass card with its site, and the tab it will land before lights up. Drop a link on a tab to open it. Drag a tab to another window and it moves with its page.
- **Focus mode** drops the toolbar and card for an edge-to-edge page.
- **Memory.** Tabs you are not using give their memory back in Balanced, Saver or Performance mode, and the app tells you which tabs are asleep and why. A **never-sleep list** keeps chosen sites awake;
  **Put all other tabs to sleep** respects it. A sleeping tab keeps its title, address, history and scroll position and reloads when you open it.
- **Saved sessions** keep the tabs, their pinned state, each page's place in it and the workspace; open one with `/open` or from the Library menu.
- **Containers** keep one site's cookies and logins apart from the rest inside a profile, **profiles** keep everything apart, and **site rules** open a site where you want it (a private tab, a container,
  a group or a workspace) before it loads.

### Address bar, search and commands

- **One bar for everything.** It suggests from your own open tabs, bookmarks and history first (computed on the device), then page text you chose to keep a searchable copy of, then your search engine
  (suggestions are off until you turn them on). The search-engine menu sits in the bar; add your own engine, and search shortcuts such as `g cats` or `yt cats` use one engine for one search.
- **Finishes addresses as you type (Mac).** Type `git` and, if you have been to GitHub, `github.com` appears with the rest selected: Return goes there, any other key replaces it, Delete removes it. It completes only the start of a
  site you visited or bookmarked, and never once you have typed a space, a path or `https://`. (The iPhone and iPad fields cannot show a selected ending, so they suggest in the list instead.)
- **Search inside one website.** Search This Site… (command palette, Library menu, or the ⋮ menu on a phone) asks what to look for and searches only the site in front, using your search engine's `site:` search.
- **Drop it on the window.** A link, a file or some text from another app, dropped on the window, opens: a web link in a new tab, a file as a document (a PDF in the editor, anything else in the previewer), text as a
  search or an address. Dropped over the page itself, the page gets it first (so file uploads on websites still work); drop on the toolbar, the sidebar or the start page.
- **Reopen Closed Window** (File menu, Mac) brings back the last extra window you closed, with its pages. The last five are kept for this run of the browser; private tabs and guest windows are never kept.
- **Pages behind and ahead.** Right-click (Mac) or press and hold (iPhone, iPad) Back or Forward to see the pages behind or ahead of this one, up to fifteen each way, and jump straight to one.
- **Answers.** Type a sum (`12 * (3 + 4)`, `15% of 80`, `sqrt(2)`) or a conversion (`5 km to miles`, `72 f in c`, `1 gb to mb`) and the answer appears under the first row; Return copies it. Worked out on the device, no currency.
- **Slash commands.** `/tabs`, `/close`, `/find`, `/group`, `/sleep`, `/duplicates`, `/save`, `/open`, `/workspace`, `/forget`, `/private`, `/scratch`, `/note`, `/split`, `/restore`: type a slash to see them, each
  explained as you type. Nothing runs until you press Return.
- **Search across all open tabs** (⇧⌘F, or `/find`) reads the text of every loaded page and finds tabs that are asleep through the saved copy of pages you read. It **forgives typos**
  ("kuberntes cluser" finds "Kubernetes cluster"), lists exact matches first and marks close ones "similar", and switching to a result finds the words in the page.
- **Command palette (⌘K).** Every command, every open tab, bookmarks and settings in one list; type `>` in the address bar for the same. **Workbench › Search** searches tabs, bookmarks, history,
  downloads, research and notes together.
- **Vim keys (optional).** j, k, gg, G, H, L and more, with an editable keymap. They act only when no text field has the keyboard.
- **Mouse gestures (Mac, off by default).** Hold the middle button and drag: left is back, right forward, down a new tab, down then right close, up scrolls to the top, and so on. The map is editable in Settings › Advanced.
  A middle click that does not move still opens a link in a new tab.
- **Selection actions.** Select words and search them with any engine from the command palette or Selection Actions…, which also shows details found in the selected text.

- **Address bar sources and buttons.** Settings › Search › Address Bar Results chooses which results show under the bar (search suggestions, open tabs, bookmarks, history, saved pages, commands) and in what order;
  "Go to…" and "Search for…" always stay first. **Command chains** (Settings › Advanced) run several palette commands as one, and show up in the palette. **Break** pauses all media in every tab at once.

### Keyboard shortcuts

Every one can be changed in Settings › Shortcuts. The defaults:

| | |
|---|---|
| New tab / private tab / close / reopen | ⌘T / ⇧⌘N / ⌘W / ⇧⌘T |
| Open location / command palette / paste and go | ⌘L / ⌘K / ⇧⌘V |
| Back / forward / reload / stop | ⌘[ / ⌘] / ⌘R / ⌘. |
| Next / previous tab / select tab 1–9 | ⇧⌘] / ⇧⌘[ / ⌘1–⌘9 |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Find in all tabs / search tabs / tab overview | ⇧⌘F / ⇧⌘A / ⇧⌘\ |
| Bookmark / bookmarks / history / downloads | ⌘D / ⇧⌘B / ⌘Y / ⇧⌘J |
| Toggle sidebar / focus mode / restore standard layout | ⇧⌘L / ⌥⌘F / ⌥⇧⌘0 |
| Reader / share / print | ⇧⌘R / ⇧⌘S / ⌘P |
| Zoom in / out / actual size | ⌘+ / ⌘- / ⌘0 |
| New window / new guest window | ⌘N / ⌥⇧⌘N |

### Privacy and security

- **Content blocking.** Ads, trackers and session-recording scripts are blocked with WebKit's content-rule engine at three levels (Light, Balanced, Strict). A small starter list ships in the app; about 90 public
  lists are optional downloads, fetched straight from their publishers only when you press Update (or turn on automatic updates, which is off by default). WebKit does not report blocked counts, so the numbers below are estimates.
- **The shield card** (click the shield beside the address) holds the protection level, a **Blocked** count with a menu to choose what it covers (this page, today, 24 hours, 7 days, 30 days, 12 months, all time), a
  **Protections** list that says what is on and flips each switch, and **Site not working?**: pause blocking for 10 minutes, an hour or until you quit (it switches back by itself), or open Repair This Page.
  **This site…** opens switches for that one site (ads and trackers, pop-ups, autoplay, fingerprint noise, JavaScript, video speed, keeping its tab awake) and **Protection History…** shows a graph by day and the sites
  with the most blocks. **The counts are estimates:** WebKit does not report what it blocks, so a picture, script or frame that fails to load with no network record is counted as blocked, and a page that asks again counts again.
  Counts are kept on this device, per profile, in one small file; private tabs are never counted.
- **Cookie banners.** Where a consent banner has a "reject" button for a common consent tool, the browser presses it; a banner left over is hidden and scrolling is given back. Nothing is accepted for you. On by default,
  one switch in the shield card's Protections list. Tested on built banners, not yet on live sites.
- **Cleaner links and pages.** Tracking parameters are stripped from links (Copy Clean Link does the same); plain-HTTP addresses are upgraded to HTTPS; **De-AMP** sends links through Google's AMP cache to the site's
  own page, and replaces an AMP page that names its own full version.
- **No videos or sound starting by themselves (on by default).** A page can start media only after a real tap or key press (and for six seconds after one, so the page you open by tapping can start its own player), not
  while you scroll. On the iPhone a second guard checks what is playing and pauses media that started with no tap in the last six seconds, whatever the page's script does. On a phone a scroll counts as a touch to WebKit, which is how a feed such as YouTube's could start videos as you scrolled. Playlists and "Autoplay next" wait for a tap, and a site that needs to
  play by itself (a voice-chat page, say) can be allowed in Site Privacy or with Repair This Page.
- **Fingerprint randomizing (off by default).** Small, per-site changes to what canvas, WebGL read-back, audio and the processor count report, different for every site and every start, so a site cannot
  recognise this device by them. Each site has its own off switch for the few pages that draw pictures.
- **Block ads on YouTube (on by default).** The ad schedule is removed from a video's own data before the player reads it, so there is no ad to play; ad slots are hidden, and an ad that still starts is skipped, or muted and run
  to its end. The rules are plain data (names of fields and page elements, never code) and can be refreshed from this project's repository at most once a day while the switch and its update option are on (Settings › Privacy
  & Security); every name is checked and a file with anything unexpected is refused whole. YouTube changes this often, so it can stop working until the rules are updated, and it has been tested on a copy of the player's data, not yet on every live page.
- **Pop-ups.** A window a page opens by itself is blocked, with a card at the top: Open Once, Always Allow, or dismiss. A window opened by a click or a key press (a sign-in, a payment) is allowed and stays connected to the page that
  opened it, so it can finish and close itself. Settings › Websites › Pop-ups lists the sites you allowed.
- **Per-site controls.** JavaScript off for one site, never-sleep, zoom, notes, your own style sheet, a browser identity (user agent), WebRTC exceptions. A **style sheet for every website** applies CSS everywhere
  (hide a cookie banner, say), with a site's own sheet on top.
- **Private tabs** use a separate, non-persistent store: no history, no session, no saved sign-ins, no extensions, no scripts of yours, and nothing in them is read by the browser's own tools.
- **Permissions.** Camera, microphone and location are asked for per site: Allow, Allow for an Hour, Allow for This Session or Always Allow (which itself expires). A log shows who asked for what and what you
  said. Insecure pages are always refused.
- **Site privacy page** (the lock beside the address, or the command palette): what the site stored (its cookies, third-party cookies by owner, storage), its permissions, how it sees you, how safe its
  connection looks (certificate chain, redirects, mixed content), and **Forget This Site Completely**. Automatic-deletion rules clear a site when its last tab closes or at every start.
- **Who is on the other end.** The certificate is read for the organisation it names. A site whose certificate names a checked organisation shows that name beside the address (green); a certificate that only
  proves the domain says "Encrypted, owner not verified". The lock's tooltip and the site info popover say the same in full.
- **WebRTC switch** (stops pages learning this device's network address), a **proxy** for page loads (HTTP or SOCKS5; it is not a VPN), a **threat list** of hosts you import (a warning before those pages load), and a
  **download scanner** that warns about risky file types and files whose contents do not match their name.
- **Sensitive-settings lock** (Touch ID or password) in front of saved sign-ins, extension changes and similar; it refuses when the device cannot authenticate instead of opening.
- **Clear on quit**, **safe start** after repeated crashes (tabs return but none loads), an in-app **health check**, and a **privacy dashboard** that shows what is on and what was cleaned.

### Safety, daily digest and sharing

- **Tools menu.** iPhone menu, iPad ⋮ menu, the Mac menu bar and a button on the new tab page open the Daily Digest, Feeds / Tasks / Vault / Clipboard, Reading List, the privacy grade and Clear Everything Now.
- **Look-alike address warning.** Before a page opens, its address is compared with about sixty well-known sites. Swapped letters and digits (paypa1), letters from other alphabets (including addresses written as `xn--`), a name one letter off, a famous name placed in front of a different site (`paypal.com.example.net`) and bait words such as `secure-paypal-login` stop the page with a warning that names the site it imitates. You can go back or continue. It runs on the address alone, on the device; Settings › Privacy has the switch.
- **Privacy grade.** *This site…* in the shield card opens an A to F grade for the page in front, with the reasons listed: secure connection, how many other sites it loaded from, trackers stopped, permissions you gave it, and a look-alike notice. Worked out on the device from what the page just did.
- **Everything for one site in one place.** The same panel also holds zoom, the site's own light or dark look, "always open in a private tab" and the permissions you allowed there, each with a *Take Back* button.
- **Clear Everything Now** (Tools menu, command palette, and Settings › Privacy) asks once, then closes every tab including locked and private ones and erases history, the downloads list, website data, copied text and what the widgets and share sheet hold. Bookmarks, passwords and settings stay.
- **VayuSetu, for what a browser cannot do.** Settings › Privacy has a **Network protection: VayuSetu** section. VayuSetu is a separate app by the same author: a VPN client (you bring your own WireGuard or IKEv2 server), encrypted DNS and ad blocking for every app on the device, not only the browser. Browser Setu works fully without it. On a Mac the button opens the download page in a tab (or, if VayuSetu is already installed, opens the app); nothing is fetched or installed for you. The iPhone version of VayuSetu is waiting for App Review, so on iPhone the button opens its website.
- **Four lookups, each only when you press its button.** **Saved copy:** a page that will not load offers "Look for a saved copy on the Internet Archive", which asks the Archive for a copy (sending the address without its query or fragment) and opens it. **Security headers:** the site panel can ask Mozilla's HTTP Observatory to grade a site's headers (sends the site's name). **Currency:** select an amount such as "$250", "€40" or "₹1,200" and the selection actions convert it at the European Central Bank's rate (sends only the currency codes; "$" is read as US dollars). **Citation from DOI:** Tools › Copy Citation from DOI finds the paper's DOI and copies the exact APA, MLA or plain reference from Crossref. None of them runs by itself, none sends a cookie or a referrer, and an address on a private network is never sent.
- **Daily Digest** (Tools menu, or the command palette): your unread reading list, the newest feed items, open tasks, today's time on sites and the blocked count, in one list.
- **Automatic switching.** Settings › Tabs (Mac), under Workspaces, takes time rules, such as weekdays 9 to 17 in the Work workspace. A rule is applied once as its time begins; a switch you make by hand afterwards is left alone.
- **Ask in plain words.** Type something like `pasta recipe last week` or `bank 3 days ago` in the command palette and the pages from your history that fit appear first. Worked out on the device.
- **Tab groups travel.** The tab list from another device now carries each tab's group; one tap opens a whole group here.
- **Sleeping tabs say so.** A tab put to sleep shows a moon, and its tooltip gives the reason.
- **AI features switch.** Settings › AI has one switch, **AI features**, that turns off everything AI-related: the on-device page summaries, Ask This Page and the AI-tool connection below. It is on by default for the on-device features and the tool connection is off by default.
- **Use Browser Setu from an AI tool or a script (downloadable Mac build only).** Settings › AI › *Let AI tools use shared tabs* opens a connection on this Mac's own loopback address (127.0.0.1, behind a secret token) that speaks the Model Context Protocol, the open standard Claude Code, Claude Desktop, Gemini CLI, Codex and Cursor use for tools. *Copy Setup For…* gives the exact line or settings snippet for each. The AI panel is in Settings (Mac sidebar, under Browser). The `scripts/bsetu` shell script talks to the same connection (`bsetu tabs`, `read`, `click`, `type`, …). ChatGPT's own app cannot reach a local address, so it is not supported directly.
  The rules are enforced in the browser, not left to the AI tool: it sees only tabs you **share** (Tools › Share This Tab with AI Tools) or that it opened itself, never private tabs; what is typed into a field is never read; addresses are shown without their query or fragment; a tab is read only while it is on a website you allowed, and a link to another site needs that site allowed; clicking and typing need you to allow the exact site (scheme, host and port) for the session, and **most buttons and most typing ask you every time**, while sending, paying, posting and deleting always do; password, card and one-time-code fields are never typed into; card numbers, US social security numbers and IBANs are masked in page text (names, email addresses, street addresses, birth dates and other account numbers are **not**); page text is handed over labelled as untrusted; every link asks first unless you switch that off in Settings › AI; Return asks except in a plain search box; what a tool typed is never written to the log. **Stop AI Tools** cuts every connection and forgets what was shared; *Make a New Token* ends the old token at once; every action is in a log in Settings.
  **Limit to understand:** the AI tool you connect usually sends what it reads to its own company's servers, which Browser Setu cannot see or control. The app says so before the feature is turned on and before the first tab is shared. It has been tested with a script and a socket test (`scripts/test-agent-server.sh`), not yet with a real AI tool in daily use, and it is not available on iPhone or iPad or in the App Store build.
- **Share into Browser Setu.** iPhone and iPad: *Browser Setu* in the share sheet opens a link, saves it to the reading list or sends it to your other devices. Mac: *Browser Setu* in the Share menu of Safari and other apps (App Store build). Both hand over only the web address.

### Passwords

- **Save and fill.** After you sign in, the browser offers to keep the password in your Keychain, for this profile. It notices a sign-in sent by the form, by Enter, by a button or by the page's own script, including a sign-in
  box that is a page from another site inside the page (App Store Connect's and Google's are). As soon as you type a password a small "Save password?" card also appears, so a sign-in nothing noticed can still be kept with one click.
  Filling asks for Touch ID or your password, happens on the exact site, never over plain HTTP and never in a private tab; clicking into a password field offers your saved sign-in. Pages cannot send the browser anything but those
  two moments.
- **Keep passwords in iCloud Keychain (Settings › Websites).** Moves your saved passwords into iCloud Keychain, which Apple seals end to end, so they appear on your other Apple devices with the same Apple Account. If this copy of the
  app cannot use iCloud Keychain it says so and keeps them on the device. **Not yet checked between two real devices.** A backup can also include them (tick the box when you export; the file is sealed with your passphrase).
- **Check Passwords for Leaks** (Settings › Websites › Saved Sign-ins, behind Touch ID): each password is hashed on the device and only the first five characters of the hash go to haveibeenpwned.com, so no
  password, whole hash, site or user name leaves. It also flags a password used on more than one site. Nothing is stored from the answer.
- **Sign-in boxes** that websites show (HTTP authentication) are remembered per site, realm and method.
- **Import** passwords and history from Chrome, Firefox, Apple's Passwords and Safari (their exported files).
- **Limits.** Browser Setu cannot use Safari's own saved passwords or its save prompt in a web view (Apple does not allow it for other browsers), and there are **no passkeys yet** (Apple must grant browsers the permission). A password manager's
  extension (Bitwarden, 1Password) is the other way, where its extension works in WebKit.

### Extensions

- Web extensions through WebKit's own support (macOS 15.4 or later, and iOS 18.4 or later). Add from a folder, a `.crx` or `.zip`, or a Chrome Web Store address. Every install shows what the extension
  asks for, warns about what Apple's support does not offer, and installs from a private copy that is hashed before and after, so what you approved is what runs.
- A permissions screen per extension: switch any permission off, restrict to "on click", specific sites or all sites, and see a history of changes. Per-site allow and block rules; pin extensions to the toolbar.
- Tools: conflict detection (shortcuts, request blocking, restyling, new-tab pages), presets (Cautious, Balanced, Open), what changed in the last update, go back to the previous version, per-workspace extension sets,
  a throwaway-profile load test with a score, and a backup of the installed files.
- **Limits.** VPN and privacy-API extensions cannot work (WebKit has no proxy or privacy APIs). Native messaging (password managers' helper programs) is written but switched off until Chrome package signatures are
  verified. Real Dark Reader, uBlock Origin Lite, Vimium and Bitwarden/1Password packages were fetched for a compatibility report ([`docs/extension-compatibility.md`](docs/extension-compatibility.md)): "loads" is not "works",
  and password managers have not been tried end to end. On iPhone only one sample extension was tried.

### Reading, research and page tools

- **Video speed and picture-in-picture.** Choose 0.5× to 2× from the command palette, the Library menu (Mac) or the ⋮ menu (iPhone, iPad); the speed is remembered for that site and put on every video it shows, including ones that
  appear later. Picture in Picture opens the biggest video in a floating window (not tested on a real video).
- **Summarize This Page.** A few lines written by the language model that is part of macOS 26 and iOS 26, on this device (Apple Intelligence). The page text is never sent anywhere. Where a device cannot run the model, the sheet says why.

- **Reader** (⇧⌘R) for clean text, a **reading list** with offline copies, highlights and page notes, and "restore what I was typing" for forms.
- **Research collections.** Save pages, highlights (each with a citation: title, address, author, dates), notes and PDFs; save an **offline PDF copy** of a page; add a note anchored to a selected passage and jump back to it;
  export to Markdown, HTML or PDF; copy a citation as plain text.
- **Page Tools** (Library › Page Tools): **Images** (save, copy), **Tables** (export as CSV), **Documents** (links to files), **Outline** (jump to a heading), **Details** (dates, phone numbers, addresses found
  in the text, with a system detector), **Video** (speed, Picture in Picture, full screen), **Text**, **Versions** and **Listen** (the page read aloud with the system voice, following along on screen).
- **Page versions and price watch.** Keep a page's text and see what changed on your next visit, with price-drop detection and scheduled checks.
- **Search My Pages.** Optionally keep a searchable copy of the pages you read (on the device, never from private tabs); it feeds the address bar and the all-tabs search.
- **Shopping.** Compare products, keep coupons, and track subscriptions with the monthly and yearly cost.
- **Also:** text from pictures (Vision, on device), translate a page on the device, a QR code for a page, Repair This Page (infinite-scroll and broken-layout helpers), remember where you stopped reading, and Request Mobile Website.

### Downloads, PDFs and documents

- **Library panels.** Bookmarks, History and Downloads share one design: a heading with a count, a search field, filter chips with counts (Favorites and Tagged; Today to All; Documents, Images, Media, Archives, Apps), sections as
  cards that fold, rows that light up under the pointer, and a proper empty state. Downloads shows progress rings, a queue bar (pause all, hold until a time) and Resume for interrupted files; History clears the last hour, today or everything.
- **Short messages** ("Filled in.", "Password saved.") appear as a card that fades by itself, not a box to click away.
- **Downloads you can see.** A card at the foot of the window shows progress while a file downloads, the Downloads button fills a ring and the Dock icon shows the percentage; when it finishes a card says
  "Downloaded" with Show in Finder and All Downloads (a file that can run code carries its warning in the same card instead of a box you have to dismiss).
- **Download details.** Each running download shows size, speed and time left ("48 of 78 MB · 6.1 MB/s · about 5 s left"). A finished file has **Copy SHA-256** and **Verify Checksum…** (paste the hash the site published; the answer says match or no match).
  A warning appears before a download that would not fit in the free disk space, a banner tells you when one finishes while the app is in the background (Settings, can be turned off), downloads can be sorted into a folder per website,
  and "Copy Download Diagnostics" in the Downloads panel copies the folder, free space, queue and recent events for a bug report.
- **Security events.** The Privacy dashboard lists what Browser Setu did to keep you safe (pop-ups stopped, a page that bounced through four or more different sites, risky file types downloaded, blocking paused for a site), newest first, next to the permission log. Private tabs are not recorded.
- **Extensions, safer.** The approval sheet adds a red "Be careful" list for broad access (every website, cookies, history, downloads, network requests). **Relaunch Without Extensions** (File menu), holding Option while opening the app, or the `-BrowserSetuNoExtensions YES` launch argument starts with all extensions off to find one that breaks pages.
- **Already there:** WebKit's own fraudulent-site warning (on by default) and macOS file quarantine for downloads (`LSFileQuarantineEnabled` on the Mac app).
- **Tabs, more.** A speaker shows on a tab that is playing sound (click it to mute; the page's players stay silent after reloads; sound made through Web Audio is not covered). Tabs can be sorted by website, title or last use (pinned stay first),
  snoozed (an hour, this evening, tomorrow, next Monday) or scheduled to open again daily, on weekdays or weekly (they open while the app runs, or at the next launch). Groups nest ("Work/Project A" via New Subgroup…), fold, and can be searched;
  a group can be saved as a session. Idle groups (unused 30 minutes) can be put to sleep, pinned tabs ask before closing (a setting), and the tab search (/tabs) finds tabs in other windows and brings them over.
  Not built: a per-tab memory number (the system does not report one; the Resources view shows awake or asleep and last use instead) and automatic detection of tabs "using too much".
- **Resource governor.** Profiles: Balanced, Performance, Memory Saver, **Battery Saver** and **Custom** (how many recent tabs stay live, how long a tab may sit idle). Balanced switches to Battery Saver by itself in Low Power Mode, below 20% battery
  unplugged, or when the device runs hot (a setting; the reason is shown). Tabs playing sound, locked, pinned, on a never-sleep site, loading or in use are never released. Battery Saver also checks sound and scheduled pages less often, stops refreshing
  tab thumbnails, and automatic filter-list updates wait on a metered or Low Data connection. The Resources view shows the profile in force, free memory, power, connection, this app's processor use and an energy estimate, start-to-first-page
  timing against earlier launches, and "Free Memory Now". Restored tabs load only when opened. Limits: WebKit's page processes cannot be measured, throttled or tuned from an app, so processor use and energy cover Browser Setu itself, and
  there is no per-tab memory number; lifecycle control works by releasing tabs and trimming browser-owned caches.
- **Privacy detail for the page in front.** The shield's "This site" panel now opens with: HTTPS or not, blocked requests (with a by-site list and an ads/trackers estimate guessed from host names, since WebKit does not say which list blocked a request),
  how many other sites the page loaded from (and which), cookies stored from other sites, WebKit's cross-site tracking restriction, and what is switched off for the site. Settings › Security has **Referrer sent to other sites** (Standard, or
  only within the same site; a page's own policy on a link still wins, and a few sign-in or download flows may need an exception). **Import a List…** in Custom Rules reads a hosts file, an Adblock-style list or plain domains and blocks each
  whole domain (path, element and exception rules are skipped). Already there: ad and tracker blocking, HTTPS upgrades for known hosts, tracking-parameter removal, fingerprint noise, private tabs, auto-cleanup, per-site settings, element hiding,
  cookie banners, storage inspection and deletion, and the Today / 7 days / 30 days / All time counts.
- **Profiles.** Each profile has its own database (history, bookmarks, permissions, home page, search engine, appearance, extension settings) and its own WebKit data store, so cookies and site storage are not shared (this uses WebKit's per-identifier data stores, macOS 14 / iOS 17 and later).
  New: an icon and a colour per profile, **Open This Page in Profile** and **Open in Profile** (the window switches, your tabs come back when you return), **Always Open this site in…** (the address bar offers to switch when a site belongs to another profile),
  **Copy Its Bookmarks Here**, downloads in a folder per profile (a setting), and a **Temporary Profile** that is deleted when you leave it or quit. Moving a profile is the encrypted backup: back up, switch, restore. It carries bookmarks, settings and,
  if you choose, passwords, but not cookies, site sign-ins or history. A guest window (private tabs only) already existed. Not built: choosing a profile from a link's right-click menu (use the tab or profile menu), and links from other apps always open in the current profile.
- **Media.** Page tools › Video lists every player on the page with: what is playing (the page's media-session title and artist, else its title), picture size and dropped frames, play/pause, speed (remembered per site), mute, subtitle and caption choice,
  Pop Out (Picture in Picture), full screen and an AirPlay/output picker where the page allows it. It also shows what is playing in other tabs (pause, mute, go to the tab, pause everything), a **sleep timer** (15 to 90 minutes, pauses media in every tab),
  and **Recently Played** (pages that played media in normal tabs; off switch and clear). Already there: failure explanations and a device capability check, autoplay blocking, a per-tab speaker/mute, Break Mode, Picture in Picture and
  background audio on iPhone. Media keys, Control Centre / lock-screen controls and the system Now Playing entry are WebKit's own handling of a page's media session, not something this app draws, and protected (DRM) video decides for itself what it allows;
  Pop Out and AirPlay are refused by some services. Audio output on a Mac is the system's output device; the page-level picker is AirPlay only. Not built: a floating mini-player of our own (use Picture in Picture), and volume memory per site.
- **Reading.** The reader has its own look in Settings: font (serif, sans, rounded, mono: the system's own), size, line and letter spacing, width and background (match system, light, sepia, dark, black), plus Larger/Smaller Text in the menu and palette.
  Saved articles open offline, remember how far you read (and reopen there), can be searched by title, site, highlights and full text, and can be highlighted; **Copy Citation** (APA, MLA or plain; the author and date are not known to the browser, so the site
  and "n.d." stand in) and **Copy Highlights with Citation** are in the menu. Translation checks the page's language first (on this device) and says if it is already in yours; **Translate Selected Text** and **Detect Page Language** use the same system.
  Already there: read-aloud with a following highlight, find in page with highlighted matches, reduced-motion and high-contrast support, scaled fonts. Not built: custom font files (only system fonts), highlights on ordinary web pages (only saved articles and PDFs),
  and per-highlight notes. Much of the app's own chrome uses fixed sizes, so system Dynamic Type affects only the parts that were built to scale.
- **New tab page.** The start page is native (no web view is used to draw it): a search box with suggestions (Settings › Search can turn the remote ones off), your favorites (add, **edit**, drag to reorder, remove), recently closed, often-visited and
  continue-browsing cards, themes and backgrounds (gradient, plain, a **colour**, a two-colour **blend**, or a photo theme), and a Customize drawer. **New tabs open** can be Browser Setu Home, a Blank Page (address bar ready) or a Custom Address (Settings › General,
  and in the drawer); private tabs always keep their own page. Each profile keeps its own choices. **Google is now the default search engine** for a profile that has not picked one (Brave Search, DuckDuckGo, Bing and others are one click away). **Voice search**: a microphone in the search box (Mac, iPhone and iPad) listens when tapped and searches when you stop talking or tap again; it uses the system recogniser **on this device only** and refuses to run if the language has no on-device model, so nothing you say is sent anywhere. **Picture** is a background choice that uses an image from your device (shrunk, kept in the profile). Known gaps: a new tab
  still creates its web view (only the start page is drawn without it), and a new tab focuses the page's search box rather than the toolbar address bar (⌘L reaches the toolbar one).
- **Search and knowledge.** **Search Everything** (⌥⌘K, or the palette) searches open tabs, bookmarks, history, downloads, the reading list (titles, text and highlights), recently closed tabs, saved sessions, research, notes and commands in one box;
  each result sits under its source's name. **Bookmark Tools** finds duplicate bookmarks (same page ignoring www, fragment and trailing slash; removing keeps the oldest), smart collections (added this week or month, untagged, each tag, sites with three or more),
  and checks for broken links by asking each site once without cookies or a referrer; a link is called broken only on a 404/410 or a site that no longer exists, and refusals or timeouts are listed as "could not tell". Settings › History keeps history for
  7 days to a year or forever. Already there: bookmark folders and tags, import and export, history by day with search by site, frequent and recent sites, favorites, recently closed, the timeline and saved-session and page-text search.
- **Split view (Mac).** Two to four panels, side by side or stacked, with draggable dividers (double-click to even them), independent navigation and scrolling, move a tab in or swap panels, save a pair as a named layout, and the layout in each
  workspace remembers its direction. New: **Link Scrolling** (scrolling one panel scrolls the others to the same share of the page), **Open Link in the Other Panel** in the link menu, **Compare the Two Pages** (what is the same and what differs, by lines of
  text) and **Reopen Last Split Layout**. Find works in the panel you click, because each panel is its own tab. Not built: dragging a link from one panel onto another (WebKit's own link drag may already do it; not checked), and iPad Split View (on hold).
- **Developer tools.** Workbench › Developer has: the page's performance, a waterfall and HAR export, storage, the element picker, a scratchpad, Safari's Web Inspector switch, and new **console, WebSocket and failed-resource capture** (opt-in and run inside the page, so
  the page can notice it; reload after turning it on) with copy and save, **page source**, **response headers** (a fresh request, with notes on missing security headers), **certificate** details and the **user agent**. **Utilities** has a JSON formatter,
  URL and Base64 coders, a timestamp converter, a regex tester, a colour picker and converter, a text comparison and a hash calculator (SHA-256/512, SHA-1, MD5). Not exposed by WebKit to an app: a page's own request headers and bodies, and a JavaScript debugger
  (use Safari's Web Inspector).
- **Network.** Workbench › Network shows: online or offline, the kind of link, metered or Low Data Mode, IPv4/IPv6/DNS support, the resolvers, every interface and its addresses, a timed test to the current site (name lookup, connect, TLS version, first answer),
  a Wi-Fi sign-in page check, a throughput graph, device-wide data used since the app opened and the page's requests by kind. The app says when you go offline, come back or change link; failed pages retry by themselves. It cannot control DNS or WebKit's transport.
- **Offline.** Saved Pages (web archives) open without a connection and run none of their scripts; the reading list keeps articles offline; bookmarks, sessions, notes, settings, downloads history and PDFs are all local, and backups are local and encrypted.
- **Passwords and addresses.** The login editor shows a strength meter with advice, and the saved list flags weak passwords (reuse and leaks were already checked). **Saved Addresses** (Keychain, per profile) fill empty address boxes on request, behind Touch ID where on.
  Not possible: payment-card autofill (the system's is closed to other browsers), and passkeys need an Apple entitlement.
- **Reliability.** A **Session Time Machine** keeps checkpoints of the open pages (every few minutes while they change, and before closing many tabs), so you can reopen what was lost; only addresses, titles and arrangement are kept. The Health tab now shows measured
  values: page crashes, pages that stopped answering (a page that misses two checks is reported), failed navigations, system memory warnings, the last unexpected termination, a database integrity check you can run now, a backup verifier and a diagnostic report that holds
  no addresses or titles. Already there: crash and launch-loop safe mode, database integrity at open with recovery, restore of the last session, interrupted-download resume. Not possible: update rollback (Sparkle replaces the app).
- **Automation.** Open several pages from text or the clipboard, clipboard tools (remove tracking, keep links, dedupe, sort, trim), batch bookmark actions on any smart collection (tag, move, remove), a workflow history, a workflow that runs at start, and workflow export and import
  (imports may use only the safe commands). Not built: per-site keyboard commands.
- **Mac integration.** New: a Dock menu (new tab, private tab, guest window, reopen closed tab, downloads, time machine) and Services (Open in Browser Setu, Search with Browser Setu from any app's selection). Already there: share sheet, Quick Look, Spotlight, Touch ID, Keychain,
  drag and drop, Dock download progress, Shortcuts actions and Handoff.
- **Downloads.** Resumable, with a queue (priorities, hold until a time, pause and resume all, retry with back-off) that survives a restart, an optional sort into folders by kind, **rules by site and kind**,
  a duplicate finder, preview, share and reveal in Finder. A page's own "Download" button that hands over a `data:` or `blob:` file works: it is saved, never run as a page. Progress shows on the Dock icon.
- **PDF editor.** Open a downloaded or chosen PDF: highlight, draw, type, add shapes; rotate, delete, reorder, extract and merge pages; **sign** with a drawn, typed or picture signature kept in the Keychain behind Touch ID;
  **redact** (the words are removed from the file, not just covered); save a password-protected copy. A signature is a picture or text placed on the page, **not a certificate-based digital signature**.
- **Other documents** (Word, Excel, Pages…) open in a preview. Take a picture of the page (visible part or the whole page), or save it as a web archive.

### Developer tools and automation

- **Developer tools** (Workbench): load numbers, a resource waterfall and **HAR export** built from the page's Resource Timing, a storage inspector (secrets masked), uncaught page errors, a JavaScript scratchpad (isolated world,
  never in private tabs), an **element picker** (its selector, size, styles and HTML), **window-size presets** with a live size readout, and a switch that lets Safari's Web Inspector attach.
  WebKit gives pages no request headers, response bodies or `console.log` output, so those are not available, and there is no network throttling (WebKit cannot do it).
- **Automation.** Workflows of fixed, safe steps (open, search, run a command, wait), `browsersetu://` links (open, search, command, workflow), Shortcuts actions, and scheduled page checks that run while the app is open.
  A workflow started from a link asks first. A permission store for scripts exists; there is no script runtime yet.

### Themes, start page and settings

- **Library panels.** Bookmarks, History and Downloads open in your choice of three ways (Settings › Tabs › Library panels, or the first-run setup): **beside the page** (the page narrows, drag the edge to resize; on the Mac and iPad),
  **as a tab** in your tab list, or **as a floating card** over a dimmed page (Mac). Each list is a calm, grouped panel with a search field, filter chips and one-line rows; pressing the same shortcut again closes it.
- **Themes.** **Pure Black** (true black, for OLED screens), a **theme schedule** (a day theme and a night theme by time) and eleven more moods (Slime Night, Blood Moon, Synthwave, Aurora, Paper, Arctic and more) and ten classic palettes (Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night, Rosé Pine, One Dark…), drawn in
  code with no downloaded art, painted under the **whole window including the title bar**. Make your own **Custom** theme (two background colours, an accent, optionally a photo whose main colour becomes the accent, with a
  warning when an accent is hard to see). **Import and export theme files** (colours only, so they are safe to share), or turn any theme into your Custom one to adjust it.
- **The toolbar takes the page's colour** (Settings › Appearance › Layout). It reads the page's theme colour, or its background when it names none. Under a theme the page adds a lighter touch; a colour that would
  clash with the window (a white page in a dark window) adds only a faint wash.
- **Start page.** Native and quick: the date and a greeting, one large search field, favorites as cards, a Continue card with a preview of the page, often-visited and recently closed places as cards, tabs on your other devices and
  tabs sent to this one. Every long list shows a few and "Show 8 more". Gradient or Plain background and Small, Regular or Large sizes apply as you choose them.
  **Customize** slides a panel in from the right without leaving the page: theme, accent, what shows, icon size, search engine; it applies the moment you touch it and there is nothing to save.
- **Settings** (Mac: a rail of panels in three groups with a search field that opens the right panel, a title that frosts as the list scrolls under it, and long lists that end in "Show more"; iPhone: topics): General, Appearance, Tabs (layout, split view and windows help, groups, workspaces), Search, Privacy, Websites,
  Profiles, Performance, Extensions, Shortcuts, Advanced. Changes apply as you make them and are shared by every window.

### Accessibility

- Icon-only buttons have spoken labels; text follows the text-size setting on iPhone and iPad (capped so bars do not break); outlines get stronger with Increase Contrast; animations are skipped with Reduce Motion;
  the start page's tiles show a focus ring when the keyboard reaches them. **This has not been audited with VoiceOver or Accessibility Inspector.**

### Sync, backup and other devices

- **iCloud sync** (App Store and TestFlight builds; Apple allows it for those only), sealed with your own passphrase before it leaves the device, so Apple stores only scrambled bytes. You choose **what to sync, one switch
  for each**: bookmarks, workspaces, saved sessions, open tabs, settings and themes, site rules and styles, **history** (the 800 most recent pages, and deletions; off by default) and passwords (off by default).
  Switching one off sends nothing, takes nothing in and deletes nothing on your other devices. Two devices that edit the same thing end up the same, in any order; a deletion is remembered, not undone.
  New devices wait for your approval, devices are grouped by a sync group name, and a status row says exactly what is wrong (not signed in, needs a passphrase, devices waiting, space nearly full, last sent and received).
- **Send a tab to another device** from the tab menu, the More menu or the palette. It arrives once, as a web address only, and shows on that device's start page.
- **Tabs on your other devices** are listed, never opened by themselves. **Wi-Fi sync** and **Send to Another Device** work straight between your own devices with a one-time 100-bit code and no server.
- **Handoff and Spotlight.** Hand the page in front to your other devices, and find your bookmarks from Spotlight (both off for private tabs, history, passwords and page text).
- **Encrypted backup file** of bookmarks, settings and research (passphrase-sealed; **saved passwords only if you tick the box**; cookies and history are never in it; save it in iCloud Drive to keep a copy off the device) and **bookmark import and export** in the standard HTML format.
- **Not run between two real devices yet:** the tests run two in-process browsers, so please report anything odd.

### iPhone and iPad

The three apps share one engine and one set of features, but each has its own layout.

- **iPhone:** no toolbar. A dock of three pills, a search button, and an address bar that opens in place when you tap it. The page keeps clear of the status bar and the dock, and a page without fixed bars gets
  a transparent top. While a page is read the dock folds into one small pill.
- **iPad (its own touch design):** one toolbar row of 44-point buttons (sidebar, back and forward, a wide address field, share, new tab, tab count, the ⋮ menu), then a strip of large rounded tab chips.
  The ⋮ menu holds the iPhone's full menu (find, share, reader, text size, page tools, extensions, close tabs) plus History, Bookmarks, Downloads and Reading List. Those three lists dock beside the page.
  While a page is read the toolbar and tabs slide away, leaving a small pill with the site name. The tab overview has large cards, a Tabs / Private switch and search. Address suggestions are one card under
  the field. An attached keyboard (Magic Keyboard or Bluetooth) uses the Mac's shortcuts: ⌘T, ⌘W, ⌘L, ⌘K, ⌘F, ⌘[ and ⌘], ⌘1 to ⌘9 and the rest, following the choices in Settings › Shortcuts.
  **Limits:** the iPad layout has been looked at only in the simulator and on one device by the author; keyboard shortcuts could not be confirmed on a real Magic Keyboard (the same keyboard failed in Safari on that iPad, so it may
  be that iPad or keyboard); it has no tests of its own yet.
- The same privacy, passwords (with Face ID), sync, themes, start page with the Customize panel, PDF editor, page tools, address-bar answers, sent tabs and settings, as above. Extensions install and run from the More
  menu (iOS 18.4 or later). There is a speed-pill widget and Shortcuts actions.
  **Widgets:** Search, Favorites, Blocked Today and Reading List for the Home Screen, and Search and Blocked Today for the Lock Screen. **Control Center and Lock Screen buttons (iOS 18):** New Tab, Private Tab and Shared Inbox. Widgets need the shared App Group, which is set up for this app.
- **Mac only:** Control-Option-Space opens a small search from the menu bar in any app (turn it on with **Search from the Menu Bar** in the Library menu), several windows, guest windows, split view, mouse gestures, the sidebar layouts, floating library cards, panels as tabs and the Workbench developer tools.

## What leaves your device

Browser Setu has no accounts, no analytics and no telemetry. The only network requests the app itself makes are:

| When | What | To |
|---|---|---|
| You load a page | the page | the site |
| You turn on search suggestions | what you type in the address bar | your search engine |
| A site icon is shown | the icon request | the site |
| You press Update on a filter list (or enable automatic updates) | the list address, with no cookies or identifiers | the list publisher |
| You add an extension from the Chrome Web Store | one package request | Google's store |
| The downloadable Mac build checks for updates (daily, can be turned off) | the app's version | github.com |
| The YouTube ad blocker and its update option are on (at most daily; "Check Now" any time) | one small rules file, no cookies or identifiers | raw.githubusercontent.com (this project) |
| You start a network check, a response-headers view, the dead-link checker, a feed refresh, or a large download | one request each, with no cookies or referrer; a large download uses up to six connections to the same file | the address you chose |
| You turn on AI tools and share a tab (downloadable Mac build only) | nothing from Browser Setu; the tool you run reads the shared tab over this Mac's loopback address and may send it on to its own company | the AI tool you chose, then its provider |
| You press **Look for a saved copy** on a page that would not load | the page's address without its query or fragment (never a private-network address) | the Internet Archive |
| You press **Check Security Headers** in the site panel | the site's name | Mozilla's HTTP Observatory |
| You press **Convert** on an amount in the selection actions | two or three currency codes | frankfurter.dev (European Central Bank rates) |
| You choose **Copy Citation from DOI** | the DOI | Crossref |
| You press Check Passwords for Leaks | the first five characters of each password's SHA-1 hash, nothing else | haveibeenpwned.com |
| You sync | an encrypted snapshot | your iCloud, or your own device over Wi-Fi |

Tests in `apps/apple/Tests/PrivacyIntegrationTests.swift` fail if networking code appears anywhere else, and if a page gains a channel back to the app. The browser's own three scripts (sign-in watching, the link under the pointer, and real clicks and key presses) report to the app from an isolated world that a page cannot reach; a test checks that those are the only message handlers and that none is registered for the page's own world.

## Updates

The App Store and TestFlight builds update through Apple. The downloadable Mac build includes [Sparkle](https://sparkle-project.org): it checks
[`appcast.xml`](appcast.xml) once a day, asks before installing, and refuses any update that is not signed with the publisher's key. Turn automatic
checks off in Settings → Advanced → Updates, or use **Browser Setu → Check for Updates…**.

## How it is built

```
apps/apple/   SwiftUI apps (macOS + iOS)
  Shared/       engine-neutral app code: BrowserModel, tabs, views, privacy, sync, research, workbench
  Shared/Engine/EngineAPI.swift   the contract between the app and a web engine
  Engines/WebKit/                 the WebKit engine, extensions, user scripts
  macOS/ iOS/ Direct/             platform shells (Direct = the downloadable Mac build with the updater)
  Tests/ UITests/ iOSTests/ iOSUITests/
core/         Rust workspace
  domain/       pure logic: tabs, omnibox, navigation and permission policy, profile names
  storage/      per-profile SQLite (WAL, versioned migrations, parameterised SQL only)
  ffi/          UniFFI surface used by Swift
Packages/SetuPrivacyKit   content-blocking policy builder and the WebKit rule installer
experiments/  a parked Blink/CEF engine bridge (not built)
docs/         capabilities (dated status ledger), threat model, extension compatibility, verification, privacy notes
scripts/      build-xcframework.sh, release.sh (sign, notarize, DMG), publish-release.sh, testflight.sh
```

**Engine.** WebKit on both platforms, for low memory and battery use and Apple's own security updates. Everything above the `BrowserEngine` protocol
is engine-neutral, so another engine could be added. WKWebView does not give Chrome-style site isolation, and the app makes no such claim.

**Security model** (details in [`docs/security/threat-model.md`](docs/security/threat-model.md)): web pages are untrusted and have no bridge to the core;
every navigation goes through a core policy (http/https only; mail and phone links need confirmation; `file`, `javascript` and `data` pages are
refused); downloads are renamed to a leaf name and never opened automatically; profile names are validated before they touch the file system; the Mac
app is sandboxed with the hardened runtime.

## Build from source

Requires Xcode, Rust (rustup; the toolchain is pinned in `core/rust-toolchain.toml`) and XcodeGen (`brew install xcodegen`).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-xcframework.sh                   # Rust core → XCFramework + Swift bindings
cd apps/apple && xcodegen generate
xcodebuild -scheme BrowserSetuMac build        # sandboxed Mac build, no updater (App Store)
xcodebuild -scheme BrowserSetuMacDirect build  # the downloadable build, with Sparkle
xcodebuild -scheme BrowserSetuiOS -destination 'generic/platform=iOS' build
```

Tests: `xcodebuild -scheme BrowserSetuMac test -only-testing:BrowserSetuMacTests`. UI and iPhone tests need `scripts/testserver.py`. The state of
verification is in [`docs/verification.md`](docs/verification.md) and [`docs/capabilities.md`](docs/capabilities.md).

Releasing: `scripts/release.sh <version> <build>` signs with Developer ID, notarizes, staples and makes the DMG; `scripts/publish-release.sh` uploads it and
adds it to the update feed; `scripts/testflight.sh` archives and uploads the iPhone build.

## Not built, on purpose

- Passkeys and iCloud Passwords (Apple has to grant browsers the entitlement; a request is the next step).
- VPN-type extensions and per-extension CPU or memory (WebKit reports none). A built-in VPN, Tor, and network throttling (WebKit gives no way to do them).
- Certificate-based digital signatures on PDFs (signing places a picture or text).
- Three-way split on iPhone (the iPhone has no split view); mouse gestures and guest windows on iPhone (no mouse, and private tabs cover guests).
- AI features and semantic search (skipped by choice).

## Licence

Copyright © 2026 Lokesh Reddy Veerabhadra. The source is published so you can read and audit it; all rights are reserved and no licence to reuse it is
granted. Third-party components keep their own licences (Sparkle is MIT). If you want to use the code, ask.
