import SwiftUI

func package(_ dir: String) -> [String: Any] {
    let url = URL(fileURLWithPath: dir).appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

final class Bar: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var root: String?
    var discovered = Set<String>()
    var excluded = Set<String>()
    var observed: [Listener] = []
    private(set) var live: [Listener] = []
    private(set) var stopped: [String] = []
    private var catalogDirs: [String] = []
    private(set) var scripts: [String: [String]] = [:]
    private var catalogID = UUID()
    private(set) var stopping = Set<UInt64>()
    var scanID = UUID()
    @Published var history = false
    let defaults = UserDefaults.standard
    var known: [String: String] = [:] // Working directory and last observed Node executable
    var launching = [String: Process]()
    var ips = [String]()
    struct RouteKey: Hashable {
        let pid: Int32
        let birth: UInt64
        let socket: String
        let address: String
    }
    var routes = [RouteKey: LocalRoute]()
    var routeURLs = [RouteKey: URL]()

    func openEndpoint(_ endpoint: Endpoint, service: Listener, retry: Bool = false) {
        guard endpoint.local else {
            if let url = URL(string: "http://" + endpoint.address) { NSWorkspace.shared.open(url) }
            return
        }
        guard let address = ips.first else { _ = alert("无法使用局域网地址", "请连接 Wi-Fi 或有线网络后重试。"); return }
        guard node_identity(service.pid) == service.birth,
              let split = endpoint.address.lastIndex(of: ":"),
              let port = UInt16(endpoint.address[endpoint.address.index(after: split)...]), port > 0 else { refresh(); return }
        let key = RouteKey(pid: service.pid, birth: service.birth, socket: endpoint.address, address: address)
        if let url = routeURLs[key] { NSWorkspace.shared.open(url); return }
        if routes[key] != nil { return }
        do {
            let host = String(endpoint.address[..<split]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let route = try LocalRoute(address: address, target: host, port: port, preservePort: !retry)
            routes[key] = route
            objectWillChange.send()
            route.start { [weak self, weak route] result in
                guard let self, let route, self.routes[key] === route else { return }
                switch result {
                case .success(let url):
                    self.routeURLs[key] = url
                    self.objectWillChange.send()
                    NSWorkspace.shared.open(url)
                case .failure(let error):
                    self.routes.removeValue(forKey: key)?.stop()
                    self.objectWillChange.send()
                    if retry { _ = self.alert("局域网地址打开失败", error.localizedDescription) }
                    else { self.openEndpoint(endpoint, service: service, retry: true) }
                }
            }
        } catch { _ = alert("局域网地址打开失败", error.localizedDescription) }
    }
    func isOpening(_ endpoint: Endpoint, service: Listener) -> Bool {
        guard endpoint.local, let address = ips.first else { return false }
        let key = RouteKey(pid: service.pid, birth: service.birth, socket: endpoint.address, address: address)
        return routes[key] != nil && routeURLs[key] == nil
    }
    func displayedAddress(_ endpoint: Endpoint, service: Listener) -> String {
        guard endpoint.local, let address = ips.first, let split = endpoint.address.lastIndex(of: ":") else { return endpoint.address }
        let key = RouteKey(pid: service.pid, birth: service.birth, socket: endpoint.address, address: address)
        if let port = routeURLs[key]?.port { return address + ":" + String(port) }
        return address + endpoint.address[split...]
    }

    var scanning = false
    var message = "正在扫描…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        known = defaults.dictionary(forKey: "projects") as? [String: String] ?? [:]
        item.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "NodeBar")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "NodeBar · 本地 Node 服务"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        panel.delegate = self
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: ProjectPanel(bar: self))
        excluded = Set(defaults.stringArray(forKey: "excluded") ?? [])
        selectRoot(defaults.string(forKey: "workspace"))
        refresh()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in self.refresh() }
    }
    func showPanel() {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrame(panelFrame(anchor: anchor, visible: screen.visibleFrame), display: true)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }
    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        showPanel()
        rebuildCatalog(reloadScripts: true)
        refresh()
    }
    func windowDidResignKey(_ notification: Notification) { panel.orderOut(nil) }

    func selectRoot(_ folder: String?) {
        root = folder.map(canonical)
        defaults.set(root, forKey: "workspace")
        catalogID = UUID()
        discovered = []
        catalogDirs = []
        scripts = [:]
        synchronizeLive()
        discover()
        objectWillChange.send()
    }
    func discover() {
        scanID = UUID()
        let request = scanID
        guard let root else { rebuildCatalog(reloadScripts: true); return }
        DispatchQueue.global(qos: .utility).async {
            let dirs = discoverProjects(in: root)
            DispatchQueue.main.async {
                guard request == self.scanID else { return }
                self.discovered = dirs
                self.rebuildCatalog(reloadScripts: true)
            }
        }
    }
    func chooseRoot() {
        let dialog = NSOpenPanel()
        dialog.title = "选择 Node 项目或工作区目录"
        dialog.prompt = "监控此目录"
        dialog.canChooseFiles = false
        dialog.canChooseDirectories = true
        dialog.directoryURL = root.map { URL(fileURLWithPath: $0) }
        panel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if dialog.runModal() == .OK, let url = dialog.url { selectRoot(url.path) }
        showPanel()
    }
    private func rebuildCatalog(reloadScripts: Bool = false) {
        let request = UUID()
        catalogID = request
        let root = self.root, knownDirs = Array(known.keys)
        let discovered = self.discovered, excluded = self.excluded
        let cached = reloadScripts ? [:] : scripts
        DispatchQueue.global(qos: .utility).async {
            let dirs = Set(knownDirs.filter { containsProject($0, root: root) })
                .union(discovered.subtracting(excluded)).sorted()
            var names = [String: [String]]()
            for dir in dirs {
                names[dir] = cached[dir] ?? (package(dir)["scripts"] as? [String: String] ?? [:]).keys.sorted()
            }
            DispatchQueue.main.async {
                guard self.catalogID == request,
                      self.catalogDirs != dirs || self.scripts != names else { return }
                self.catalogDirs = dirs
                self.scripts = names
                self.updateStopped()
                self.objectWillChange.send()
            }
        }
    }

    private func updateStopped() {
        let running = Set(live.map(\.cwd))
        stopped = catalogDirs.filter { !running.contains($0) }
    }

    private func synchronizeLive() {
        live = observed.filter { containsProject($0.cwd, root: root) }
        updateStopped()
        item.button?.title = String(live.count)
        var added = false, changed = false
        for service in live where known[service.cwd] != service.executable {
            added = added || known[service.cwd] == nil
            known[service.cwd] = service.executable
            changed = true
        }
        if changed { defaults.set(known, forKey: "projects") }
        if added { rebuildCatalog() }
    }
    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try listeners() }, ips = lanIPs()
            DispatchQueue.main.async {
                self.scanning = false
                let networkChanged = self.ips != ips
                self.ips = ips
                switch result {
                case .success(let list):
                    let servicesChanged = self.observed != list
                    guard servicesChanged || networkChanged || !self.message.isEmpty else { return }
                    if servicesChanged {
                        self.observed = list
                        self.synchronizeLive()
                    }
                    for key in Array(self.routes.keys) where !ips.contains(key.address) || !list.contains(where: {
                        $0.pid == key.pid && $0.birth == key.birth && $0.endpoints(ips).contains(where: { $0.address == key.socket })
                    }) {
                        self.routes.removeValue(forKey: key)?.stop()
                        self.routeURLs.removeValue(forKey: key)
                    }
                    self.message = ""
                case .failure(let error): self.message = "扫描失败 · " + error.localizedDescription
                }
                self.objectWillChange.send()
            }
        }
    }
    func forget(_ dir: String) {
        known.removeValue(forKey: dir)
        if discovered.contains(dir) { excluded.insert(dir); defaults.set(Array(excluded), forKey: "excluded") }
        defaults.set(known, forKey: "projects")
        catalogDirs.removeAll { $0 == dir }
        scripts.removeValue(forKey: dir)
        stopped.removeAll { $0 == dir }
        rebuildCatalog()
        objectWillChange.send()
    }
    func alert(_ title: String, _ detail: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let box = NSAlert()
        box.messageText = title
        box.informativeText = detail
        box.addButton(withTitle: "好")
        return box.runModal() == .alertFirstButtonReturn
    }
    func stop(_ service: Listener) {
        guard !stopping.contains(service.birth), node_identity(service.pid) == service.birth else { refresh(); return }
        guard kill(service.pid, SIGTERM) == 0 else { _ = alert("停止失败", String(cString: strerror(errno))); return }
        stopping.insert(service.birth)
        objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.stopping.remove(service.birth)
            self.objectWillChange.send()
            self.refresh()
        }
        refresh()
    }
    func start(_ dir: String, _ script: String) {
        guard launching[dir] == nil, !live.contains(where: { $0.cwd == dir }) else { return }
        let root = URL(fileURLWithPath: dir)
        let declared = (package(dir)["packageManager"] as? String)?.split(separator: "@").first.map(String.init)
        let manager = declared ?? ([("pnpm-lock.yaml","pnpm"),("yarn.lock","yarn"),("bun.lock","bun"),("bun.lockb","bun")].first {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0.0).path)
        }?.1 ?? "npm")
        guard ["npm","pnpm","yarn","bun"].contains(manager) else { _ = alert("未知包管理器", manager); return }
        let task = Process()
        do {
            let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NodeBar")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent(UUID().uuidString + ".log")
            try Data().write(to: log)
            let output = try FileHandle(forWritingTo: log)
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.currentDirectoryURL = root
            task.arguments = ["-lc", #"export PATH="$1:/opt/homebrew/bin:/usr/local/bin:$PATH"; shift; exec "$@""#, "NodeBar", URL(fileURLWithPath: known[dir] ?? observed.first?.executable ?? known.values.sorted().first ?? "/usr/bin/node").deletingLastPathComponent().path, manager, "run", script]
            task.standardOutput = output
            task.standardError = output
            task.standardInput = FileHandle.nullDevice
            task.terminationHandler = { child in
                DispatchQueue.main.async {
                    self.launching.removeValue(forKey: dir)
                    self.objectWillChange.send()
                    if child.terminationStatus != 0 && child.terminationStatus != 143 && child.terminationStatus != 15 {
                        _ = self.alert("启动命令已退出", dir + "\n日志：" + log.path)
                    }
                    self.refresh()
                }
            }
            try task.run()
            launching[dir] = task
            objectWillChange.send()
            try? output.close()
        } catch { _ = alert("无法启动项目", error.localizedDescription) }
    }
}

if CommandLine.arguments.contains("--list") {
    for s in try listeners() { print(s.pid, s.cwd, s.sockets.sorted().joined(separator: ", ")) }
    print("LAN", lanIPs().joined(separator: ", "))
} else {
    let app = NSApplication.shared
    let bar = Bar()
    app.delegate = bar
    app.run()
}
