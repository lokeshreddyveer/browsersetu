import XCTest
import Security
@testable import Browser_Setu

/// What can be checked about secrets after the App Sandbox is gone, using throwaway items only (no existing secret is read, changed or deleted).
final class KeychainContinuityTests: XCTestCase {
    func testThisBuildIsNotSandboxedAndCanUseBothKeychainKinds() throws {
        XCTAssertNil(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"], "this build must not be sandboxed")
        let service = "com.browsersetu.test.continuity.\(UUID().uuidString)", account = "throwaway"
        defer { _ = SecretStore.delete(service: service, account: account) }
        // The app's own store (the login keychain, tied to this device): write, read back, replace, remove.
        XCTAssertEqual(SecretStore.put(Data("one".utf8), service: service, account: account), .local)
        XCTAssertEqual(SecretStore.get(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }, "one")
        XCTAssertEqual(SecretStore.put(Data("two".utf8), service: service, account: account), .local)
        XCTAssertEqual(SecretStore.get(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }, "two")
        _ = SecretStore.delete(service: service, account: account)
        XCTAssertNil(SecretStore.get(service: service, account: account))
        // The data-protection keychain (used for iCloud Keychain items and by the account store): does this signed Debug build have what it needs?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".dp", kSecAttrAccount as String: account,
                                kSecValueData as String: Data("x".utf8), kSecUseDataProtectionKeychain as String: true]
        let status = SecItemAdd(q as CFDictionary, nil)
        print("KEYCHAIN data-protection add status: \(status) (\(status == errSecSuccess ? "works" : status == errSecMissingEntitlement ? "errSecMissingEntitlement: needs a keychain access group / provisioning profile" : "other"))")
        if status == errSecSuccess { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".dp", kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true] as CFDictionary) }
        // Existing items, metadata only (their secrets are never requested): how many does the app have, and which keychain are they in?
        var out: CFTypeRef?
        let list = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true] as CFDictionary, &out)
        let services = ((out as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix("com.browsersetu") && !$0.contains(".test.") }
        print("KEYCHAIN existing app items (login keychain, metadata only): status=\(list) services=\(Set(services).sorted())")
    }
}
