import AppKit
import Foundation

/// A Claude Code session stored on disk in ~/.claude/projects/<project>/<id>.jsonl.
struct HistorySession: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let modified: Date
}

/// A Claude Code process that is currently running (registered in ~/.claude/sessions/<pid>.json).
struct RunningSession: Identifiable, Equatable {
    let pid: pid_t
    let sessionId: String
    let cwd: String
    var id: pid_t { pid }
}

enum SessionStore {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    private static var cache: [String: (Date, HistorySession?)] = [:]

    static func running() -> [RunningSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> RunningSession? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  let sid = obj["sessionId"] as? String,
                  kill(pid_t(pid), 0) == 0
            else { return nil }
            return RunningSession(pid: pid_t(pid), sessionId: sid, cwd: obj["cwd"] as? String ?? NSHomeDirectory())
        }
    }

    static func history(limit: Int = 40) -> [HistorySession] {
        let projects = claudeDir.appendingPathComponent("projects")
        let fm = FileManager.default
        var result: [HistorySession] = []
        let projectDirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in projectDirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let cached = cache[file.path], cached.0 == mtime {
                    if let s = cached.1 { result.append(s) }
                    continue
                }
                let session = parse(file: file, modified: mtime)
                cache[file.path] = (mtime, session)
                if let s = session { result.append(s) }
            }
        }
        return Array(result.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Moves a session's transcript (and its subagent folder, if any) to the Trash. It then no longer
    /// shows up in the history or in `claude --resume`, but can still be restored from the Trash.
    static func trash(sessionId: String) {
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(at: claudeDir.appendingPathComponent("projects"), includingPropertiesForKeys: nil)) ?? []
        for dir in projectDirs {
            for name in ["\(sessionId).jsonl", sessionId] {
                let url = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path) else { continue }
                try? fm.trashItem(at: url, resultingItemURL: nil)
                cache.removeValue(forKey: url.path)
            }
        }
    }

    /// Reads only the head (for cwd) and the tail (for titles) of a transcript, which can get large.
    private static func parse(file: URL, modified: Date) -> HistorySession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: 128 * 1024)) ?? Data(), as: UTF8.self)
        let tailStart = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? handle.seek(toOffset: tailStart)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)

        var cwd: String?
        for line in head.split(separator: "\n") where line.contains("\"cwd\":") {
            if let obj = json(line), let c = obj["cwd"] as? String { cwd = c; break }
        }

        var customTitle: String?, aiTitle: String?, lastPrompt: String?
        for line in tail.split(separator: "\n") {
            if line.hasPrefix("{\"type\":\"custom-title\""), let t = json(line)?["customTitle"] as? String { customTitle = t }
            else if line.hasPrefix("{\"type\":\"ai-title\""), let t = json(line)?["aiTitle"] as? String { aiTitle = t }
            else if line.hasPrefix("{\"type\":\"last-prompt\""), let t = json(line)?["lastPrompt"] as? String { lastPrompt = t }
        }
        guard let title = customTitle ?? aiTitle ?? lastPrompt, !title.isEmpty else { return nil }
        return HistorySession(
            id: file.deletingPathExtension().lastPathComponent,
            title: title.replacingOccurrences(of: "\n", with: " "),
            cwd: cwd ?? NSHomeDirectory(),
            modified: modified
        )
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// The app hosting a running claude process (Terminal, iTerm, VS Code, …).
    static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil {
                return app
            }
            let parent = parentPid(of: current)
            if parent <= 1 { return nil }
            current = parent
        }
        return nil
    }

    static func focusHostApp(of pid: pid_t) {
        hostApp(of: pid)?.activate()
    }

    private static func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

extension String {
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
