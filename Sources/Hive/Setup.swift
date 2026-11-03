import Foundation

/// Whether Claude Code is installed and signed in, so Hive can guide new users through setup.
enum SetupState: Equatable {
    case checking
    case notInstalled
    case notLoggedIn
    case ready
}

enum ClaudeSetup {
    /// Absolute path of the `claude` executable once found; sessions start this one directly,
    /// so a fresh install works even before the user's shell PATH picks it up.
    nonisolated(unsafe) static var executable = "claude"

    /// The official installer from https://docs.claude.com/en/docs/claude-code/setup
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    static var loginCommand: String { "exec \(shellQuote(executable)) auth login" }

    /// Places the installer and other tools put `claude`, checked when the login shell doesn't know it.
    private static var candidates: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    static func check() async -> SetupState {
        await Task.detached {
            guard let path = findClaude() else { return .notInstalled }
            executable = path
            return isLoggedIn(path) ? .ready : .notLoggedIn
        }.value
    }

    private static func findClaude() -> String? {
        // Ask the user's own login shell first, so custom PATH setups (nvm, Homebrew, …) count.
        if let out = run("/bin/zsh", ["-l", "-i", "-c", "command -v claude"]),
           let path = out.split(separator: "\n").last(where: { $0.hasPrefix("/") }).map(String.init),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func isLoggedIn(_ claude: String) -> Bool {
        guard let out = run(claude, ["auth", "status", "--json"]),
              let start = out.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool
        else {
            // Older versions without `auth status`: claude asks for login itself on first start.
            return true
        }
        return loggedIn
    }

    /// Runs a command with a timeout and returns its stdout, or nil on failure.
    private static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
