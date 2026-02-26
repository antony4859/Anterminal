import Foundation

/// Manages tmux sessions for terminal panels, enabling 1:1 mirroring between native and web.
///
/// When the user opts in to tmux mode (via Settings > Web Server > Tmux Sessions),
/// each new terminal panel runs inside a tmux session named `at-<panelId>`.
/// The web UI can then run `tmux attach -t at-<panelId>` in its PTY WebSocket
/// so that both the native Ghostty surface and the browser see the exact same
/// terminal content in real time.
///
/// This class is a singleton following the same pattern as other anterminal managers
/// (e.g. EmbeddedServer, ServerBridge).  It runs `tmux` commands via
/// `/opt/homebrew/bin/tmux` and is safe to call even when tmux is not installed
/// (all operations will gracefully return empty results).
class TmuxSessionManager {
    static let shared = TmuxSessionManager()

    /// Prefix for all anterminal-managed tmux sessions.
    private let sessionPrefix = "at-"

    /// Resolved path to the tmux binary.
    static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/bin/env"  // fallback — will search PATH
    }()

    /// Track which panels have tmux sessions: panelId -> tmux session name.
    private var panelSessions: [UUID: String] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Session Naming

    /// Generate a tmux session name for a panel.
    /// If a workspace title is provided, use it as the base (sanitized).
    /// Otherwise fall back to the panel UUID prefix.
    func sessionName(for panelId: UUID, workspaceTitle: String? = nil) -> String {
        if let title = workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            // Sanitize: tmux session names can't have dots or colons
            let safe = title
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .lowercased()
            let short = String(safe.prefix(30))
            let suffix = panelId.uuidString.prefix(4).lowercased()
            return sessionPrefix + short + "-" + suffix
        }
        return sessionPrefix + panelId.uuidString.prefix(8).lowercased()
    }

    // MARK: - Command Building

    /// Build the command string that Ghostty should run instead of a bare shell.
    /// This creates a new tmux session OR attaches to an existing one.
    ///
    /// Uses `tmux new-session -A` which attaches if the session already exists
    /// and creates it if it does not.  Also disables the tmux status bar since
    /// Ghostty handles all chrome.
    func buildCommand(for panelId: UUID, workingDirectory: String? = nil, workspaceTitle: String? = nil) -> String {
        // If a session name was already registered (e.g. from session restore), reuse it
        // so we reattach to the existing tmux session instead of creating a new one.
        lock.lock()
        let existingName = panelSessions[panelId]
        lock.unlock()

        let name: String
        if let existingName, !existingName.isEmpty {
            name = existingName
        } else {
            name = sessionName(for: panelId, workspaceTitle: workspaceTitle)
            lock.lock()
            panelSessions[panelId] = name
            lock.unlock()
        }

        // -A: attach if exists, create if not
        // -s: session name
        // We don't use -d (detached) because Ghostty will be the client.
        // "set status off" hides the tmux status bar.
        // Force UTF-8 with -u flag to avoid encoding issues in web terminal
        var cmd = "\(Self.tmuxPath) -u new-session -A -s \(name)"
        if let dir = workingDirectory, !dir.isEmpty {
            cmd += " -c '\(dir.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        // Hide tmux status bar — Ghostty provides its own chrome.
        cmd += " \\; set status off"
        // Set the correct CMUX_SURFACE_ID/CMUX_PANEL_ID for this specific panel
        // so claude-hook notifications highlight the right pane.
        // setenv updates the tmux session env; send-keys exports in the running shell
        // then clears the screen so the user doesn't see the export command.
        cmd += " \\; setenv CMUX_SURFACE_ID \(panelId.uuidString)"
        cmd += " \\; setenv CMUX_PANEL_ID \(panelId.uuidString)"
        cmd += " \\; send-keys 'export CMUX_SURFACE_ID=\(panelId.uuidString) CMUX_PANEL_ID=\(panelId.uuidString) && clear' Enter"
        return cmd
    }

    /// Build the tmux attach command for the web UI to connect to the same session.
    func buildAttachCommand(for panelId: UUID) -> String? {
        lock.lock()
        let name = panelSessions[panelId]
        lock.unlock()
        guard let name else { return nil }
        return buildAttachCommandByName(name)
    }

    /// Build attach command by session name directly (for web UI).
    func buildAttachCommandByName(_ sessionName: String) -> String {
        return "TERM=xterm-256color \(Self.tmuxPath) -u attach -t \(sessionName)"
    }

    // MARK: - Registration

    /// Register a panel's tmux session (called when restoring sessions).
    func registerSession(panelId: UUID, sessionName: String) {
        lock.lock()
        panelSessions[panelId] = sessionName
        lock.unlock()
    }

    /// Unregister when panel closes.
    func unregisterSession(panelId: UUID) {
        lock.lock()
        panelSessions.removeValue(forKey: panelId)
        lock.unlock()
    }

    /// Get the tmux session name for a panel.
    func getSessionName(for panelId: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return panelSessions[panelId]
    }

    /// Get all registered panel-to-session mappings.
    func allRegisteredSessions() -> [UUID: String] {
        lock.lock()
        defer { lock.unlock() }
        return panelSessions
    }

    // MARK: - Tmux Process Queries

    /// List all active anterminal-managed tmux sessions (runs `tmux list-sessions`).
    ///
    /// This method runs synchronously on a `Process` and should be called from
    /// a context that can tolerate a brief blocking wait.
    nonisolated func listActiveSessions() -> [TmuxSession] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        task.arguments = [
            "list-sessions", "-F",
            "#{session_name}\t#{session_created}\t#{session_windows}\t#{session_attached}\t#{pane_current_path}"
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let prefix = "at-"
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4)
            guard parts.count >= 4 else { return nil }
            let name = String(parts[0])
            // Only return anterminal-managed sessions.
            guard name.hasPrefix(prefix) else { return nil }
            return TmuxSession(
                name: name,
                created: Date(timeIntervalSince1970: Double(parts[1]) ?? 0),
                windowCount: Int(parts[2]) ?? 1,
                attached: Int(parts[3]) ?? 0,
                currentPath: parts.count > 4 ? String(parts[4]) : ""
            )
        }
    }

    /// Check if a specific tmux session exists.
    nonisolated func sessionExists(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        task.arguments = ["has-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Kill a tmux session by name.
    nonisolated func killSession(_ name: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        task.arguments = ["kill-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    /// Kill all anterminal-managed tmux sessions.
    func killAllSessions() {
        for session in listActiveSessions() {
            killSession(session.name)
        }
        lock.lock()
        panelSessions.removeAll()
        lock.unlock()
    }
}

// MARK: - TmuxSession Model

/// Represents a single tmux session as reported by `tmux list-sessions`.
struct TmuxSession: Identifiable {
    var id: String { name }
    let name: String
    let created: Date
    let windowCount: Int
    /// Number of clients currently attached to this session.
    let attached: Int
    let currentPath: String
}
