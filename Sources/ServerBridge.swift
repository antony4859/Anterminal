import Foundation
import Sentry

// MARK: - Server Bridge

/// Optional server bridge that connects the terminal app to a claude-manager
/// Express server for remote monitoring, phone access, and cost tracking.
///
/// The bridge is entirely opt-in: when disabled (the default) it does nothing and
/// adds zero overhead.  When enabled it:
///   - Opens a WebSocket to the server for bidirectional communication
///   - Periodically syncs workspace state so remote dashboards stay up-to-date
///   - Forwards terminal notifications to the server
///   - Accepts commands from the server and routes them through TerminalController
@MainActor
class ServerBridge {
    static let shared = ServerBridge()

    // MARK: - Public State

    private(set) var isConnected = false
    private(set) var serverURL: URL?

    // MARK: - Private State

    private nonisolated(unsafe) var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var stateTimer: Timer?
    private var authToken: String?
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTimer: Timer?
    private var isStarted = false

    // MARK: - Constants

    private static let maxReconnectDelay: TimeInterval = 30.0
    private static let initialReconnectDelay: TimeInterval = 1.0

    private init() {}

    // MARK: - Lifecycle

    /// Start the bridge. Called from AppDelegate.applicationDidFinishLaunching when enabled.
    func start() {
        guard ServerBridgeSettings.isEnabled() else { return }
        guard !isStarted else { return }
        isStarted = true

        sentryBreadcrumb("serverBridge.start", category: "bridge")

        let urlString = ServerBridgeSettings.serverURL()
        guard let url = URL(string: urlString) else {
            print("ServerBridge: Invalid server URL: \(urlString)")
            return
        }
        serverURL = url

        // Load auth token from keychain
        authToken = ServerBridgeKeychain.loadToken()

        // Create a dedicated URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)

        // Connect WebSocket
        connectWebSocket()

        // Start state sync timer
        let interval = ServerBridgeSettings.syncInterval()
        stateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncState()
            }
        }
    }

    /// Stop the bridge. Called from AppDelegate.applicationWillTerminate.
    func stop() {
        guard isStarted else { return }
        isStarted = false

        sentryBreadcrumb("serverBridge.stop", category: "bridge")

        stateTimer?.invalidate()
        stateTimer = nil

        reconnectTimer?.invalidate()
        reconnectTimer = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        session?.invalidateAndCancel()
        session = nil

        isConnected = false
        serverURL = nil
        reconnectDelay = Self.initialReconnectDelay
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket() {
        guard isStarted, let serverURL else { return }

        // Convert http(s) to ws(s)
        var wsURLString = serverURL.absoluteString
        if wsURLString.hasPrefix("https://") {
            wsURLString = "wss://" + wsURLString.dropFirst("https://".count)
        } else if wsURLString.hasPrefix("http://") {
            wsURLString = "ws://" + wsURLString.dropFirst("http://".count)
        }
        // Append the bridge WebSocket endpoint
        if !wsURLString.hasSuffix("/") {
            wsURLString += "/"
        }
        wsURLString += "ws/terminal-app"

        guard let wsURL = URL(string: wsURLString), let session else {
            print("ServerBridge: Cannot form WebSocket URL from \(wsURLString)")
            return
        }

        var request = URLRequest(url: wsURL)
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()

        sentryBreadcrumb("serverBridge.ws.connecting", category: "bridge", data: [
            "url": wsURLString
        ])

        receiveWebSocketMessage()
    }

    private func receiveWebSocketMessage() {
        guard let webSocket else { return }

        webSocket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }

                switch result {
                case .success(let message):
                    // Mark connected on the first successful receive (the server's
                    // welcome / handshake message) instead of guessing with a timer.
                    if !self.isConnected {
                        self.isConnected = true
                        self.reconnectDelay = Self.initialReconnectDelay
                        sentryBreadcrumb("serverBridge.ws.connected", category: "bridge")
                        // Send initial state immediately upon connection
                        self.syncState()
                    }
                    self.handleServerCommand(message)
                    // Continue receiving
                    self.receiveWebSocketMessage()

                case .failure(let error):
                    print("ServerBridge: WebSocket receive error: \(error.localizedDescription)")
                    sentryBreadcrumb("serverBridge.ws.error", category: "bridge", data: [
                        "error": error.localizedDescription
                    ])
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard isStarted else { return }

        reconnectTimer?.invalidate()
        let delay = reconnectDelay

        sentryBreadcrumb("serverBridge.ws.reconnect.scheduled", category: "bridge", data: [
            "delay": delay
        ])

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.webSocket?.cancel(with: .goingAway, reason: nil)
                self.webSocket = nil
                self.connectWebSocket()
            }
        }

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s cap
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
    }

    // MARK: - State Sync

    /// Collect workspace state from TabManager and send to the server.
    private func syncState() {
        guard isStarted, isConnected else { return }
        guard let tabManager = AppDelegate.shared?.tabManager else { return }

        var workspaces: [[String: Any]] = []
        for workspace in tabManager.tabs {
            let unreadCount = TerminalNotificationStore.shared.unreadCount(forTabId: workspace.id)
            var wsInfo: [String: Any] = [
                "id": workspace.id.uuidString,
                "title": workspace.customTitle ?? workspace.title,
                "directory": workspace.currentDirectory,
                "panelCount": workspace.panels.count,
                "unreadCount": unreadCount,
                "isPinned": workspace.isPinned,
            ]
            if let color = workspace.customColor {
                wsInfo["color"] = color
            }
            workspaces.append(wsInfo)
        }

        let payload: [String: Any] = [
            "type": "terminal_state",
            "workspaces": workspaces,
            "selected": tabManager.selectedTabId?.uuidString ?? "",
            "totalUnread": TerminalNotificationStore.shared.unreadCount,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]

        sendWebSocketJSON(payload)
    }

    // MARK: - Notification Forwarding

    /// Forward a terminal notification to the server.
    /// Called from TerminalNotificationStore when a new notification is added.
    func forwardNotification(_ notification: TerminalNotification) {
        guard isStarted, isConnected else { return }
        guard ServerBridgeSettings.forwardNotifications() else { return }

        let payload: [String: Any] = [
            "type": "notification",
            "id": notification.id.uuidString,
            "tabId": notification.tabId.uuidString,
            "surfaceId": notification.surfaceId?.uuidString ?? "",
            "title": notification.title,
            "subtitle": notification.subtitle,
            "body": notification.body,
            "createdAt": ISO8601DateFormatter().string(from: notification.createdAt),
        ]

        sendWebSocketJSON(payload)

        sentryBreadcrumb("serverBridge.notification.forwarded", category: "bridge", data: [
            "notificationId": notification.id.uuidString
        ])
    }

    // MARK: - Command Handling

    /// Handle an incoming command from the server via WebSocket.
    private func handleServerCommand(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else { return }
            data = textData
        case .data(let binaryData):
            data = binaryData
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("ServerBridge: Failed to parse incoming command JSON")
            return
        }

        guard let type = json["type"] as? String else { return }

        switch type {
        case "command":
            routeCommand(json)
        case "ping":
            sendWebSocketJSON(["type": "pong"])
        case "auth_required":
            Task { @MainActor [weak self] in
                await self?.authenticate()
            }
        default:
            sentryBreadcrumb("serverBridge.command.unknown", category: "bridge", data: [
                "type": type
            ])
        }
    }

    /// Route a command to TerminalController for execution.
    private func routeCommand(_ json: [String: Any]) {
        guard let method = json["method"] as? String else { return }
        let params = json["params"] as? [String: Any] ?? [:]
        let requestId = json["id"] as? String

        sentryBreadcrumb("serverBridge.command.received", category: "bridge", data: [
            "method": method
        ])

        // Build a V2 JSON-RPC style command string for TerminalController
        var commandDict: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if let requestId {
            commandDict["id"] = requestId
        }

        guard let commandData = try? JSONSerialization.data(withJSONObject: commandDict),
              let commandString = String(data: commandData, encoding: .utf8) else {
            print("ServerBridge: Failed to serialize command for TerminalController")
            return
        }

        // Route through TerminalController's command handling.
        // We write the command to the socket controller by building a V2 envelope.
        // TerminalController is @MainActor so we can call it here.
        TerminalController.shared.handleBridgeCommand(commandString) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                // Forward the response back to the server
                var responsePayload: [String: Any] = [
                    "type": "command_response",
                    "method": method,
                ]
                if let requestId {
                    responsePayload["id"] = requestId
                }
                responsePayload["result"] = response
                self.sendWebSocketJSON(responsePayload)
            }
        }
    }

    // MARK: - Authentication

    /// Authenticate with the server using a stored or keychain-retrieved token.
    private func authenticate() async {
        guard isStarted, let serverURL, let session else { return }

        let authURL = serverURL.appendingPathComponent("api/auth/login")
        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("ServerBridge: Authentication failed")
                sentryBreadcrumb("serverBridge.auth.failed", category: "bridge")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["token"] as? String {
                authToken = token
                try? ServerBridgeKeychain.saveToken(token)
                sentryBreadcrumb("serverBridge.auth.success", category: "bridge")
            }
        } catch {
            print("ServerBridge: Authentication error: \(error.localizedDescription)")
            sentryBreadcrumb("serverBridge.auth.error", category: "bridge", data: [
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - WebSocket Helpers

    /// Send a JSON dictionary over the WebSocket.
    private func sendWebSocketJSON(_ payload: [String: Any]) {
        guard let webSocket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        webSocket.send(.string(text)) { error in
            if let error {
                print("ServerBridge: WebSocket send error: \(error.localizedDescription)")
            }
        }
    }
}
