# Turning on the widgets and the share-sheet extension (iPhone and iPad)

The home-screen and lock-screen widgets (Search, Favorites, Blocked Today, Reading List) and the "Open in / Save to Reading List / Send to My Devices"
share-sheet entry are written and compiled behind a switch, because they pass data to the app through an **App Group**, and Apple has to create it first.
The app and everything else build without it.

1. In the Apple Developer account (developer.apple.com, Certificates, Identifiers & Profiles, Identifiers), add an **App Group** named `group.com.browsersetu.shared`.
2. Open the App IDs `com.browsersetu.ios`, `com.browsersetu.ios.speedwidget` and (new) `com.browsersetu.ios.share`, switch on **App Groups** and tick that group.
3. In `apps/apple/project.yml`: uncomment the `entitlements` blocks marked "see docs/app-group.md" on `BrowserSetuiOS`, `BrowserSetuSpeedWidget` and `BrowserSetuShare`,
   uncomment `- target: BrowserSetuShare`, and add `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) APP_GROUP` under the settings of `BrowserSetuSpeedWidget` and `BrowserSetuShare`.
4. `xcodegen generate`, build with `-allowProvisioningUpdates`, and check on a device: the widgets appear in the widget gallery, and "Browser Setu" appears in the share sheet.

Not verified on a device: widget refresh timing, the share sheet's attempt to open the app straight away (iOS may refuse it; the item then waits until the app opens), and the lock-screen families.
