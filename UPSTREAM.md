# Syncing with upstream cmux

anterminal is a fork of [cmux](https://github.com/manaflow-ai/cmux). Here's how to pull in upstream changes.

## Setup (one-time)

```bash
cd ~/test/warp-terminal
git remote add upstream https://github.com/manaflow-ai/cmux.git
```

## Syncing

```bash
# Fetch latest upstream
git fetch upstream

# See what's changed
git log upstream/main --oneline -20

# Merge upstream into your branch
git merge upstream/main

# If there are conflicts, resolve them. Our custom files are:
# - Sources/EmbeddedServer.swift (new)
# - Sources/EmbeddedServerSettings.swift (new)
# - Sources/EmbeddedServerHTML.swift (new)
# - Sources/PTYWebSocket.swift (new)
# - Sources/TmuxSessionManager.swift (new)
# - Sources/ServerBridge.swift (new)
# - Sources/ServerBridgeSettings.swift (new)
# - Sources/ServerBridgeKeychain.swift (new)
#
# Modified files (may conflict):
# - Sources/AppDelegate.swift (small additions)
# - Sources/GhosttyTerminalView.swift (tmux integration)
# - Sources/TerminalNotificationStore.swift (1 line)
# - Sources/ContentView.swift (sidebar footer + tmux badge)
# - Sources/Workspace.swift (isTmuxEnabled property)
# - Sources/TabManager.swift (isTmux parameter)
# - Sources/cmuxApp.swift (menu items + settings)
# - Sources/Update/UpdateTitlebarAccessory.swift (+ button menu)
# - GhosttyTabs.xcodeproj/project.pbxproj (new file refs)
# - Package.swift (Swifter dependency)
```

## After merge

```bash
# Rebuild GhosttyKit if ghostty submodule was updated
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast -Dxcframework-target=native
cd ..
ln -sfn ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework

# Rebuild
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
```

## Our additions (files that won't conflict with upstream)

These are entirely new files that upstream cmux doesn't have:
- `Sources/EmbeddedServer*.swift` - Built-in web server
- `Sources/PTYWebSocket.swift` - PTY WebSocket for web terminals
- `Sources/TmuxSessionManager.swift` - tmux session management
- `Sources/ServerBridge*.swift` - Server bridge (optional)
