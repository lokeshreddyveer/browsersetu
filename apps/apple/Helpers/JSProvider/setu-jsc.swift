// setu-jsc: Browser Setu's JavaScript challenge runner for yt-dlp. It runs ONE script, read from standard input, in Apple's JavaScriptCore and prints what the script writes with console.log.
// Nothing else exists in it: no DOM, window, fetch, XMLHttpRequest, timers, WebAssembly, module loader, file or network API (a bare JSContext has none; WebAssembly is removed), and it shares nothing with
// the browser's WKWebView pages, their cookies, profiles or user data: it is a separate process with a fresh JSVirtualMachine per run.
//
// Confinement comes from the operating system, not from this code: the helper is signed with the App Sandbox entitlement and NO other (no network, no file access, no JIT), so macOS itself denies it
// the user's files, the network and the browser's data. It REFUSES to run unless the kernel says it is sandboxed (sandbox_check, not an environment variable a launcher could set): fail closed.
//
// Contract with yt-dlp's provider plugin (protocol 1):
//   setu-jsc --version                 prints  "setu-jsc <version> protocol <n>"
//   setu-jsc [--deadline S] -          script on stdin, result on stdout; --deadline S (1...300, default 120) is the wall-clock limit in seconds
// Limits (all enforced here, whatever the script does): input 16 MB (the wall-clock deadline also covers reading it); stdout 8 MB; stderr 64 KB; wall-clock S seconds; CPU 120 s; memory footprint 1 GiB.
// Failures are classified by exit status and the first words on stderr, so the caller never has to guess:
//   0 ok | 1 [js-error] the script threw | 2 [input] bad arguments, not UTF-8 or too large | 3 [unsandboxed] | 4 [output-limit] | 5 [memory-limit] | killed by SIGALRM/SIGXCPU: [deadline]
// Development builds (-D BS_DEV only) may run unsandboxed and read a script file; a release build has neither.
import Foundation
import JavaScriptCore
import Darwin

// The kernel's own answer about THIS process (libsystem_sandbox). 1 = denied. A sandboxed helper has no network entitlement, so "network-outbound" must be denied; anything else (allowed, or an error) means
// nothing confines us. Declared with no variadic arguments (filter 0), which is safe to call from Swift.
@_silgen_name("sandbox_check") func sandbox_check(_ pid: Int32, _ operation: UnsafePointer<CChar>, _ filterType: Int32) -> Int32
let version = "1.0.0"
let protocolVersion = 1
let maxInput = 16 << 20, maxOutput = 8 << 20, maxStderr = 64 << 10, memoryLimit: UInt64 = 1 << 30

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
// _exit, not exit: from the watchdog thread exit() would run atexit handlers while the script thread is still running.
func die(_ code: Int32, _ cls: String, _ message: String) -> Never { err("setu-jsc: [\(cls)] \(message)"); _exit(code) }

var args = Array(CommandLine.arguments.dropFirst())
if args == ["--version"] { print("setu-jsc \(version) protocol \(protocolVersion)"); exit(0) }
if args == ["--help"] { print("Browser Setu JavaScriptCore runner \(version) (protocol \(protocolVersion))\nusage: setu-jsc [--deadline SECONDS] -   (runs the script on standard input; console.log goes to standard output)"); exit(0) }

var deadline: UInt32 = 120
if args.count == 3, args[0] == "--deadline" {
    guard let d = UInt32(args[1]), (1...300).contains(d) else { die(2, "input", "deadline must be 1...300 seconds") }
    deadline = d; args.removeFirst(2)
}
#if BS_DEV
let devScriptPath: String? = (args.count == 2 && args[0] == "--script") ? args[1] : nil
guard devScriptPath != nil || args == ["-"] else { die(2, "input", "bad arguments") }
let mustBeSandboxed = ProcessInfo.processInfo.environment["BS_JSC_ALLOW_UNSANDBOXED"] != "1"
#else
guard args == ["-"] else { die(2, "input", "bad arguments") }
let mustBeSandboxed = true
#endif

// Fail closed, using the KERNEL's answer: a process with no network entitlement that is really in the App Sandbox is denied "network-outbound". The old environment-variable check could be satisfied by
// whoever launched an unconfined copy of this program.
if mustBeSandboxed && sandbox_check(getpid(), "network-outbound", 0) != 1 { die(3, "unsandboxed", "the operating system does not report this process as sandboxed; refusing to run a script unconfined") }

// Deadlines the script cannot catch, mask or extend, armed BEFORE anything is read so a stdin that never closes cannot hold the helper: wall-clock (SIGALRM) and CPU time (SIGXCPU, all threads together).
signal(SIGALRM, SIG_DFL); alarm(deadline)
var cpu = rlimit(rlim_cur: 120, rlim_max: 130); setrlimit(RLIMIT_CPU, &cpu)

// Input: read in pieces and stop as soon as it is too large, instead of reading without a bound.
func readInput() -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = read(0, &buffer, buffer.count)
        if n < 0 { if errno == EINTR { continue }; die(2, "input", "cannot read the script") }
        if n == 0 { break }
        data.append(buffer, count: n)
        if data.count > maxInput { die(2, "input", "script is larger than 16 MB") }
    }
    return data
}
var source: Data
#if BS_DEV
if let path = devScriptPath { guard let d = FileManager.default.contents(atPath: path) else { die(2, "input", "cannot read \(path)") }; source = d } else { source = readInput() }
#else
source = readInput()
#endif
guard let script = String(data: source, encoding: .utf8) else { die(2, "input", "script is not UTF-8") }

// Memory: JavaScriptCore offers no public heap limit, so a watchdog thread reads this process's own footprint twenty times a second and ends it above the limit.
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}
let watchdog = Thread {
    while true { usleep(50_000); if footprint() > memoryLimit { die(5, "memory-limit", "the script used more than 1 GiB") } }
}
watchdog.start()

let vm = JSVirtualMachine()!
let ctx = JSContext(virtualMachine: vm)!
var failed = false
ctx.exceptionHandler = { _, e in failed = true; err("setu-jsc: [js-error] " + String((e?.toString() ?? "unknown").prefix(300)).replacingOccurrences(of: "\n", with: " ")) }
_ = ctx.evaluateScript("delete globalThis.WebAssembly;")      // not needed by any solver; one less engine surface

let console = JSValue(newObjectIn: ctx)!
var written = 0
let out = FileHandle.standardOutput
let log: @convention(block) () -> Void = {
    let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.isString ? $0.toString()! : ($0.toString() ?? "") }
    let data = Data((parts.joined(separator: " ") + "\n").utf8)
    written += data.count
    if written > maxOutput { die(4, "output-limit", "the script wrote more than 8 MB") }
    out.write(data)
}
var errWritten = 0
let elog: @convention(block) () -> Void = {
    // Diagnostics only, never the player or any page data: short, flattened, and capped in total so a script cannot flood the caller's memory through stderr.
    let line = "setu-jsc: [js-log] " + String(((JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }).joined(separator: " ").prefix(300)).replacingOccurrences(of: "\n", with: " ")
    errWritten += line.utf8.count + 1
    if errWritten > maxStderr { die(4, "output-limit", "the script wrote more than 64 KB of diagnostics") }
    err(line)
}
console.setValue(log, forProperty: "log"); console.setValue(log, forProperty: "info"); console.setValue(elog, forProperty: "error"); console.setValue(elog, forProperty: "warn")
ctx.setObject(console, forKeyedSubscript: "console" as NSString)
ctx.evaluateScript(script, withSourceURL: URL(string: "solver.js"))
exit(failed ? 1 : 0)
