import Foundation
import CoreGraphics

func canonical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

func containsProject(_ dir: String, root: String?) -> Bool {
    guard let root else { return true }
    let path = canonical(dir)
    return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}

func discoverProjects(in root: String) -> Set<String> {
    let fm = FileManager.default
    let ignored = Set(["node_modules", "build", "dist", "coverage", "vendor", "Pods", "DerivedData"])
    let url = URL(fileURLWithPath: root, isDirectory: true)
    var result = Set<String>()
    guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
    for case let file as URL in files {
        let name = file.lastPathComponent
        if ignored.contains(name) { files.skipDescendants(); continue }
        guard name == "package.json", (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else { continue }
        result.insert(file.deletingLastPathComponent().path)
    }
    return result
}

struct StoppedGroup: Identifiable {
    let id: String
    let title: String
    let projects: [String]

    static func groups(for projects: [String], root: String?) -> [StoppedGroup] {
        let prefix = root.map { $0 == "/" ? "/" : $0 + "/" }
        let grouped = Dictionary(grouping: projects) { dir -> String in
            if dir == root { return dir }
            if let prefix, dir.hasPrefix(prefix),
               let first = dir.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first {
                return prefix + first
            }
            return URL(fileURLWithPath: dir).deletingLastPathComponent().path
        }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return StoppedGroup(id: path, title: path == root ? "工作区根目录" : name, projects: grouped[path] ?? [])
        }
    }
}

func panelFrame(anchor: CGRect, visible: CGRect) -> CGRect {
    let width = min(454, visible.width), height = min(410, visible.height - 8)
    let x = min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width)
    let top = min(anchor.minY, visible.maxY) - 4
    return CGRect(x: x, y: max(visible.minY, top - height), width: width, height: height)
}
