import Foundation

/// A named preferences suite for a test, kept inside the test process. `UserDefaults(suiteName:)` cannot be used for that: `cfprefsd` keeps every suite in the person's real
/// `~/Library/Preferences` whatever home the test process has (a name given as an absolute path included), so each test that made one left a file there.
///
/// Use it exactly where `UserDefaults(suiteName:)` was used: `IsolatedTestDefaults(suiteName: "bs.thing.\(UUID().uuidString)")!`.
/// - Values are shared by suite name, so a suite made again with the same name sees what the first one wrote (re-creation within the process behaves as with a real suite).
///   Nothing is written to disk, so values do not outlive the test process; no test here checks that, and the supported APIs offer no disposable on-disk suite (see the Stage 3 report).
/// - Reads of anything not written here fall through to the normal search list (the never-written suite itself, the argument domain, the global domain, registered defaults).
/// - `removePersistentDomain(forName:)` clears the named suite's values; `synchronize()` has nothing to write.
/// - Key-value observers and `UserDefaults.didChangeNotification` are told of every change.
/// Subclasses (a test's counting store, for example) override `set(_:forKey:)` and call `super` as before.
class IsolatedTestDefaults: UserDefaults {
    private final class Storage {
        let lock = NSLock()
        var written: [String: Any] = [:]
        var removed: Set<String> = []
    }
    private static let registryLock = NSLock()
    private static var registry: [String: Storage] = [:]
    private static func storage(_ name: String) -> Storage {
        registryLock.lock(); defer { registryLock.unlock() }
        if let s = registry[name] { return s }
        let s = Storage(); registry[name] = s; return s
    }

    /// The suite's name. Tests pass a unique name; a missing one becomes unique so two nameless suites never share values.
    let isolatedName: String
    private let storage: Storage

    override init?(suiteName: String?) {
        let name = suiteName ?? "bs.isolated.\(UUID().uuidString)"
        isolatedName = name
        storage = Self.storage(name)
        super.init(suiteName: name)
    }

    // MARK: Reading

    override func object(forKey key: String) -> Any? {
        storage.lock.lock()
        if let value = storage.written[key] { storage.lock.unlock(); return value }
        let wasRemoved = storage.removed.contains(key)
        storage.lock.unlock()
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
        storage.lock.lock(); defer { storage.lock.unlock() }
        for key in storage.removed { all[key] = volatileDomain(forName: UserDefaults.registrationDomain)[key] }
        for (key, value) in storage.written { all[key] = value }
        return all
    }

    // MARK: Writing (memory only)

    override func set(_ value: Any?, forKey key: String) {
        guard let value else { removeObject(forKey: key); return }
        change(key) { $0.written[key] = value; $0.removed.remove(key) }
    }
    override func removeObject(forKey key: String) { change(key) { $0.written[key] = nil; $0.removed.insert(key) } }
    override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ url: URL?, forKey key: String) { set(url as Any?, forKey: key) }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        for (key, value) in domain { set(value, forKey: key) }
    }
    /// Clears what this suite holds (the name a test passes is its own suite's name).
    override func removePersistentDomain(forName domainName: String) {
        storage.lock.lock(); let keys = Array(storage.written.keys); storage.lock.unlock()
        for key in keys { removeObject(forKey: key) }
    }
    override func synchronize() -> Bool { true }

    // MARK: Observers (the standard machinery never hears a write kept in memory)

    private struct Observation { weak var observer: NSObject?; let keyPath: String; let options: NSKeyValueObservingOptions; let context: UnsafeMutableRawPointer? }
    private var observations: [Observation] = []

    override func addObserver(_ observer: NSObject, forKeyPath keyPath: String, options: NSKeyValueObservingOptions = [], context: UnsafeMutableRawPointer?) {
        storage.lock.lock(); observations.append(Observation(observer: observer, keyPath: keyPath, options: options, context: context)); storage.lock.unlock()
        if options.contains(.initial) { observer.observeValue(forKeyPath: keyPath, of: self, change: [.kindKey: NSKeyValueChange.setting.rawValue, .newKey: object(forKey: keyPath) ?? NSNull()], context: context) }
    }
    override func removeObserver(_ observer: NSObject, forKeyPath keyPath: String, context: UnsafeMutableRawPointer?) {
        storage.lock.lock(); observations.removeAll { $0.observer == nil || ($0.observer === observer && $0.keyPath == keyPath && $0.context == context) }; storage.lock.unlock()
    }
    override func removeObserver(_ observer: NSObject, forKeyPath keyPath: String) {
        storage.lock.lock(); if let i = observations.lastIndex(where: { $0.observer === observer && $0.keyPath == keyPath }) { observations.remove(at: i) }; storage.lock.unlock()
    }

    private func change(_ key: String, _ body: (Storage) -> Void) {
        let old = object(forKey: key)
        storage.lock.lock(); body(storage); let watching = observations.filter { $0.keyPath == key && $0.observer != nil }; storage.lock.unlock()
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
