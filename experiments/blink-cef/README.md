# Blink (CEF) engine experiment, parked

Not part of the build. BrowserSetu uses WebKit on macOS and iOS (chosen for privacy, RAM and battery).
This folder keeps the unfinished Objective-C++ CEF bridge in case a Blink engine is needed later
(for example Chrome extension compatibility). It targets the `BrowserEngine` protocol in
`apps/apple/Shared/Engine/EngineAPI.swift`. It was never compiled or run.
`fetch-cef.sh` downloads the pinned CEF build with checksum verification.
