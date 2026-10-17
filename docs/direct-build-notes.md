# Direct-download Mac build (on hold)

Parked on request. Nothing here is built or shipped. The code that would use it is in `Engines/WebKit/NativeMessaging.swift` and is inert
unless the `DIRECT_DISTRIBUTION` compile flag is set.

Idea: a second Mac target without the App Sandbox, so it can start Apple's own Passwords helper for the iCloud Passwords extension
(`/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app`). Only helpers under /System whose manifest
names the extension are allowed. Unknown until tried: whether the helper accepts a caller that is not Chrome.

Target to add to `project.yml` (the Mac target would first become a `targetTemplates` entry used by both targets):

```yaml
  BrowserSetuMac:
    templates: [MacApp]
  # The direct-download build: the same app without the App Sandbox, so it can start Apple's own Passwords helper for the iCloud Passwords
  # extension. A separate bundle id, so it installs beside the App Store build and neither touches the other's data.
  BrowserSetuMacDirect:
    templates: [MacApp]
    entitlements:
      path: macOS/BrowserSetuDirect.entitlements
      properties:
        com.apple.security.app-sandbox: false
    settings:
      base:
        BROWSERSETU_BUNDLE_ID: com.browsersetu.mac.direct
        PRODUCT_NAME: Browser Setu Direct
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) DIRECT_DISTRIBUTION"
```
