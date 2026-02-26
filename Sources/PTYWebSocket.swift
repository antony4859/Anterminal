import Foundation
import Darwin
import Swifter

// MARK: - PTY Session

/// Manages a single PTY session for a web-based terminal.
/// Each session forks a shell process and bridges I/O between the PTY master fd
/// and a WebSocket connection.  All PTY reads happen on a background
/// `DispatchSourceRead`; writes go straight to the master fd.
class PTYSession {
    let id: String
    let masterFd: Int32
    let pid: pid_t
    let workingDirectory: String
    let tmuxSessionName: String?
    private var readSource: DispatchSourceRead?
    private weak var webSocketSession: WebSocketSession?
    private var isTerminated = false

    /// When the WebSocket disconnects, this is set to the current date.
    /// The session is kept alive for a grace period so the client can reconnect.
    var lastDisconnectedAt: Date?

    /// True when no WebSocket is currently attached to this PTY session.
    var isOrphaned: Bool {
        return webSocketSession == nil && !isTerminated
    }

    /// Fork a new PTY with the user's login shell, or attach to a tmux session.
    /// - Parameters:
    ///   - id: Unique session identifier.
    ///   - workingDirectory: Initial working directory for the shell.
    ///   - cols: Initial terminal width in columns.
    ///   - rows: Initial terminal height in rows.
    ///   - tmuxSession: Optional tmux session name to attach to instead of running a bare shell.
    init(id: String, workingDirectory: String, cols: UInt16 = 80, rows: UInt16 = 24, tmuxSession: String? = nil) throws {
        self.id = id
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSession

        var masterFd: Int32 = 0
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&masterFd, nil, nil, &winSize)
        guard pid >= 0 else {
            throw NSError(domain: "PTYSession", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "forkpty failed: \(String(cString: strerror(errno)))"])
        }

        if pid == 0 {
            // ---- Child process ----
            chdir(workingDirectory)

            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)

            if let tmuxSession {
                // Attach to an existing tmux session for 1:1 mirroring with native app.
                let cTmux = strdup("tmux")
                let cAttach = strdup("attach")
                let cFlag = strdup("-t")
                let cName = strdup(tmuxSession)
                let argv: [UnsafeMutablePointer<CChar>?] = [cTmux, cAttach, cFlag, cName, nil]
                argv.withUnsafeBufferPointer { buf in
                    _ = execv(TmuxSessionManager.tmuxPath, buf.baseAddress!)
                }
            } else {
                // Resolve the user's preferred shell.
                let shell: String
                if let pw = getpwuid(getuid()) {
                    shell = String(cString: pw.pointee.pw_shell)
                } else {
                    shell = "/bin/zsh"
                }

                // Execute as a login shell.
                let dashShell = "-" + (shell as NSString).lastPathComponent
                // execl is unavailable in Swift 6, use execv with a C string array
                let cShell = strdup(dashShell)
                let argv: [UnsafeMutablePointer<CChar>?] = [cShell, nil]
                argv.withUnsafeBufferPointer { buf in
                    _ = execv(shell, buf.baseAddress!)
                }
            }
            _exit(1)
        }

        // ---- Parent process ----
        self.masterFd = masterFd
        self.pid = pid
    }

    // MARK: - WebSocket Attachment

    /// Attach a WebSocket and start streaming PTY output to it.
    func attach(to session: WebSocketSession) {
        self.webSocketSession = session
        self.lastDisconnectedAt = nil

        // Non-blocking reads so the dispatch source fires correctly.
        let flags = fcntl(masterFd, F_GETFL)
        fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd,
                                                   queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self, let ws = self.webSocketSession else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(self.masterFd, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                if let str = String(data: data, encoding: .utf8) {
                    ws.writeText(str)
                } else {
                    // Fallback: encode each byte as its Latin-1 code point.
                    let latin1 = data.map { String(UnicodeScalar($0)) }.joined()
                    ws.writeText(latin1)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                ws.writeText("\r\n[Process exited]\r\n")
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.masterFd)
        }
        source.resume()
        self.readSource = source
    }

    /// Re-attach a new WebSocket to this PTY session after a disconnect.
    /// Resumes streaming PTY output to the new WebSocket.
    func reattach(to session: WebSocketSession) {
        // Cancel the old read source (if any) without closing the fd
        // since we will re-create the dispatch source.
        if let oldSource = readSource {
            // We need to cancel without triggering the cancel handler that closes the fd.
            // Create a new source instead.
            oldSource.cancel()
            readSource = nil
        }

        self.webSocketSession = session
        self.lastDisconnectedAt = nil

        // Re-create the read source for the new WebSocket.
        let flags = fcntl(masterFd, F_GETFL)
        fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd,
                                                   queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self, let ws = self.webSocketSession else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(self.masterFd, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                if let str = String(data: data, encoding: .utf8) {
                    ws.writeText(str)
                } else {
                    let latin1 = data.map { String(UnicodeScalar($0)) }.joined()
                    ws.writeText(latin1)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                ws.writeText("\r\n[Process exited]\r\n")
            }
        }
        // Don't close the fd on cancel for reattach — the fd belongs to the PTYSession lifecycle.
        source.resume()
        self.readSource = source
    }

    /// Detach the WebSocket without terminating the PTY.
    /// Called when a WebSocket disconnects but the PTY should remain alive for reconnection.
    func detach() {
        readSource?.cancel()
        readSource = nil
        webSocketSession = nil
        lastDisconnectedAt = Date()
    }

    // MARK: - Input / Resize

    /// Write user keyboard input from the WebSocket into the PTY.
    func write(_ text: String) {
        guard let bytes = text.data(using: .utf8) else { return }
        bytes.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = Darwin.write(masterFd, base, ptr.count)
            }
        }
    }

    /// Resize the PTY window.
    func resize(cols: UInt16, rows: UInt16) {
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFd, TIOCSWINSZ, &winSize)
    }

    // MARK: - Teardown

    /// Terminate the shell process and close the PTY file descriptor.
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        readSource?.cancel()
        readSource = nil
        kill(pid, SIGHUP)
        // Reap the child asynchronously so we don't block.
        DispatchQueue.global().async { [pid] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    deinit {
        terminate()
    }
}

// MARK: - Session Manager

/// Thread-safe registry of all active PTY sessions.
/// Also tracks the mapping from WebSocket connections to PTY sessions.
class PTYSessionManager {
    static let shared = PTYSessionManager()

    /// Grace period in seconds before an orphaned PTY is reaped.
    static let orphanGracePeriod: TimeInterval = 60

    private var sessions: [String: PTYSession] = [:]
    /// Maps WebSocketSession identity to the PTY session id.
    private var wsToSessionId: [ObjectIdentifier: String] = [:]
    private let lock = NSLock()

    private init() {}

    /// Create a new PTY session for the given working directory and attach
    /// it to the provided WebSocket.
    ///
    /// If `tmuxSession` is provided, the PTY will run `tmux attach -t <name>`
    /// instead of a bare shell, enabling 1:1 mirroring with a native terminal.
    @discardableResult
    func createSession(for wsSession: WebSocketSession,
                       workingDirectory: String,
                       cols: UInt16 = 80,
                       rows: UInt16 = 24,
                       tmuxSession: String? = nil) throws -> PTYSession {
        let id = UUID().uuidString
        let session = try PTYSession(id: id, workingDirectory: workingDirectory,
                                     cols: cols, rows: rows, tmuxSession: tmuxSession)
        lock.lock()
        sessions[id] = session
        wsToSessionId[ObjectIdentifier(wsSession)] = id
        lock.unlock()

        session.attach(to: wsSession)
        return session
    }

    /// Look up the PTY session associated with a given WebSocket connection.
    func session(for wsSession: WebSocketSession) -> PTYSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = wsToSessionId[ObjectIdentifier(wsSession)] else { return nil }
        return sessions[id]
    }

    /// Look up a PTY session by its session id.
    func session(byId id: String) -> PTYSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    /// Detach the WebSocket from its PTY session without terminating the PTY.
    /// The PTY is marked as orphaned and kept alive for the grace period.
    func detachSession(for wsSession: WebSocketSession) {
        lock.lock()
        let key = ObjectIdentifier(wsSession)
        guard let id = wsToSessionId.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        let session = sessions[id]
        lock.unlock()
        session?.detach()
    }

    /// Remove and terminate the PTY session associated with a WebSocket.
    func removeSession(for wsSession: WebSocketSession) {
        lock.lock()
        let key = ObjectIdentifier(wsSession)
        guard let id = wsToSessionId.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        session?.terminate()
    }

    /// Find an orphaned PTY session by its session id.
    func findOrphanedSession(byId sessionId: String) -> PTYSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionId], session.isOrphaned else { return nil }
        return session
    }

    /// Find orphaned PTY sessions matching a working directory.
    func findOrphanedSessions(byDirectory directory: String) -> [PTYSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { $0.isOrphaned && $0.workingDirectory == directory }
    }

    /// Find an orphaned PTY session matching a tmux session name.
    func findOrphanedSession(byTmuxSession tmuxName: String) -> PTYSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.first { $0.isOrphaned && $0.tmuxSessionName == tmuxName }
    }

    /// Re-attach a WebSocket to an existing orphaned PTY session.
    /// Returns true if the reattach succeeded.
    @discardableResult
    func reattachSession(_ sessionId: String, to wsSession: WebSocketSession) -> Bool {
        lock.lock()
        guard let session = sessions[sessionId], session.isOrphaned else {
            lock.unlock()
            return false
        }
        wsToSessionId[ObjectIdentifier(wsSession)] = sessionId
        lock.unlock()
        session.reattach(to: wsSession)
        return true
    }

    /// Terminate any orphaned PTY sessions whose grace period has expired.
    /// Returns the number of sessions reaped.
    @discardableResult
    func reapOrphans() -> Int {
        let now = Date()
        lock.lock()
        var toReap: [String: PTYSession] = [:]
        for (id, session) in sessions {
            if session.isOrphaned,
               let disconnectedAt = session.lastDisconnectedAt,
               now.timeIntervalSince(disconnectedAt) > PTYSessionManager.orphanGracePeriod {
                toReap[id] = session
            }
        }
        for id in toReap.keys {
            sessions.removeValue(forKey: id)
        }
        lock.unlock()

        for (_, session) in toReap {
            session.terminate()
        }
        return toReap.count
    }

    /// Tear down every active PTY session (called on server stop).
    func removeAll() {
        lock.lock()
        let all = sessions
        sessions.removeAll()
        wsToSessionId.removeAll()
        lock.unlock()
        all.values.forEach { $0.terminate() }
    }
}
