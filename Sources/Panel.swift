import SwiftUI

struct Endpoint: Identifiable {
    let address: String
    let local: Bool
    var id: String { address }
}

extension Listener {
    func endpoints(_ ips: [String]) -> [Endpoint] {
        var found = [String: Endpoint]()
        for socket in sockets {
            guard let split = socket.lastIndex(of: ":") else { continue }
            let host = String(socket[..<split]), suffix = String(socket[split...])
            let hosts: [String]
            switch host {
            case "*", "0.0.0.0": hosts = ips.isEmpty ? ["127.0.0.1"] : ips
            case "[::]":
                hosts = lanIPv6Addresses()
            default: hosts = [host]
            }
            for host in hosts {
                let address = host + suffix
                found[address] = Endpoint(address: address, local: host.hasPrefix("127.") || host == "[::1]")
            }
        }
        return found.values.sorted {
            if $0.local != $1.local { return !$0.local }
            return $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }
}

private let jade = Color(red: 0.10, green: 0.50, blue: 0.37)

struct ProjectPanel: View {
    @ObservedObject var bar: Bar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(jade, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("NodeBar").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(bar.ips.isEmpty ? "暂无局域网 IPv4 地址" : "局域网  " + bar.ips.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { bar.chooseRoot() } label: {
                    Image(systemName: bar.root == nil ? "folder" : "folder.fill")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .accessibilityLabel("选择监控目录")
                .help(bar.root.map { "当前目录：" + $0 + "（右键可显示全部）" } ?? "选择监控目录")
                .contextMenu {
                    Button("选择监控目录…") { bar.chooseRoot() }
                    if bar.root != nil { Button("显示全部") { bar.selectRoot(nil) } }
                }
                Button { bar.refresh(); bar.discover() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle()) }.help("刷新")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 24, height: 24).contentShape(Rectangle()) }.help("退出 NodeBar")
            }.buttonStyle(.borderless)
            Picker("项目", selection: $bar.history) {
                Text("运行中  \(bar.live.count)").tag(false)
                Text("已停止  \(bar.stopped.count)").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if !bar.message.isEmpty { Text(bar.message).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if bar.history {
                        ForEach(bar.stopped, id: \.self) { dir in historyRow(dir) }
                        if bar.stopped.isEmpty { empty("暂无已停止的项目") }
                    } else {
                        ForEach(bar.live, id: \.birth) { service in serviceRow(service) }
                        if bar.live.isEmpty { empty("暂无运行中的 Node 服务") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: bar.history ? [] : bar.live.map(\.birth))
            }
            .id(bar.history)
            .transition(.opacity)
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: bar.history)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    func empty(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 48)
    }
    func directory(_ dir: String) -> some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) } label: {
            Label((dir as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }.buttonStyle(.plain).help(dir)
    }
    func serviceRow(_ service: Listener) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(jade).frame(width: 7, height: 7)
                Text(URL(fileURLWithPath: service.cwd).lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button { bar.stop(service) } label: { Label(bar.stopping.contains(service.birth) ? "停止中…" : "停止", systemImage: "stop.fill") }
                    .controlSize(.regular).foregroundStyle(.red)
                    .disabled(bar.stopping.contains(service.birth))
            }
            directory(service.cwd)
            Divider()
            ForEach(service.endpoints(bar.ips)) { endpoint in
                let opening = bar.isOpening(endpoint, service: service)
                HStack {
                    Text(bar.displayedAddress(endpoint, service: service)).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(opening ? "打开中…" : (endpoint.local ? "本机打开 ↗" : "局域网打开 ↗")) {
                        bar.openEndpoint(endpoint, service: service)
                    }.buttonStyle(.borderedProminent).tint(jade).controlSize(.regular).disabled(opening)
                }
            }
        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
        .help("PID " + String(service.pid))
    }
    func historyRow(_ dir: String) -> some View {
        let scripts = bar.scripts[dir] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(URL(fileURLWithPath: dir).lastPathComponent).font(.headline)
                Spacer()
                Button { bar.forget(dir) } label: { Image(systemName: "minus.circle") }.help("移除此记录")
            }
            directory(dir)
            if bar.launching[dir] != nil { Text("正在运行启动命令").font(.caption) }
            else if scripts.isEmpty { Text("此目录无启动脚本").font(.caption).foregroundStyle(.secondary) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], alignment: .leading) {
                    ForEach(scripts, id: \.self) { script in
                        Button { bar.start(dir, script) } label: {
                            Label(script, systemImage: "play.fill").lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.bordered).help("运行 " + script)
                    }
                }
            }
        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
