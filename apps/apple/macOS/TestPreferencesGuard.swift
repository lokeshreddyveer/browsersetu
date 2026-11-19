import Foundation
import ObjectiveC

#if DEBUG
/// A test process never writes the person's own preferences. Relocating the home (`TestIsolation.relocateHomeIfNeeded`) does not move preferences: `cfprefsd` keeps a process's domain under the person's
/// real `~/Library/Preferences` whatever `CFFIXED_USER_HOME` says, and so does a suite, even one named by an absolute path. In a test process the standard defaults are therefore an in-memory store:
/// every write and removal stays in this process, while reads still see the argument domain (`-UITestRoot` and the like), registered defaults and the global domain, as the standard defaults would.
/// Only a test process (a `-UITestRoot` launch or an XCTest host) installs this; the installed app never does, and a Release build does not contain it.
enum TestPreferencesGuard {
    private(set) static var installed = false
    private static let store = TestProcessDefaults()

    static func installIfTestProcess() {
        let decision = TestIsolation.homeDecision(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments, realHome: TestIsolation.realHome, relocatedHome: "")
        guard decision != .notATestProcess, !installed else { return }
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else {
            fatalError("TestPreferencesGuard: cannot replace the standard defaults; refusing to let a test process write the person's own preferences")
        }
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in TestPreferencesGuard.store }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        installed = true
    }
}

/// The standard defaults of a test process: values written here live in memory for the life of the process. Reads that nothing in this process has written or removed go to the normal search list.
final class TestProcessDefaults: UserDefaults {
    private let lock = NSLock()
    private var written: [String: Any] = [:]
    private var removed: Set<String> = []

    init() { super.init(suiteName: nil)! }

    // MARK: Reading

    override func object(forKey key: String) -> Any? {
        lock.lock()
        if let value = written[key] { lock.unlock(); return value }
        let wasRemoved = removed.contains(key)
        lock.unlock()
        // A removed value falls back to what is registered, as it would once removed from the persistent domain.
        if wasRemoved { return volatileDomain(forName: UserDefaults.registrationDomain)[key] }
        return super.object(forKey: key)
    }

    override func string(forKey key: String) -> String? {
        switch object(forKey: key) { case let s as String: return s; case let n as NSNumber: return n.stringValue; default: return nil }
    }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func integer(forKey key: String) -> Int {
        switch object(forKey: key) { case let n as NSNumber: return n.intValue; case let s as String: return Int(s) ?? Int(Double(s) ?? 0); default: return 0 }
    }
    override func float(forKey key: String) -> Float { Float(double(forKey: key)) }
    override func double(forKey key: String) -> Double {
        switch object(forKey: key) { case let n as NSNumber: return n.doubleValue; case let s as String: return Double(s) ?? 0; default: return 0 }
    }
    override func bool(forKey key: String) -> Bool {
        switch object(forKey: key) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased()) || (Int(s) ?? 0) != 0
        default: return false
        }
    }
    override func url(forKey key: String) -> URL? {
        switch object(forKey: key) {
        case let u as URL: return u
        case let s as String: return s.hasPrefix("/") || s.hasPrefix("~") ? URL(fileURLWithPath: (s as NSString).expandingTildeInPath) : URL(string: s)
        case let d as Data: return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d) as URL?
        default: return nil
        }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        var all = super.dictionaryRepresentation()
        lock.lock(); defer { lock.unlock() }
        for key in removed { all[key] = volatileDomain(forName: UserDefaults.registrationDomain)[key] }
        for (key, value) in written { all[key] = value }
        return all
    }

    // MARK: Writing (memory only)

    override func set(_ value: Any?, forKey key: String) {
        guard let value else { removeObject(forKey: key); return }
        change(key) { written[key] = value; removed.remove(key) }
    }
    override func removeObject(forKey key: String) { change(key) { written[key] = nil; removed.insert(key) } }
    override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ url: URL?, forKey key: String) { set(url as Any?, forKey: key) }

    /// The persistent domains are never written either: setting one fills the memory store, removing one clears what this process wrote.
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        for (key, value) in domain { set(value, forKey: key) }
    }
    override func removePersistentDomain(forName domainName: String) {
        lock.lock(); let keys = Array(written.keys); lock.unlock()
        for key in keys { removeObject(forKey: key) }
    }

    /// Nothing is pending on disk: there is nothing to write.
    override func synchronize() -> Bool { true }

    // MARK: Observers
    // The standard defaults route key-value observation through their own preferences machinery, which never hears a write kept in memory; so observers of this store are kept and told here
    // (SwiftUI's `@AppStorage` observes this way).

    private struct Observation { weak var observer: NSObject?; let keyPath: String; let options: NSKeyValueObservingOptions; let context: UnsafeMutableRawPointer? }
    private var observations: [Observation] = []

    override func addObserver(_ observer: NSObject, forKeyPath keyPath: String, options: NSKeyValueObservingOptions = [], context: UnsafeMutableRawPointer?) {
        lock.lock(); observations.append(Observation(observer: observer, keyPath: keyPath, options: options, context: context)); lock.unlock()
        if options.contains(.initial) { observer.observeValue(forKeyPath: keyPath, of: self, change: [.kindKey: NSKeyValueChange.setting.rawValue, .newKey: object(forKey: keyPath) ?? NSNull()], context: context) }
    }
    override func removeObserver(_ observer: NSObject, forKeyPath keyPath: String, context: UnsafeMutableRawPointer?) {
        lock.lock(); observations.removeAll { $0.observer == nil || ($0.observer === observer && $0.keyPath == keyPath && $0.context == context) }; lock.unlock()
    }
    override func removeObserver(_ observer: NSObject, forKeyPath keyPath: String) {
        lock.lock(); if let i = observations.lastIndex(where: { $0.observer === observer && $0.keyPath == keyPath }) { observations.remove(at: i) }; lock.unlock()
    }

    private func change(_ key: String, _ body: () -> Void) {
        let old = object(forKey: key)
        lock.lock(); body(); let watching = observations.filter { $0.keyPath == key && $0.observer != nil }; lock.unlock()
        let new = object(forKey: key)
        for o in watching {
            var change: [NSKeyValueChangeKey: Any] = [.kindKey: NSKeyValueChange.setting.rawValue]
            if o.options.contains(.new) { change[.newKey] = new ?? NSNull() }
            if o.options.contains(.old) { change[.oldKey] = old ?? NSNull() }
            o.observer?.observeValue(forKeyPath: key, of: self, change: change, context: o.context)
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
}
#endif
