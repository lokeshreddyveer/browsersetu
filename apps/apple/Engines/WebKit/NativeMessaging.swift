import Foundation

/// Chrome's native messaging, for the one case Browser Setu supports it: an extension talking to a helper program that Apple ships with macOS (the
/// iCloud Passwords extension and the Passwords helper behind it). Everything here is plain data handling and is compiled into every build; only the
/// direct-download build, which is not sandboxed, ever starts a helper (see `NativeMessagingSession`).
enum NativeFraming {
    /// The most a helper may send in one message, as in Chrome.
    static let maxIncoming = 1_048_576

    enum Problem: Error { case notJSON, tooLarge }

    /// A message as the helper expects it: its length as four bytes (the machine's byte order), then the JSON text.
    static func encode(_ message: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message) || message is String || message is NSNumber || message is NSNull else { throw Problem.notJSON }
        let body = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Takes every complete message off the front of `buffer` and leaves a partial one for the next read.
    static func decode(_ buffer: inout Data) throws -> [Any] {
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
            guard length <= maxIncoming else { throw Problem.tooLarge }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + length))
            guard let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { throw Problem.notJSON }
            messages.append(message)
        }
        return messages
    }
}

/// Which helper programs an extension may start. Only ones Apple installs under /System, and only for the extension ids the helper's own manifest
/// names; nothing an extension or a downloaded file supplies is ever run.
enum NativeHosts {
    struct Manifest: Equatable {
        var name: String
        var path: String
        var allowedOrigins: [String]
    }

    static let searchDirectories = ["/Library/Google/Chrome/NativeMessagingHosts"]

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
        }
    }

    static func manifest(named name: String, in directories: [String] = searchDirectories) -> Manifest? {
        guard isValidName(name) else { return nil }
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["name"] as? String == name, json["type"] as? String == "stdio", let path = json["path"] as? String else { continue }
            return Manifest(name: name, path: path, allowedOrigins: (json["allowed_origins"] as? [String]) ?? [])
        }
        return nil
    }

    /// The origin string a browser hands the helper when it starts it.
    static func origin(for chromeID: String) -> String { "chrome-extension://\(chromeID)/" }

    static func isPermitted(_ manifest: Manifest, chromeID: String?) -> Bool {
        guard let chromeID, chromeID.count == 32 else { return false }
        let path = URL(fileURLWithPath: manifest.path).standardizedFileURL.path
        return path.hasPrefix("/System/") && manifest.allowedOrigins.contains(origin(for: chromeID))
    }
}

#if DIRECT_DISTRIBUTION && os(macOS)
import WebKit

/// One running helper: its standard input and output carry the framed messages. Closed when the extension's port closes, when the helper quits, or
/// when Browser Setu does.
@MainActor
final class NativeMessagingSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var closed = false
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?

    init(manifest: NativeHosts.Manifest, chromeID: String) throws {
        process.executableURL = URL(fileURLWithPath: manifest.path)
        process.arguments = [NativeHosts.origin(for: chromeID)]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished() } }
        }
        try process.run()
    }

    func send(_ message: Any) {
        guard !closed, let framed = try? NativeFraming.encode(message) else { return }
        try? input.fileHandleForWriting.write(contentsOf: framed)
    }

    func close() {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func received(_ data: Data) {
        guard !closed else { return }
        if data.isEmpty { finished(); return }
        buffer.append(data)
        guard let messages = try? NativeFraming.decode(&buffer) else { close(); onExit?(); return }
        for message in messages { onMessage?(message) }
    }

    private func finished() {
        guard !closed else { return }
        close()
        onExit?()
    }

    /// One message out, the first message back: for an extension's single `sendNativeMessage`.
    func exchange(_ message: Any, timeout: TimeInterval = 30) async -> Any? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            var resumed = false
            func finish(_ value: Any?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            onMessage = { finish($0) }
            onExit = { finish(nil) }
            send(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

@available(macOS 15.4, *)
extension WebKitExtensionManager {
    /// The helper this extension asked for, if it is one Apple ships and the helper names this extension.
    private func permittedHost(named name: String?, for context: WKWebExtensionContext) -> (NativeHosts.Manifest, String)? {
        // `chromeIDVerified` is set only once an extension's package signature has been checked against its id. Nothing sets it yet, so this path stays inert
        // even if the build flag is switched on.
        guard let name, let id = contexts.first(where: { $0.value === context })?.key,
              let record = records.first(where: { $0.id == id }), record.chromeIDVerified == true,
              let chromeID = record.chromeID,
              let manifest = NativeHosts.manifest(named: name), NativeHosts.isPermitted(manifest, chromeID: chromeID) else { return nil }
        return (manifest, chromeID)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext) async throws -> Any? {
        guard let (manifest, chromeID) = permittedHost(named: applicationIdentifier, for: extensionContext) else { throw ExtensionError.unsupported }
        let session = try NativeMessagingSession(manifest: manifest, chromeID: chromeID)
        defer { session.close() }
        return await session.exchange(message)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext) async throws {
        guard let (manifest, chromeID) = permittedHost(named: port.applicationIdentifier, for: extensionContext) else { throw ExtensionError.unsupported }
        let session = try NativeMessagingSession(manifest: manifest, chromeID: chromeID)
        nativeSessions.append(session)
        port.messageHandler = { [weak session] message, error in
            guard error == nil, let message else { return }
            Task { @MainActor in session?.send(message) }
        }
        port.disconnectHandler = { [weak session, weak self] _ in
            Task { @MainActor in
                session?.close()
                self?.nativeSessions.removeAll { $0 === session }
            }
        }
        session.onMessage = { [weak port] message in port?.sendMessage(message) { _ in } }
        session.onExit = { [weak port, weak session, weak self] in
            port?.disconnect()
            self?.nativeSessions.removeAll { $0 === session }
        }
    }
}
#endif
