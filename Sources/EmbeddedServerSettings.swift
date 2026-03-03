import Foundation

// MARK: - Embedded Server Settings

/// Persisted settings for the optional embedded HTTP/WebSocket server.
/// Follows the same enum-with-static-accessors pattern used throughout cmux
/// (e.g. ServerBridgeSettings, NotificationBadgeSettings, WorkspaceAutoReorderSettings).
enum EmbeddedServerSettings {
    // MARK: Keys & Defaults

    static let enabledKey = "embeddedServerEnabled"
    static let defaultEnabled = false

    static let portKey = "embeddedServerPort"
    static let defaultPort = 4848

    static let tmuxEnabledKey = "embeddedServerTmuxEnabled"
    static let defaultTmuxEnabled = false

    // MARK: Accessors

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func port(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: portKey)
        if value <= 0 {
            return defaultPort
        }
        return value
    }

    // MARK: Tmux

    static func tmuxEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: tmuxEnabledKey) == nil {
            return defaultTmuxEnabled
        }
        return defaults.bool(forKey: tmuxEnabledKey)
    }

    static func setTmuxEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: tmuxEnabledKey)
    }
}
