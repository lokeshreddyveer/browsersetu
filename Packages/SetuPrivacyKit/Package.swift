// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SetuPrivacyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SetuPrivacyCore", targets: ["SetuPrivacyCore"]),
        .library(name: "SetuPrivacyWebKit", targets: ["SetuPrivacyWebKit"]),
    ],
    targets: [
        // Pure Swift: rule models, parsing, validation, precedence, snapshots. No UI, no WebKit, no networking.
        .target(name: "SetuPrivacyCore"),
        // WebKit adapter: compiles WKContentRuleList, caches and installs it. Public WebKit API only.
        .target(name: "SetuPrivacyWebKit", dependencies: ["SetuPrivacyCore"]),
        .testTarget(name: "CoreTests", dependencies: ["SetuPrivacyCore", "SetuPrivacyWebKit"]),
    ]
)
