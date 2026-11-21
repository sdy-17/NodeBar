import Foundation
import Darwin

struct Listener: Equatable {
    let pid: Int32
    let birth: UInt64
    let cwd: String
    let executable: String
    var sockets: Set<String>
}

func listeners() throws -> [Listener] {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpftn"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 || (task.terminationStatus == 1 && data.isEmpty) else {
        throw NSError(domain: "lsof", code: Int(task.terminationStatus))
    }
    var found: [Int32: Listener] = [:], pid: Int32 = 0, family = "", fd: Int32 = -1
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if line.first == "p" {
            pid = Int32(line.dropFirst()) ?? 0
            let birth = node_identity(pid)
            guard birth != 0, let cwd = process_cwd(pid) else { continue }
            defer { free(cwd) }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            found[pid] = Listener(pid: pid, birth: birth, cwd: String(cString: cwd), executable: String(cString: path), sockets: [])
        } else if line.first == "f" {
            fd = Int32(line.dropFirst()) ?? -1
        } else if line.first == "t" {
            family = String(line.dropFirst())
        } else if line.first == "n" {
            let raw = String(line.dropFirst())
            found[pid]?.sockets.insert(family == "IPv6" && raw.hasPrefix("*:") && socket_accepts_ipv4(pid, fd) == 0 ? "[::]" + raw.dropFirst() : raw)
        }
    }
    return found.values.filter { !$0.sockets.isEmpty }.sorted { ($0.cwd,$0.pid) < ($1.cwd,$1.pid) }
}

func lanIPs() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var ips = Set<String>()
    var current = head
    while let item = current?.pointee {
        current = item.ifa_next
        guard let a = item.ifa_addr, a.pointee.sa_family == AF_INET,
              item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(a, socklen_t(a.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
            ips.insert(String(cString: buf))
        }
    }
    return ips.sorted()
}

func lanIPv6Addresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return ["[::1]"] }
    defer { freeifaddrs(head) }
    var hosts = Set<String>(), current = head
    while let item = current?.pointee {
        current = item.ifa_next
        guard let a = item.ifa_addr, a.pointee.sa_family == AF_INET6,
              item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(a, socklen_t(a.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let host = String(cString: buf)
        if !host.contains("%") { hosts.insert("[" + host + "]") }
    }
    return hosts.isEmpty ? ["[::1]"] : hosts.sorted()
}
