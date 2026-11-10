import Foundation
import JavaScriptCore
@_silgen_name("sandbox_init") func sandbox_init(_ p: UnsafePointer<CChar>, _ f: UInt64, _ e: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
let profile = """
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
let vm = JSVirtualMachine()!; let ctx = JSContext(virtualMachine: vm)!; _ = ctx.evaluateScript("1")
var eb: UnsafeMutablePointer<CChar>? = nil
let r = ProcessInfo.processInfo.environment["BS_PROBE_NOINIT"] == "1" ? 0 : sandbox_init(profile, 0, &eb); print("sandbox_init:", r, eb.map { String(cString: $0) } ?? "")
func probe(_ n: String, _ ok: Bool) { print("\(n): \(ok ? "ALLOWED  <-- not isolated" : "denied")") }
let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)      // the REAL home, not the sandbox container's
probe("list ~/Documents", opendir(home + "/Documents") != nil)
probe("list ~/Library/Application Support/BrowserSetu", opendir(home + "/Library/Application Support/BrowserSetu") != nil)
probe("list ~/Library/Application Support (any profile data)", opendir(home + "/Library/Application Support") != nil)
probe("list ~/Library/Cookies", opendir(home + "/Library/Cookies") != nil)
probe("read ~/.zshrc or ~/.zprofile", fopen(home + "/.zshrc", "r") != nil || fopen(home + "/.zprofile", "r") != nil)
probe("read ~/Library/Application Support", opendir(home + "/Library/Application Support") != nil)
probe("read /etc/hosts", fopen("/etc/hosts", "r") != nil)
probe("write /tmp/x", fopen("/tmp/sb3-x", "w") != nil)
let s = socket(AF_INET, SOCK_STREAM, 0)
var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(53).bigEndian; addr.sin_addr.s_addr = inet_addr("1.1.1.1"); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
probe("socket+connect 1.1.1.1:53", s >= 0 && withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
var pid: pid_t = 0; probe("posix_spawn /bin/echo", posix_spawn(&pid, "/bin/echo", nil, nil, [strdup("echo"), nil], nil) == 0)
// the engine still has to work, including a real allocation- and thread-heavy workload
let t0 = Date()
let v = ctx.evaluateScript("var a=[];for(var i=0;i<3e5;i++)a.push({i:i,s:'x'+i});JSON.stringify(a).length")!
print("JS after sandbox: length", v.toInt32(), "in", String(format: "%.2fs", Date().timeIntervalSince(t0)))
