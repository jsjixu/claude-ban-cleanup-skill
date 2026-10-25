import AppKit

// Claude Link Router — 默认浏览器路由器：claude 系域名 → 隔离浏览器，其它 → 个人浏览器。
// 配置优先级：~/.config/claude-link-router.json {"launcher","personalBrowser","hosts":[...]}
//             > 环境变量（.app 启动拿不到 shell env，仅兜底）
//             > 默认值（~/.local/bin/claude-browser / /Applications/Google Chrome.app）

struct RouterConfig: Decodable {
    let launcher: String?
    let personalBrowser: String?
    let hosts: [String]?
}

let defaultHosts = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com", "claudemcpcontent.com", "claude.app"]

let cfgFile = NSHomeDirectory() + "/.config/claude-link-router.json"
var launcher = ProcessInfo.processInfo.environment["CLAUDE_BROWSER_LAUNCHER"]
    ?? NSHomeDirectory() + "/.local/bin/claude-browser"
var personal = ProcessInfo.processInfo.environment["CLAUDE_PERSONAL_BROWSER"]
    ?? "/Applications/Google Chrome.app"
var hosts = defaultHosts
if let data = FileManager.default.contents(atPath: cfgFile),
   let cfg = try? JSONDecoder().decode(RouterConfig.self, from: data) {
    if let v = cfg.launcher { launcher = v }
    if let v = cfg.personalBrowser { personal = v }
    if let h = cfg.hosts, !h.isEmpty { hosts = h }
}

let logPath = NSHomeDirectory() + "/Library/Logs/claude-link-router.log"

func isClaudeHost(_ host: String) -> Bool {
    let h = host.lowercased()
    for d in hosts where h == d || h.hasSuffix("." + d) { return true }
    return false
}

func logRoute(_ host: String, _ target: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(host.lowercased()) -> \(target)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

var recent: [String: Date] = [:]
func route(_ url: URL) {
    let key = url.absoluteString
    if let t = recent[key], Date().timeIntervalSince(t) < 3 { return }
    recent[key] = Date()
    let host = url.host ?? ""
    if isClaudeHost(host) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [launcher, key]
        try? p.run()
        logRoute(host, "isolated")
    } else {
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: personal), configuration: cfg) { _, _ in }
        logRoute(host, "personal")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var exitTimer: Timer?
    var setDefaultPending = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        if CommandLine.arguments.contains("--set-default") {
            setDefault()
        } else {
            // URL 经 AppleEvent 送达而非 argv；留一拍等它落地再退。
            scheduleExit(1.0)
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
           let url = URL(string: s) {
            route(url)
        }
        scheduleExit(1.5)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { route(u) }
        scheduleExit(1.5)
    }

    func scheduleExit(_ delay: TimeInterval) {
        exitTimer?.invalidate()
        exitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }

    func setDefault() {
        exitTimer?.invalidate()
        setDefaultPending = 2
        let appURL = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { err in
                if let err = err {
                    FileHandle.standardError.write(("setDefault \(scheme) error: \(err.localizedDescription)\n").data(using: .utf8)!)
                }
                self.setDefaultPending -= 1
                if self.setDefaultPending <= 0 { NSApp.terminate(nil) }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
