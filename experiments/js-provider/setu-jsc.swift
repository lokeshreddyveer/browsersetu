// PROTOTYPE (experiments/ only; not wired into any production flow).
// setu-jsc: runs ONE JavaScript file in Apple's JavaScriptCore and prints what the script writes with console.log. Nothing else.
//   setu-jsc --script FILE        (the contract yt-dlp uses for its QuickJS runtime)
//   setu-jsc -                    (script on stdin, the contract it uses for Deno/Node/Bun)
//   setu-jsc --version | --help
// Isolation: a fresh process and a fresh JSVirtualMachine per run; no DOM, no window, no fetch/XMLHttpRequest/timers, no module loader and no file or network API exist in a bare JSContext.
// Before the script runs the process enters a deny-by-default sandbox (no files, no network, no processes, no IPC), so even an engine bug cannot reach cookies,
// profiles or the web. A wall-clock limit ends the process. The solver is run with the JIT off unless BS_JSC_JIT=1: slower, but needs no relaxed code-signing entitlement.
import Foundation
import JavaScriptCore
import Darwin

@_silgen_name("sandbox_init") func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
// A custom profile, not the named "pure-computation" one: on macOS 27 the named profile terminates the process. Deny by default; the only things left are reading kernel/CPU facts the
// engine asks for and signalling itself. No file read or write, no network, no processes, no IPC. (sandbox_init is deprecated but is what Chromium and Safari's helpers build on.)
let sandboxProfile = """
(version 1)
(deny default)
(allow sysctl-read)
(allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/private/var/db/timezone"))   ; the OS's own locale (ICU) and timezone data, read lazily by Number/Date formatting; nothing of the user's
(allow signal (target self))
(allow process-info-pidinfo (target self))
(deny network*)
(deny process-fork)
(deny process-exec*)
(deny file-write*)
"""
let version = "0.1.0"
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.first == "--help" || args.first == "-h" {
    print("Browser Setu JavaScriptCore runner \(version)\nusage: setu-jsc --script FILE | -   (runs one script; console.log goes to stdout)"); exit(args.isEmpty ? 1 : 0)
}
if args.first == "--version" { print("setu-jsc \(version)"); exit(0) }

var limit: UInt32 = 120
if let i = args.firstIndex(of: "--timeout"), i + 1 < args.count, let n = UInt32(args[i + 1]) { limit = n; args.removeSubrange(i...(i + 1)) }

var source: Data
if args.count == 2, args[0] == "--script" {
    guard let d = FileManager.default.contents(atPath: args[1]) else { err("cannot read \(args[1])"); exit(2) }
    source = d
} else if args.last == "-" {
    source = FileHandle.standardInput.readDataToEndOfFile()
} else { err("bad arguments"); exit(2) }
guard let script = String(data: source, encoding: .utf8) else { err("script is not UTF-8"); exit(2) }

// JIT off by default (set before the VM exists; JavaScriptCore reads JSC_* options when it starts).
if ProcessInfo.processInfo.environment["BS_JSC_JIT"] != "1" { setenv("JSC_useJIT", "false", 1) }

let vm = JSVirtualMachine()!
let ctx = JSContext(virtualMachine: vm)!
var failed = false
_ = ctx.evaluateScript("0")        // warm-up: the engine starts its helper threads and maps what it needs BEFORE access is withdrawn
// Everything the script needs is loaded into memory; now give up all file, network and process access.
if ProcessInfo.processInfo.environment["BS_JSC_NOSANDBOX"] != "1" {
    var errBuf: UnsafeMutablePointer<CChar>? = nil
    if sandbox_init(sandboxProfile, 0, &errBuf) != 0 {
        err("sandbox refused: \(errBuf.map { String(cString: $0) } ?? "unknown")"); exit(3)      // fail closed: never run a script unconfined
    }
}
alarm(limit)          // SIGALRM ends the process; there is no way for the script to catch or extend it

ctx.exceptionHandler = { _, e in failed = true; err("JavaScript error: \(e?.toString() ?? "unknown")") }
let console = JSValue(newObjectIn: ctx)!
let out = FileHandle.standardOutput
let log: @convention(block) () -> Void = {
    let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.isString ? $0.toString()! : ($0.toString() ?? "") }
    out.write(Data((parts.joined(separator: " ") + "\n").utf8))
}
let elog: @convention(block) () -> Void = {
    let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
    err(parts.joined(separator: " "))
}
console.setValue(log, forProperty: "log"); console.setValue(log, forProperty: "info"); console.setValue(elog, forProperty: "error"); console.setValue(elog, forProperty: "warn")
ctx.setObject(console, forKeyedSubscript: "console" as NSString)
ctx.evaluateScript(script, withSourceURL: URL(string: "solver.js"))
exit(failed ? 1 : 0)
