// DevServers — macOS menu bar monitor for local dev servers.
// Lists listening TCP ports with repo, branch/worktree, process tree, origin
// (terminal app / tmux / T3 Code thread) and stops a server's whole process tree.

import AppKit
import ServiceManagement

// MARK: - Shell helpers

@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let t3Home = ProcessInfo.processInfo.environment["T3CODE_HOME"] ?? "\(home)/.t3"
let t3DB = "\(t3Home)/userdata/statev2.sqlite"

// MARK: - Model

struct ProcInfo {
    let pid: Int32
    let ppid: Int32
    let etime: String
    let lstart: String
    let command: String
    var exe: String { (command.split(separator: " ").first.map(String.init) ?? command) }
    var name: String {
        let n = (exe as NSString).lastPathComponent
        return n.hasPrefix("-") ? String(n.dropFirst()) : n
    }
}

struct GitInfo {
    let toplevel: String
    let branch: String
    let repo: String
    let isWorktree: Bool
}

struct T3Thread {
    let id: String
    let title: String
    let worktreePath: String?
    let projectTitle: String?
    let updatedAt: String
}

struct DevServer {
    let pid: Int32
    let ports: [Int]
    let proc: ProcInfo
    let cwd: String
    let git: GitInfo?
    let root: ProcInfo          // top of the server's own process tree (what "Stop" kills)
    let chain: [ProcInfo]       // listening proc → root
    let origin: String          // e.g. "cmux · tmux", "T3 Code", "VS Code"
    let thread: T3Thread?
    let threadMatch: String?    // "started by" | "same worktree"
    let isDev: Bool

    var displayName: String {
        if let g = git {
            let wtName = (g.toplevel as NSString).lastPathComponent
            return g.isWorktree && wtName != g.repo ? "\(g.repo) ▸ \(wtName)" : g.repo
        }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - Collector

enum Collector {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "nu"]
    static let hardBoundaries: Set<String> = ["tmux", "screen", "launchd", "login", "claude", "codex", "t3", "zellij", "sshd"]
    static let bundleNames: [String: String] = [
        "com.cmuxterm.app": "cmux", "com.microsoft.VSCode": "VS Code", "com.mitchellh.ghostty": "Ghostty",
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "com.t3tools.t3code": "T3 Code",
        "dev.warp.Warp-Stable": "Warp", "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.Zed": "Zed",
        "com.jetbrains.intellij": "IntelliJ", "net.kovidgoyal.kitty": "kitty", "org.alacritty": "Alacritty",
    ]

    static func isBoundary(_ p: ProcInfo) -> Bool {
        if p.pid <= 1 { return true }
        if p.command.contains(".app/Contents/") { return true }
        if hardBoundaries.contains(p.name) { return true }
        // Interactive / login shells are boundaries; `sh -c "npm run x"` wrappers belong to the server.
        if shells.contains(p.name) { return !p.command.contains(" -c ") }
        return false
    }

    static func snapshot() -> [Int32: ProcInfo] {
        var map: [Int32: ProcInfo] = [:]
        for line in run("/bin/ps", ["-axww", "-o", "pid=,ppid=,etime=,lstart=,command="]).split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count >= 9, let pid = Int32(t[0]), let ppid = Int32(t[1]) else { continue }
            map[pid] = ProcInfo(pid: pid, ppid: ppid, etime: String(t[2]),
                                lstart: t[3...7].joined(separator: " "),
                                command: t[8...].joined(separator: " "))
        }
        return map
    }

    static func listeners() -> [Int32: [Int]] {
        var res: [Int32: Set<Int>] = [:]
        var cur: Int32 = 0
        for line in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") { cur = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), let c = line.lastIndex(of: ":"), let port = Int(line[line.index(after: c)...]) {
                res[cur, default: []].insert(port)
            }
        }
        return res.mapValues { $0.sorted() }
    }

    static func cwds(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        var res: [Int32: String] = [:]
        var cur: Int32 = 0
        let list = pids.map(String.init).joined(separator: ",")
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") { cur = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { res[cur] = String(line.dropFirst()) }
        }
        return res
    }

    static let envKeys = ["T3CODE_THREAD_ID", "__CFBundleIdentifier", "TERM_PROGRAM", "TMUX", "CLAUDE_CODE_SESSION_ID", "CODEX_SOCKET_PATH"]
    static func envs(_ pids: [Int32]) -> [Int32: [String: String]] {
        guard !pids.isEmpty else { return [:] }
        var res: [Int32: [String: String]] = [:]
        let out = run("/bin/ps", ["eww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")])
        for line in out.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let sp = s.firstIndex(of: " "), let pid = Int32(s[..<sp]) else { continue }
            var env: [String: String] = [:]
            for key in envKeys {
                if let r = s.range(of: " \(key)=") {
                    let rest = s[r.upperBound...]
                    env[key] = String(rest.prefix { $0 != " " })
                }
            }
            res[pid] = env
        }
        return res
    }

    /// Run closures concurrently and return their results in order.
    static func parallel<T>(_ jobs: [() -> T]) -> [T] {
        var out = [T?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let r = jobs[i]()
            lock.lock(); out[i] = r; lock.unlock()
        }
        return out.map { $0! }
    }

    static func git(_ dir: String) -> GitInfo? {
        let out = run("/usr/bin/git", ["-C", dir, "rev-parse", "--path-format=absolute", "--show-toplevel",
                                       "--abbrev-ref", "HEAD", "--git-dir", "--git-common-dir"])
        let l = out.split(separator: "\n").map(String.init)
        guard l.count >= 4 else { return nil }
        let common = l[3]
        let repo = common.hasSuffix("/.git") ? ((common as NSString).deletingLastPathComponent as NSString).lastPathComponent
                                             : (common as NSString).lastPathComponent
        return GitInfo(toplevel: l[0], branch: l[1] == "HEAD" ? "(detached)" : l[1], repo: repo, isWorktree: l[2] != common)
    }

    static func t3Threads() -> [T3Thread] {
        guard FileManager.default.fileExists(atPath: t3DB) else { return [] }
        let sql = """
        select t.thread_id as id, t.title as title, json_extract(t.payload_json,'$.worktreePath') as wt,
               p.title as project, t.updated_at as updated
        from orchestration_v2_projection_threads t
        left join projection_projects p on p.project_id = t.project_id
        where t.deleted_at is null;
        """
        let out = run("/usr/bin/sqlite3", ["-readonly", "-json", "file:\(t3DB)?mode=ro", sql])
        guard let data = out.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return T3Thread(id: id, title: r["title"] as? String ?? id, worktreePath: r["wt"] as? String,
                            projectTitle: r["project"] as? String, updatedAt: r["updated"] as? String ?? "")
        }
    }

    static func t3EnvironmentId() -> String? {
        (try? String(contentsOfFile: "\(t3Home)/userdata/environment-id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let procsLock = NSLock()

    static func collect() -> [DevServer] {
        var procs: [Int32: ProcInfo] = [:]
        var ls: [Int32: [Int]] = [:]
        var threads: [T3Thread] = []
        DispatchQueue.concurrentPerform(iterations: 3) { i in
            switch i {
            case 0: let v = snapshot(); procsLock.lock(); procs = v; procsLock.unlock()
            case 1: let v = listeners(); procsLock.lock(); ls = v; procsLock.unlock()
            default: let v = t3Threads(); procsLock.lock(); threads = v; procsLock.unlock()
            }
        }
        let myPid = getpid()
        let pids = ls.keys.filter { $0 != myPid && procs[$0] != nil }

        // Chains and roots
        var chains: [Int32: [ProcInfo]] = [:]
        for pid in pids {
            var chain: [ProcInfo] = []
            var cur = procs[pid]
            while let c = cur, chain.count < 40 {
                chain.append(c)
                cur = procs[c.ppid]
                if let n = cur, isBoundary(n) { chain.append(n); break }
            }
            chains[pid] = chain
        }
        // Env of the listener plus its boundary process (origin hints)
        var envPids = Set(pids)
        for c in chains.values { if let b = c.last { envPids.insert(b.pid) } }
        var cwdMap: [Int32: String] = [:]
        var envMap: [Int32: [String: String]] = [:]
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 { let v = cwds(pids); procsLock.lock(); cwdMap = v; procsLock.unlock() }
            else { let v = envs(Array(envPids)); procsLock.lock(); envMap = v; procsLock.unlock() }
        }
        let devDirs = Array(Set(pids.compactMap { pid -> String? in
            guard let c = cwdMap[pid], let p = procs[pid], !p.command.contains(".app/Contents/"), c.hasPrefix(home + "/") else { return nil }
            return c
        }))
        let gits = parallel(devDirs.map { d in { git(d) } })
        let gitMap = Dictionary(uniqueKeysWithValues: zip(devDirs, gits))
        let threadById = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var result: [DevServer] = []
        for pid in pids {
            guard let proc = procs[pid], let chain = chains[pid] else { continue }
            let cwd = cwdMap[pid] ?? "/"
            let inside = chain.filter { !isBoundary($0) }
            let root = inside.last ?? proc
            let boundary = chain.last.flatMap { isBoundary($0) ? $0 : nil }

            let isApp = proc.command.contains(".app/Contents/")
            let isDev = !isApp && cwd.hasPrefix(home + "/")

            let g: GitInfo? = isDev ? (gitMap[cwd] ?? nil) : nil

            // Origin
            let env = envMap[pid] ?? [:]
            var originParts: [String] = []
            if let b = env["__CFBundleIdentifier"] { originParts.append(bundleNames[b] ?? b) }
            if env["TMUX"] != nil || boundary?.name == "tmux" || env["TERM_PROGRAM"] == "tmux" { originParts.append("tmux") }
            if env["CLAUDE_CODE_SESSION_ID"] != nil { originParts.append("Claude Code") }
            if env["CODEX_SOCKET_PATH"] != nil && env["__CFBundleIdentifier"] == nil { originParts.append("Codex") }
            if originParts.isEmpty, let b = boundary { originParts.append(b.pid <= 1 ? "launchd (detached)" : b.name) }
            var seen = Set<String>()
            originParts = originParts.filter { seen.insert($0).inserted }

            // T3 thread
            var thread: T3Thread? = nil
            var match: String? = nil
            if let tid = env["T3CODE_THREAD_ID"] {
                thread = threadById[tid] ?? T3Thread(id: tid, title: tid, worktreePath: nil, projectTitle: nil, updatedAt: "")
                match = "started by"
            } else if isDev {
                let base = g?.toplevel ?? cwd
                let cands = threads.filter { t in
                    guard let wt = t.worktreePath, wt.hasPrefix("\(t3Home)/worktrees/") else { return false }
                    return base == wt || base.hasPrefix(wt + "/")
                }
                if let best = cands.max(by: { $0.updatedAt < $1.updatedAt }) { thread = best; match = "same worktree" }
            }

            result.append(DevServer(pid: pid, ports: ls[pid] ?? [], proc: proc, cwd: cwd, git: g, root: root,
                                    chain: chain, origin: originParts.joined(separator: " · "),
                                    thread: thread, threadMatch: match, isDev: isDev))
        }
        return result.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    /// SIGTERM the root and all descendants; SIGKILL survivors after a grace period.
    static func stop(_ s: DevServer, completion: @escaping (Bool) -> Void) {
        let procs = snapshot()
        guard let r = procs[s.root.pid], r.lstart == s.root.lstart, !isBoundary(r) else { completion(false); return }
        var children: [Int32: [Int32]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }
        var tree: [Int32] = []
        var stack = [r.pid]
        while let x = stack.popLast() { tree.append(x); stack += children[x] ?? [] }
        let startTimes = Dictionary(uniqueKeysWithValues: tree.compactMap { pid in procs[pid].map { (pid, $0.lstart) } })
        for pid in tree.reversed() { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let now = snapshot()
            for pid in tree where now[pid]?.lstart == startTimes[pid] { kill(pid, SIGKILL) }
            DispatchQueue.main.async { completion(true) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var servers: [DevServer] = []
    var showAll = UserDefaults.standard.bool(forKey: "showAll")
    var stopping: Set<Int32> = []
    var timer: Timer?
    let queue = DispatchQueue(label: "collector")
    let t3Env = Collector.t3EnvironmentId()

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Dev servers")
            b.imagePosition = .imageLeading
        }
        refresh()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // keep refreshing while the menu is open
        timer = t
    }

    var visible: [DevServer] { showAll ? servers : servers.filter { $0.isDev } }

    func refresh(then: (() -> Void)? = nil) {
        queue.async {
            let s = Collector.collect()
            DispatchQueue.main.async {
                self.servers = s
                let n = s.filter { $0.isDev }.count
                self.statusItem.button?.title = n > 0 ? " \(n)" : ""
                if self.menuOpen && self.signature() != self.builtSignature { self.build() }
                then?()
            }
        }
    }

    var menuOpen = false
    var builtSignature = ""

    func signature() -> String {
        visible.map { "\($0.root.pid):\($0.ports):\($0.git?.branch ?? ""):\(stopping.contains($0.root.pid))" }.joined(separator: "|")
            + "\(showAll)"
    }

    // Open instantly from cache, then refresh and rebuild in place if anything changed.
    func menuNeedsUpdate(_ menu: NSMenu) { build() }
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: Menu

    func header(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func info(_ text: String, symbol: String? = nil, copy: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: copy != nil ? #selector(copyText(_:)) : nil, keyEquivalent: "")
        i.target = self
        i.representedObject = copy
        i.isEnabled = copy != nil
        if let s = symbol { i.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        if copy != nil { i.toolTip = "Click to copy" }
        return i
    }

    func action(_ title: String, symbol: String, _ sel: Selector, _ obj: Any?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = obj
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return i
    }

    func short(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
    func trunc(_ s: String, _ n: Int = 70) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    func build() {
        builtSignature = signature()
        menu.removeAllItems()
        // Group by repo (non-git processes by directory name), then by port; separator between groups.
        func repoKey(_ s: DevServer) -> String {
            (s.isDev ? "0" : "1") + (s.git?.repo ?? (s.cwd as NSString).lastPathComponent).lowercased()
        }
        let list = visible.sorted { a, b in
            let ka = repoKey(a), kb = repoKey(b)
            return ka != kb ? ka < kb : (a.ports.first ?? 0) < (b.ports.first ?? 0)
        }
        if list.isEmpty {
            menu.addItem(header(showAll ? "No listening processes" : "No dev servers running"))
        }
        var lastKey: String? = nil
        for s in list {
            let key = repoKey(s)
            if let lk = lastKey, lk != key { menu.addItem(.separator()) }
            lastKey = key
            let ports = s.ports.map { ":\($0)" }.joined(separator: " ")
            let title = NSMutableAttributedString(string: "\(ports)  ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)])
            title.append(NSAttributedString(string: s.displayName, attributes: [.font: NSFont.menuFont(ofSize: 13)]))

            let item = NSMenuItem(title: "\(ports) \(s.displayName)", action: #selector(openBrowser(_:)), keyEquivalent: "")
            item.attributedTitle = title
            item.target = self
            item.representedObject = s.ports.first
            var sub: [String] = []
            if let g = s.git { sub.append("⎇ \(g.branch)") }
            sub.append(s.proc.name)
            if let t = s.thread { sub.append("T3: \(trunc(t.title, 40))") } else if !s.origin.isEmpty { sub.append(s.origin) }
            item.subtitle = sub.joined(separator: "  ·  ")
            if stopping.contains(s.root.pid) { item.subtitle = "Stopping…" }
            item.image = NSImage(systemSymbolName: s.thread != nil ? "bubble.left.and.text.bubble.right.fill" : "circle.fill",
                                 accessibilityDescription: nil)
            if s.thread == nil {
                item.image = item.image?.withSymbolConfiguration(.init(paletteColors: [s.isDev ? .systemGreen : .tertiaryLabelColor]))
                    .flatMap { img in img.size = NSSize(width: 8, height: 8); return img }
            }

            // Submenu with details & actions
            let m = NSMenu()
            m.autoenablesItems = false
            m.addItem(action("Stop server", symbol: "stop.circle", #selector(stopServer(_:)), s.root.pid))
            if let p = s.ports.first {
                m.addItem(action("Open http://localhost:\(p)", symbol: "safari", #selector(openBrowser(_:)), p))
            }
            if let t = s.thread {
                m.addItem(action("Open T3 thread: \(trunc(t.title, 50))", symbol: "bubble.left.and.text.bubble.right",
                                 #selector(openThread(_:)), t.id))
            }
            m.addItem(action("Reveal in Finder", symbol: "folder", #selector(reveal(_:)), s.git?.toplevel ?? s.cwd))
            m.addItem(.separator())
            if let g = s.git {
                m.addItem(header("Repository"))
                m.addItem(info(g.repo, symbol: "shippingbox", copy: g.repo))
                m.addItem(info(g.branch, symbol: "arrow.triangle.branch", copy: g.branch))
                m.addItem(info((g.isWorktree ? "worktree  " : "") + short(g.toplevel), symbol: "folder", copy: g.toplevel))
                if s.cwd != g.toplevel { m.addItem(info("cwd  " + short(s.cwd), symbol: "folder.badge.gearshape", copy: s.cwd)) }
            } else {
                m.addItem(header("Directory"))
                m.addItem(info(short(s.cwd), symbol: "folder", copy: s.cwd))
            }
            m.addItem(.separator())
            m.addItem(header("Process  (up \(s.proc.etime))"))
            m.addItem(info("\(s.proc.pid)  \(trunc(short(s.proc.command)))", symbol: "terminal", copy: s.proc.command))
            if s.root.pid != s.proc.pid {
                m.addItem(info("started by \(s.root.pid)  \(trunc(short(s.root.command)))", symbol: "arrow.turn.left.up",
                               copy: s.root.command))
            }
            let chainText = s.chain.reversed().map { "\($0.name)(\($0.pid))" }.joined(separator: " → ")
            m.addItem(info(trunc(chainText, 90), symbol: "list.bullet.indent", copy: chainText))
            if !s.origin.isEmpty { m.addItem(info("from \(s.origin)", symbol: "macwindow")) }
            if let t = s.thread {
                m.addItem(.separator())
                m.addItem(header("T3 Code thread (\(s.threadMatch ?? ""))"))
                m.addItem(info(trunc(t.title, 60), symbol: "text.bubble", copy: t.title))
                if let p = t.projectTitle { m.addItem(info("project  \(p)", symbol: "square.stack")) }
                m.addItem(info(t.id, symbol: "number", copy: t.id))
            }
            item.submenu = m
            menu.addItem(item)

            // Hold ⌥ to turn the row into a one-click Stop.
            let alt = NSMenuItem(title: "Stop \(ports)  \(s.displayName)", action: #selector(stopServer(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = s.root.pid
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            alt.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            alt.subtitle = "Kills pid \(s.root.pid) and its children"
            menu.addItem(alt)
        }

        menu.addItem(.separator())
        let tip = header("Hold ⌥ and click a row to stop it")
        tip.attributedTitle = NSAttributedString(string: tip.title, attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(tip)
        if list.contains(where: { $0.isDev }) {
            menu.addItem(action("Stop all dev servers…", symbol: "stop.fill", #selector(stopAll(_:)), nil))
        }
        let all = action("Show all listening processes", symbol: "eye", #selector(toggleAll(_:)), nil)
        all.state = showAll ? .on : .off
        all.image = nil
        menu.addItem(all)
        let login = action("Launch at login", symbol: "power", #selector(toggleLogin(_:)), nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.image = nil
        menu.addItem(login)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit DevServers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
    }

    // MARK: Actions

    @objc func copyText(_ i: NSMenuItem) {
        guard let s = i.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func openBrowser(_ i: NSMenuItem) {
        guard let p = i.representedObject as? Int, let u = URL(string: "http://localhost:\(p)") else { return }
        NSWorkspace.shared.open(u)
    }

    @objc func openThread(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String else { return }
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        if let env = t3Env, let u = URL(string: "t3code://threads/\(env)/\(enc)") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func reveal(_ i: NSMenuItem) {
        guard let p = i.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc func stopServer(_ i: NSMenuItem) {
        guard let pid = i.representedObject as? Int32, let s = servers.first(where: { $0.root.pid == pid }) else { return }
        stop([s])
    }

    @objc func stopAll(_ i: NSMenuItem) {
        let targets = servers.filter { $0.isDev }
        let a = NSAlert()
        a.messageText = "Stop \(targets.count) dev server\(targets.count == 1 ? "" : "s")?"
        a.informativeText = targets.map { "\($0.ports.map { ":\($0)" }.joined(separator: " "))  \($0.displayName)" }
            .joined(separator: "\n")
        a.addButton(withTitle: "Stop all")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { stop(targets) }
    }

    func stop(_ list: [DevServer]) {
        var seen = Set<Int32>()
        for s in list where seen.insert(s.root.pid).inserted {
            stopping.insert(s.root.pid)
            if menuOpen { build() }
            Collector.stop(s) { ok in
                self.stopping.remove(s.root.pid)
                if !ok { self.notify("Could not stop \(s.displayName)", "The process changed or is protected.") }
                self.refresh()
            }
        }
    }

    func notify(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func toggleAll(_ i: NSMenuItem) {
        showAll.toggle()
        UserDefaults.standard.set(showAll, forKey: "showAll")
    }

    @objc func toggleLogin(_ i: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { notify("Launch at login failed", error.localizedDescription) }
    }
}

// CLI mode for debugging: `DevServers --list`
if CommandLine.arguments.contains("--list") {
    for s in Collector.collect() where s.isDev || CommandLine.arguments.contains("--all") {
        print(s.ports.map(String.init).joined(separator: ","), s.displayName, s.git?.branch ?? "-",
              "pid=\(s.proc.pid)", "root=\(s.root.pid):\(s.root.name)", "origin=\(s.origin)",
              s.thread.map { "t3=\($0.title) [\(s.threadMatch ?? "")]" } ?? "", separator: " | ")
    }
    exit(0)
}
// `DevServers --stop <port>` stops the server tree listening on that port (same logic as the menu).
if let i = CommandLine.arguments.firstIndex(of: "--stop"), i + 1 < CommandLine.arguments.count,
   let port = Int(CommandLine.arguments[i + 1]) {
    guard let s = Collector.collect().first(where: { $0.ports.contains(port) }) else { print("nothing on :\(port)"); exit(1) }
    print("stopping root \(s.root.pid) (\(s.root.command))")
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    Collector.stop(s) { r in ok = r; sem.signal() }
    while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date() + 0.05) }
    print(ok ? "stopped" : "refused")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
