import Foundation

/// The test scheme starts scripts/test_process_supervisor.py outside the sandbox; a sandboxed test host asks it, over loopback, to run the helper servers (the FTP fixture, sshd)
/// that it cannot start itself. The supervisor only runs fixed programs and only on paths inside this process's own temporary folder.
enum TestProcessSupervisor {
    static let base = URL(string: "http://127.0.0.1:18821")!

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func call(_ path: String, _ body: [String: Any]?) throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 25)
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: (Data?, URLResponse?, Error?) = (nil, nil, nil) }
        let box = Box()
        URLSession(configuration: .ephemeral).dataTask(with: request) { d, r, e in box.value = (d, r, e); sem.signal() }.resume()
        guard sem.wait(timeout: .now() + 30) == .success else { throw Failure(message: "the test process supervisor did not answer") }
        let result = box.value
        guard let data = result.0, result.2 == nil else { throw Failure(message: "the test process supervisor is not running (the test scheme starts it): \(result.2?.localizedDescription ?? "no answer")") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let status = (result.1 as? HTTPURLResponse)?.statusCode, status != 200 { throw Failure(message: object["error"] as? String ?? "the supervisor refused (\(status))") }
        return object
    }

    /// Starts one helper and returns its id. `kind` is "ftp" (args: root, port, options) or "sshd" (args: the config path; `port` is the one it listens on).
    static func start(kind: String, args: [String], port: Int = 0) throws -> String {
        let r = try call("start", ["kind": kind, "args": args, "port": port])
        guard let id = r["id"] as? String else { throw Failure(message: "the supervisor returned no id") }
        return id
    }

    static func stop(_ id: String?) { if let id { _ = try? call("stop", ["id": id]) } }
}
