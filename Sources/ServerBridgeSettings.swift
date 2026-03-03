import Foundation

// MARK: - Server Bridge Settings

/// Persisted settings for the optional server bridge connection.
/// Follows the same enum-with-static-accessors pattern used throughout anterminal
/// (e.g. NotificationBadgeSettings, WorkspaceAutoReorderSettings, ClaudeCodeIntegrationSettings).
enum ServerBridgeSettings {
    // MARK: Keys & Defaults

    static let enabledKey = "serverBridgeEnabled"
    static let defaultEnabled = false

    static let urlKey = "serverBridgeURL"
    static let defaultURL = "http://localhost:4847"

    static let autoConnectKey = "serverBridgeAutoConnect"
    static let defaultAutoConnect = true

    static let syncIntervalKey = "serverBridgeSyncInterval"
    static let defaultSyncInterval: TimeInterval = 2.0

    static let forwardNotificationsKey = "serverBridgeForwardNotifications"
    static let defaultForwardNotifications = true

    // MARK: Accessors

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func serverURL(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: urlKey), !stored.isEmpty {
            return stored
        }
        return defaultURL
    }

    static func autoConnect(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: autoConnectKey) == nil {
            return defaultAutoConnect
        }
        return defaults.bool(forKey: autoConnectKey)
    }

    static func syncInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: syncIntervalKey)
        if value <= 0 {
            return defaultSyncInterval
        }
        return value
    }

    static func forwardNotifications(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: forwardNotificationsKey) == nil {
            return defaultForwardNotifications
        }
        return defaults.bool(forKey: forwardNotificationsKey)
    }
}
