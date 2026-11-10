import XCTest
@testable import Browser_Setu

/// What can be checked about iCloud Sync on this machine without changing any user's synced data: only a throwaway key is written (and removed) in the key-value store.
@MainActor
final class ICloudContinuityTests: XCTestCase {
    func testEntitlementIdentityTokenAndKeyValueStoreOnThisBuild() throws {
        let token = FileManager.default.ubiquityIdentityToken
        print("ICLOUD signed-in identity token present: \(token != nil); CloudSync.available=\(CloudSync.available)")
        // The entitlement the running build was signed with (read from its own code signature).
        var code: SecStaticCode?
        SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code)
        var info: CFDictionary?
        if let code { SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &info) }
        let ents = ((info as? [String: Any])?["entitlements-dict"] as? [String: Any]) ?? [:]
        print("ICLOUD entitlements in the running build: kvstore=\(ents["com.apple.developer.ubiquity-kvstore-identifier"] ?? "none") sandbox=\(ents["com.apple.security.app-sandbox"] ?? "none")")
        // Round trip of a throwaway key through the key-value store (a local write; whether it reaches iCloud depends on the account).
        let store = NSUbiquitousKeyValueStore.default
        let key = "bs.test.continuity.\(UUID().uuidString)"
        store.set("ok", forKey: key)
        XCTAssertEqual(store.string(forKey: key), "ok")
        store.removeObject(forKey: key)
        XCTAssertNil(store.string(forKey: key))
    }
}
