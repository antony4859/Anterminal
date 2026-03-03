import Foundation
import Swifter

// MARK: - Embedded Server

/// Embedded HTTP/WebSocket server that exposes terminal sessions to browsers.
/// Access from any device on the local network via http://<mac-ip>:<port>
///
/// This is a singleton following the same pattern as TerminalController and
/// ServerBridge.  The server is entirely opt-in: when disabled (the default) it
/// does nothing and adds zero overhead.  When enabled it:
///   - Serves a mobile-optimized single-page web UI at /
///   - Exposes REST API endpoints for workspace and notification data
///   - Opens a WebSocket at /ws for real-time state sync
///   - Periodically broadcasts workspace state to all connected clients
///   - Forwards terminal notifications to connected browsers
@MainActor
class EmbeddedServer {
    static let shared = EmbeddedServer()

    // MARK: - Public State

    private(set) var isRunning = false

    // MARK: - Private State

    private var server: HttpServer?
    /// All currently connected WebSocket sessions.  Access only from MainActor.
    private var connectedClients: [WebSocketSession] = []
    /// Timer that periodically broadcasts workspace state to all connected clients.
    private var stateTimer: Timer?
    /// Timer that periodically reaps orphaned PTY sessions and sends WebSocket pings.
    private var reaperTimer: Timer?
    /// Timer that periodically sends WebSocket pings.
    private var pingTimer: Timer?
    /// Cached tmux session data for inclusion in state broadcasts.
    private var cachedTmuxSessions: [[String: Any]] = []
    /// Last time the tmux session cache was refreshed.
    private var lastTmuxRefresh: Date = .distantPast

    private init() {}

    /// The port the server listens on, pulled from persisted settings.
    var port: in_port_t { in_port_t(EmbeddedServerSettings.port()) }

    // MARK: - Lifecycle

    /// Start the embedded server.  Called from AppDelegate.applicationDidFinishLaunching when enabled.
    func start() {
        guard !isRunning else { return }

        // Kill any existing process on our port (e.g. a stale server from a previous launch)
        killProcessOnPort(Int(port))

        let server = HttpServer()
        self.server = server

        // Configure routes, API, and WebSocket
        setupRoutes(server)
        setupAPI(server)
        setupWebSocket(server)

        // Try to start, with one retry if the port is still being released
        var started = false
        for attempt in 1...3 {
            do {
                try server.start(port, forceIPv4: false, priority: .default)
                started = true
                break
            } catch {
                if attempt < 3 {
                    print("anterminal: Port \(port) not ready (attempt \(attempt)/3), retrying...")
                    usleep(500_000) // 500ms between retries
                } else {
                    print("EmbeddedServer: Failed to start after 3 attempts: \(error)")
                    sentryBreadcrumb("embeddedServer.startFailed", category: "server", data: ["error": error.localizedDescription])
                    self.server = nil
                }
            }
        }
        if started {
            isRunning = true
            startStateSync()
            startReaperAndHeartbeat()
            print("anterminal: Running on http://0.0.0.0:\(port)")
            sentryBreadcrumb("embeddedServer.started", category: "server", data: ["port": Int(port)])
        }
    }

    /// Stop the embedded server.  Safe to call even if the server is not running.
    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        stateTimer?.invalidate()
        stateTimer = nil
        reaperTimer?.invalidate()
        reaperTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        connectedClients.removeAll()
        PTYSessionManager.shared.removeAll()
        sentryBreadcrumb("embeddedServer.stopped", category: "server")
    }

    // MARK: - Routes

    private func setupRoutes(_ server: HttpServer) {
        // Serve the single-page web UI at /
        server["/"] = { _ in
            .ok(.html(EmbeddedServerHTML.indexPage))
        }

        // PWA manifest
        server["/manifest.json"] = { _ in
            let manifest = """
            {
              "name": "anterminal",
              "short_name": "anterminal",
              "description": "Terminal from anywhere",
              "start_url": "/",
              "display": "standalone",
              "background_color": "#1a1a2e",
              "theme_color": "#1a1a2e",
              "orientation": "any",
              "icons": [{
                "src": "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect fill='%231a1a2e' width='100' height='100' rx='20'/><text y='68' x='50' text-anchor='middle' font-size='50' fill='%236366f1'>at</text></svg>",
                "sizes": "any",
                "type": "image/svg+xml"
              }]
            }
            """
            let data = Data(manifest.utf8)
            return .ok(.data(data, contentType: "application/json"))
        }

        // PWA service worker (minimal — caches shell for offline launch)
        server["/sw.js"] = { _ in
            let sw = """
            const CACHE = 'anterminal-v1';
            const SHELL = ['/'];
            self.addEventListener('install', e => {
              e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)));
              self.skipWaiting();
            });
            self.addEventListener('activate', e => {
              e.waitUntil(self.clients.claim());
            });
            self.addEventListener('fetch', e => {
              if (e.request.mode === 'navigate') {
                e.respondWith(fetch(e.request).catch(() => caches.match('/')));
              }
            });
            """
            let data = Data(sw.utf8)
            return .ok(.data(data, contentType: "application/javascript"))
        }

        // Serve CSS with correct content type
        server["/style.css"] = { _ in
            let data = Data(EmbeddedServerHTML.styleCSS.utf8)
            return .ok(.data(data, contentType: "text/css; charset=utf-8"))
        }

        // Serve JS with correct content type
        server["/app.js"] = { _ in
            let data = Data(EmbeddedServerHTML.appJS.utf8)
            return .ok(.data(data, contentType: "application/javascript; charset=utf-8"))
        }
    }

    // MARK: - API Endpoints

    private func setupAPI(_ server: HttpServer) {
        // GET /api/status - server status
        server["/api/status"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let data: [String: Any]
            if Thread.isMainThread {
                data = self.buildStatusJSON()
            } else {
                data = DispatchQueue.main.sync { self.buildStatusJSON() }
            }
            return .ok(.json(data as Any))
        }

        // GET /api/workspaces - list all workspaces with details
        server["/api/workspaces"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let data: [[String: Any]]
            if Thread.isMainThread {
                data = self.buildWorkspacesJSON()
            } else {
                data = DispatchQueue.main.sync { self.buildWorkspacesJSON() }
            }
            return .ok(.json(data as Any))
        }

        // GET /api/notifications - list notifications
        server["/api/notifications"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let data: [[String: Any]]
            if Thread.isMainThread {
                data = self.buildNotificationsJSON()
            } else {
                data = DispatchQueue.main.sync { self.buildNotificationsJSON() }
            }
            return .ok(.json(data as Any))
        }

        // POST /api/workspaces/:id/select - select a workspace
        server["/api/workspaces/:id/select"] = { request in
            guard let workspaceId = request.params[":id"] else {
                return .badRequest(.text("Missing workspace id"))
            }
            let params: [String: Any] = ["method": "workspace.select", "params": ["id": workspaceId]]
            guard let cmdData = try? JSONSerialization.data(withJSONObject: params),
                  let command = String(data: cmdData, encoding: .utf8) else {
                return .badRequest(.text("Invalid workspace id"))
            }
            // Wait for the bridge command to complete and return the actual result.
            let result = EmbeddedServer.awaitBridgeCommand(command)
            return .ok(.json(result as Any))
        }

        // POST /api/command - send any V2 command
        server.POST["/api/command"] = { request in
            let bodyString = String(bytes: request.body, encoding: .utf8) ?? ""
            guard !bodyString.isEmpty else {
                return .badRequest(.text("Empty request body"))
            }
            // Wait for the bridge command to complete and return the actual result.
            let result = EmbeddedServer.awaitBridgeCommand(bodyString)
            return .ok(.json(result as Any))
        }

        // POST /api/workspaces/new - create a new workspace in the native app
        server.POST["/api/workspaces/new"] = { request in
            let body = (try? JSONSerialization.jsonObject(with: Data(request.body))) as? [String: Any]
            let isTmux = (body?["tmux"] as? Bool) ?? false
            let directory = body?["directory"] as? String

            var resultId: String?
            // Must create the workspace on the main thread
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if let appDelegate = AppDelegate.shared {
                    let wsId = appDelegate.addWorkspaceInPreferredMainWindow(
                        workingDirectory: directory,
                        isTmux: isTmux,
                        debugSource: "webAPI.newWorkspace"
                    )
                    resultId = wsId?.uuidString
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)

            if let resultId {
                return .ok(.json(["ok": true, "workspaceId": resultId, "tmux": isTmux] as [String: Any] as Any))
            } else {
                return .internalServerError
            }
        }

        // POST /api/workspaces/:id/tmux - toggle tmux for a workspace
        server["/api/workspaces/:id/tmux"] = { request in
            guard let wsId = request.params[":id"] else {
                return .badRequest(.text("Missing workspace id"))
            }
            let body = (try? JSONSerialization.jsonObject(with: Data(request.body))) as? [String: Any]
            let enable = (body?["enabled"] as? Bool) ?? true

            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if let tabManager = AppDelegate.shared?.tabManager,
                   let workspace = tabManager.tabs.first(where: { $0.id.uuidString == wsId }) {
                    workspace.isTmuxEnabled = enable
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            return .ok(.json(["ok": true, "tmuxEnabled": enable] as [String: Any] as Any))
        }

        // GET /api/tmux/sessions - list all anterminal-managed tmux sessions
        server["/api/tmux/sessions"] = { _ in
            let sessions = TmuxSessionManager.shared.listActiveSessions()
            let formatter = ISO8601DateFormatter()
            let json: [[String: Any]] = sessions.map { s in
                [
                    "name": s.name,
                    "windowCount": s.windowCount,
                    "attached": s.attached,
                    "currentPath": s.currentPath,
                    "created": formatter.string(from: s.created)
                ]
            }
            return .ok(.json(json as Any))
        }

        // DELETE /api/tmux/sessions/:name - kill a specific tmux session
        server.DELETE["/api/tmux/sessions/:name"] = { request in
            guard let name = request.params[":name"] else {
                return .badRequest(.text("Missing session name"))
            }
            TmuxSessionManager.shared.killSession(name)
            return .ok(.json(["ok": true, "killed": name] as [String: Any] as Any))
        }

        // DELETE /api/tmux/sessions - kill ALL anterminal tmux sessions
        server.DELETE["/api/tmux/sessions"] = { _ in
            let sessions = TmuxSessionManager.shared.listActiveSessions()
            TmuxSessionManager.shared.killAllSessions()
            return .ok(.json(["ok": true, "killed": sessions.count] as [String: Any] as Any))
        }

        // POST /api/workspaces/:id/tmux - toggle tmux for a workspace
        server["/api/workspaces/:id/tmux"] = { request in
            guard let wsId = request.params[":id"] else {
                return .badRequest(.text("Missing workspace id"))
            }
            let enable: Bool
            if let body = try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any],
               let val = body["enabled"] as? Bool {
                enable = val
            } else {
                enable = true
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManager,
                      let workspace = tabManager.tabs.first(where: { $0.id.uuidString == wsId }) else { return }
                workspace.isTmuxEnabled = enable
            }
            return .ok(.json(["ok": true, "tmuxEnabled": enable] as [String: Any] as Any))
        }

        // MARK: - Claude Code Session Endpoints

        // GET /api/cc/sessions - list recent Claude Code sessions
        server["/api/cc/sessions"] = { _ in
            let sessions = ClaudeSessionScanner.shared.recentSessions()
            let formatter = ISO8601DateFormatter()
            let json: [[String: Any]] = sessions.map { s in
                [
                    "uuid": s.uuid,
                    "projectPath": s.projectPath,
                    "projectName": s.projectName,
                    "lastModified": formatter.string(from: s.lastModified),
                    "sizeBytes": s.sizeBytes
                ]
            }
            return .ok(.json(json as Any))
        }

        // POST /api/cc/resume - resume a CC session in a new tmux workspace
        server.POST["/api/cc/resume"] = { request in
            let body = (try? JSONSerialization.jsonObject(with: Data(request.body))) as? [String: Any]
            let projectPath = body?["projectPath"] as? String

            guard let projectPath else {
                return .badRequest(.text("projectPath required"))
            }

            var resultId: String?
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if let appDelegate = AppDelegate.shared {
                    let wsId = appDelegate.addWorkspaceInPreferredMainWindow(
                        workingDirectory: projectPath,
                        isTmux: true,
                        debugSource: "webAPI.ccResume"
                    )
                    resultId = wsId?.uuidString
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)

            if let resultId {
                return .ok(.json(["ok": true, "workspaceId": resultId] as [String: Any] as Any))
            }
            return .internalServerError
        }

        // MARK: - Pane Split Endpoint

        // POST /api/workspaces/:id/split - split the focused panel in a workspace
        server.POST["/api/workspaces/:id/split"] = { request in
            guard let wsId = request.params[":id"] else {
                return .badRequest(.text("Missing workspace id"))
            }
            let body = (try? JSONSerialization.jsonObject(with: Data(request.body))) as? [String: Any]
            let direction = (body?["direction"] as? String) ?? "right"

            let sem = DispatchSemaphore(value: 0)
            var success = false
            DispatchQueue.main.async {
                if let tabManager = AppDelegate.shared?.tabManager,
                   let workspace = tabManager.tabs.first(where: { $0.id.uuidString == wsId }),
                   let surfaceId = workspace.focusedPanelId {
                    success = tabManager.newSplit(tabId: workspace.id, surfaceId: surfaceId,
                                                  direction: direction == "down" ? .down : .right) != nil
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 10)
            return .ok(.json(["ok": success] as [String: Any] as Any))
        }
    }

    // MARK: - Bridge Command Helper

    /// Execute a bridge command synchronously, waiting for the completion callback.
    /// Must be called from a background thread (Swifter request handler context).
    private static func awaitBridgeCommand(_ command: String) -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        var responseText = ""
        DispatchQueue.main.async {
            TerminalController.shared.handleBridgeCommand(command) { result in
                responseText = result
                semaphore.signal()
            }
        }
        // Wait up to 10 seconds for the command to complete.
        let timeout = semaphore.wait(timeout: .now() + 10)
        if timeout == .timedOut {
            return ["ok": false, "error": "Command timed out"]
        }
        // Try to parse the response as JSON; if it fails, wrap in an "ok" envelope.
        if let data = responseText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        if responseText.isEmpty {
            return ["ok": true]
        }
        return ["ok": true, "result": responseText]
    }

    // MARK: - WebSocket

    private func setupWebSocket(_ server: HttpServer) {
        // State-sync WebSocket (workspace list, notifications)
        server["/ws"] = websocket(
            text: { [weak self] session, text in
                self?.handleWebSocketMessage(session: session, text: text)
            },
            binary: { _, _ in },
            pong: { _, _ in },
            connected: { [weak self] session in
                DispatchQueue.main.async {
                    self?.connectedClients.append(session)
                    print("EmbeddedServer: WebSocket client connected (\(self?.connectedClients.count ?? 0) total)")
                }
            },
            disconnected: { [weak self] session in
                DispatchQueue.main.async {
                    self?.connectedClients.removeAll { $0 == session }
                    print("EmbeddedServer: WebSocket client disconnected (\(self?.connectedClients.count ?? 0) total)")
                }
            }
        )

        // Terminal PTY WebSocket
        // Protocol:
        //   1. Client connects to /ws/terminal
        //   2. Client sends first message: {"type":"init","dir":"/path","cols":80,"rows":24}
        //      OR {"type":"reconnect","sessionId":"..."} to reattach to an orphaned PTY
        //   3. Server forks a PTY and starts streaming output as text frames
        //   4. Client sends: {"type":"input","data":"..."} for keystrokes
        //   5. Client sends: {"type":"resize","cols":N,"rows":N} on window resize
        //   6. Client sends: {"type":"pong"} in response to server ping
        server["/ws/terminal"] = websocket(
            text: { session, text in
                let mgr = PTYSessionManager.shared

                // If a PTY already exists for this connection, handle input/resize/pong.
                if let pty = mgr.session(for: session) {
                    // Try to parse as JSON command.
                    if let jsonData = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let type = json["type"] as? String {
                        switch type {
                        case "input":
                            if let input = json["data"] as? String {
                                pty.write(input)
                            }
                        case "resize":
                            if let cols = json["cols"] as? Int,
                               let rows = json["rows"] as? Int {
                                pty.resize(cols: UInt16(cols), rows: UInt16(rows))
                            }
                        case "pong":
                            // Client responded to our ping; nothing to do.
                            break
                        default:
                            break
                        }
                    } else {
                        // Plain text fallback: treat as raw input.
                        pty.write(text)
                    }
                    return
                }

                // No PTY yet -- expect an init or reconnect message.
                guard let jsonData = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let type = json["type"] as? String else {
                    session.writeText("{\"error\":\"Expected init or reconnect message\"}")
                    return
                }

                switch type {
                case "reconnect":
                    // Try to reattach to an orphaned PTY session.
                    if let sessionId = json["sessionId"] as? String,
                       mgr.reattachSession(sessionId, to: session) {
                        session.writeText("{\"type\":\"reconnected\",\"sessionId\":\"\(sessionId)\"}")
                        print("EmbeddedServer: PTY session reattached: \(sessionId)")
                    } else {
                        // No orphaned session found; tell client to do a fresh init.
                        session.writeText("{\"type\":\"reconnect_failed\"}")
                    }

                case "init":
                    let dir = (json["dir"] as? String) ?? NSHomeDirectory()
                    let cols = UInt16(json["cols"] as? Int ?? 80)
                    let rows = UInt16(json["rows"] as? Int ?? 24)
                    let tmuxSession = json["tmux"] as? String  // Optional tmux session to attach to

                    // Validate the directory exists; fall back to home.
                    var isDir: ObjCBool = false
                    let resolvedDir = FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
                        ? dir
                        : NSHomeDirectory()

                    // Check for an orphaned PTY session we can reattach to.
                    var reattached = false
                    if let tmux = tmuxSession,
                       let orphan = mgr.findOrphanedSession(byTmuxSession: tmux) {
                        if mgr.reattachSession(orphan.id, to: session) {
                            session.writeText("{\"type\":\"reconnected\",\"sessionId\":\"\(orphan.id)\"}")
                            print("EmbeddedServer: Reattached to orphaned tmux PTY: \(tmux)")
                            reattached = true
                        }
                    }
                    if !reattached {
                        // Check by directory for non-tmux sessions.
                        let orphans = mgr.findOrphanedSessions(byDirectory: resolvedDir)
                        if let orphan = orphans.first {
                            if mgr.reattachSession(orphan.id, to: session) {
                                session.writeText("{\"type\":\"reconnected\",\"sessionId\":\"\(orphan.id)\"}")
                                print("EmbeddedServer: Reattached to orphaned PTY for \(resolvedDir)")
                                reattached = true
                            }
                        }
                    }

                    if !reattached {
                        do {
                            let ptySession = try mgr.createSession(for: session,
                                                      workingDirectory: resolvedDir,
                                                      cols: cols,
                                                      rows: rows,
                                                      tmuxSession: tmuxSession)
                            let modeLabel = tmuxSession != nil ? " (tmux: \(tmuxSession!))" : ""
                            // Send the session id to the client so it can reconnect later.
                            session.writeText("{\"type\":\"session_created\",\"sessionId\":\"\(ptySession.id)\"}")
                            print("EmbeddedServer: PTY session created for \(resolvedDir)\(modeLabel)")
                        } catch {
                            session.writeText("\r\n[Failed to create terminal: \(error.localizedDescription)]\r\n")
                            print("EmbeddedServer: PTY creation failed: \(error)")
                        }
                    }

                default:
                    session.writeText("{\"error\":\"Expected init or reconnect message\"}")
                }
            },
            binary: { _, _ in },
            pong: { _, _ in },
            connected: { session in
                print("EmbeddedServer: Terminal WebSocket connected (awaiting init)")
            },
            disconnected: { session in
                // Instead of immediately terminating, detach the PTY so it can be reconnected.
                PTYSessionManager.shared.detachSession(for: session)
                print("EmbeddedServer: Terminal WebSocket disconnected, PTY kept alive for reconnect")
            }
        )
    }

    /// Handle an incoming WebSocket text message from a browser client.
    /// Called on a background thread by Swifter.
    private nonisolated func handleWebSocketMessage(session: WebSocketSession, text: String) {
        // Check for pong response first.
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            if type == "pong" {
                return  // heartbeat response, nothing to do
            }
            // For WebSocket commands, check for an "id" field and return the result
            // with the same id so the client can correlate requests and responses.
            let commandId = json["id"] as? String
            DispatchQueue.main.async {
                TerminalController.shared.handleBridgeCommand(text) { response in
                    if !response.isEmpty {
                        if let commandId {
                            // Wrap the response with the command id for correlation.
                            if let respData = response.data(using: .utf8),
                               var respJson = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] {
                                respJson["id"] = commandId
                                if let wrapped = try? JSONSerialization.data(withJSONObject: respJson),
                                   let wrappedStr = String(data: wrapped, encoding: .utf8) {
                                    session.writeText(wrappedStr)
                                    return
                                }
                            }
                            // Fallback: wrap plain text response using JSONSerialization to prevent injection.
                            let fallbackDict: [String: Any] = ["id": commandId, "result": response]
                            if let fallbackData = try? JSONSerialization.data(withJSONObject: fallbackDict),
                               let fallbackStr = String(data: fallbackData, encoding: .utf8) {
                                session.writeText(fallbackStr)
                            }
                        } else {
                            session.writeText(response)
                        }
                    }
                }
            }
            return
        }
        // Fallback: forward as bridge command.
        DispatchQueue.main.async {
            TerminalController.shared.handleBridgeCommand(text) { response in
                if !response.isEmpty {
                    session.writeText(response)
                }
            }
        }
    }

    // MARK: - State Sync

    /// Start the periodic state broadcast timer (every 2 seconds).
    private func startStateSync() {
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.broadcastState()
            }
        }
    }

    /// Broadcast current workspace state to all connected WebSocket clients.
    /// Includes tmux session data so the web UI does not need to poll separately.
    private func broadcastState() {
        guard !connectedClients.isEmpty else { return }

        let now = Date()
        // Only refresh tmux sessions every 10 seconds to avoid spawning tmux every 2s.
        if now.timeIntervalSince(lastTmuxRefresh) >= 10.0 {
            lastTmuxRefresh = now
            // Refresh tmux session cache on a background thread.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let sessions = TmuxSessionManager.shared.listActiveSessions()
                let formatter = ISO8601DateFormatter()
                let tmuxJson: [[String: Any]] = sessions.map { s in
                    [
                        "name": s.name,
                        "windowCount": s.windowCount,
                        "attached": s.attached,
                        "currentPath": s.currentPath,
                        "created": formatter.string(from: s.created)
                    ]
                }
                DispatchQueue.main.async {
                    self?.cachedTmuxSessions = tmuxJson
                    self?.doBroadcastState()
                }
            }
        } else {
            // Use cached tmux data.
            doBroadcastState()
        }
    }

    /// Actually send the state broadcast (called on MainActor after tmux cache update).
    private func doBroadcastState() {
        guard !connectedClients.isEmpty else { return }
        let workspaces = buildWorkspacesJSON()
        let payload: [String: Any] = [
            "type": "state",
            "data": workspaces,
            "tmuxSessions": cachedTmuxSessions
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8) else { return }

        let clients = connectedClients  // capture on main thread
        DispatchQueue.global(qos: .utility).async {
            for client in clients {
                client.writeText(message)
            }
        }
    }

    // MARK: - Reaper and Heartbeat

    /// Start the periodic reaper (every 15 seconds) that cleans up orphaned PTY sessions
    /// and sends WebSocket pings.
    private func startReaperAndHeartbeat() {
        reaperTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            // Reap orphaned PTY sessions on a background thread.
            DispatchQueue.global(qos: .utility).async {
                let reaped = PTYSessionManager.shared.reapOrphans()
                if reaped > 0 {
                    print("EmbeddedServer: Reaped \(reaped) orphaned PTY session(s)")
                }
            }
        }
        // Separate ping timer every 30 seconds.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPings()
            }
        }
    }

    /// Send a ping message to all connected terminal WebSocket clients.
    private func sendPings() {
        // We don't track terminal WS clients separately from state WS clients,
        // but the ping message is harmless for state clients (they'll ignore unknown types).
        let clients = connectedClients
        let pingMsg = "{\"type\":\"ping\"}"
        DispatchQueue.global(qos: .utility).async {
            for client in clients {
                client.writeText(pingMsg)
            }
        }
    }

    // MARK: - Notification Forwarding

    /// Forward a terminal notification to all connected WebSocket clients.
    /// Called from TerminalNotificationStore when a new notification is added.
    func forwardNotification(_ notification: TerminalNotification) {
        let json: [String: Any] = [
            "type": "notification",
            "id": notification.id.uuidString,
            "title": notification.title,
            "subtitle": notification.subtitle,
            "body": notification.body,
            "tabId": notification.tabId.uuidString,
            "isRead": notification.isRead,
            "createdAt": ISO8601DateFormatter().string(from: notification.createdAt)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }

        // connectedClients is modified on main, so read it on main too
        let send = { [weak self] in
            guard let clients = self?.connectedClients, !clients.isEmpty else { return }
            DispatchQueue.global(qos: .utility).async {
                for client in clients {
                    client.writeText(str)
                }
            }
        }
        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async { send() }
        }
    }

    // MARK: - JSON Builders

    /// Build a status summary dictionary.  Must be called on MainActor.
    private func buildStatusJSON() -> [String: Any] {
        let tabManager = AppDelegate.shared?.tabManager
        return [
            "version": "anterminal 1.0.0",
            "workspaceCount": tabManager?.tabs.count ?? 0,
            "selectedWorkspace": tabManager?.selectedTabId?.uuidString ?? "",
            "unreadCount": TerminalNotificationStore.shared.unreadCount,
            "connectedClients": connectedClients.count,
            "port": Int(port),
            "uptime": ProcessInfo.processInfo.systemUptime,
            "ccSessionCount": ClaudeSessionScanner.shared.recentSessions(limit: 1).count > 0 ? ClaudeSessionScanner.shared.recentSessions().count : 0
        ]
    }

    /// Build an array of workspace dictionaries.  Must be called on MainActor.
    private func buildWorkspacesJSON() -> [[String: Any]] {
        guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
        return tabManager.tabs.map { workspace in
            let unread = TerminalNotificationStore.shared.unreadCount(forTabId: workspace.id)
            var info: [String: Any] = [
                "id": workspace.id.uuidString,
                "title": workspace.customTitle ?? workspace.title,
                "directory": workspace.currentDirectory,
                "panelCount": workspace.panels.count,
                "unreadCount": unread,
                "isPinned": workspace.isPinned,
                "isTmuxEnabled": workspace.isTmuxEnabled,
                "isSelected": workspace.id == tabManager.selectedTabId
            ]
            if let color = workspace.customColor {
                info["color"] = color
            }
            // Include tmux session info for each panel so the web UI can attach.
            var panels: [[String: Any]] = []
            for (panelId, _) in workspace.panels {
                var panelInfo: [String: Any] = [
                    "id": panelId.uuidString,
                    "directory": workspace.panelDirectories[panelId] ?? workspace.currentDirectory
                ]
                if let tmuxName = TmuxSessionManager.shared.getSessionName(for: panelId) {
                    panelInfo["tmuxSession"] = tmuxName
                }
                panels.append(panelInfo)
            }
            if !panels.isEmpty {
                info["panels"] = panels
            }

            // Include the split tree layout so the web UI can mirror the exact pane arrangement
            let tree = workspace.bonsplitController.treeSnapshot()
            let layoutSnapshot = workspace.sessionLayoutSnapshot(from: tree)
            if let layoutData = try? JSONEncoder().encode(layoutSnapshot),
               let layoutJSON = try? JSONSerialization.jsonObject(with: layoutData) {
                info["layout"] = layoutJSON
            }

            return info
        }
    }

    /// Build an array of notification dictionaries.  Must be called on MainActor.
    private func buildNotificationsJSON() -> [[String: Any]] {
        return TerminalNotificationStore.shared.notifications.prefix(50).map { n in
            [
                "id": n.id.uuidString,
                "title": n.title,
                "subtitle": n.subtitle,
                "body": n.body,
                "tabId": n.tabId.uuidString,
                "isRead": n.isRead,
                "createdAt": ISO8601DateFormatter().string(from: n.createdAt)
            ]
        }
    }

    // MARK: - Port Cleanup

    /// Kill any process listening on the given port and wait for it to release.
    private func killProcessOnPort(_ port: Int) {
        // SIGKILL to ensure they die immediately
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        var killed = false
        for line in output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid != getpid() {
                kill(pid, SIGKILL)  // SIGKILL, not SIGTERM — we need the port NOW
                killed = true
                print("anterminal: Killed stale process \(pid) on port \(port)")
            }
        }

        guard killed else { return }

        // Wait for the port to actually become available (up to 3 seconds)
        for _ in 0..<30 {
            usleep(100_000) // 100ms
            let check = Process()
            let checkPipe = Pipe()
            check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            check.arguments = ["-ti", ":\(port)"]
            check.standardOutput = checkPipe
            check.standardError = FileHandle.nullDevice
            do {
                try check.run()
                check.waitUntilExit()
                let checkData = checkPipe.fileHandleForReading.readDataToEndOfFile()
                let checkOutput = String(data: checkData, encoding: .utf8) ?? ""
                // Filter out our own PID
                let otherPids = checkOutput.split(separator: "\n").filter {
                    Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) != getpid()
                }
                if otherPids.isEmpty {
                    print("anterminal: Port \(port) is now free")
                    return
                }
            } catch { return }
        }
        print("anterminal: Warning — port \(port) may still be in use after 3s wait")
    }
}
