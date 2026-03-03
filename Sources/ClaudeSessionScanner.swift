import Foundation

/// Discovers Claude Code sessions by scanning ~/.claude/projects/
///
/// Claude Code stores conversation transcripts as .jsonl files under
/// `~/.claude/projects/<encoded-path>/<uuid>.jsonl`.  The encoded path
/// replaces `/` with `-`, so `/Users/foo/bar` becomes `-Users-foo-bar`.
///
/// This scanner walks that directory tree, extracts session metadata
/// (UUID, project path, last-modified date, file size), and returns
/// the results sorted by most-recently-modified first.  Results are
/// cached for 30 seconds so that rapid polling from the web UI or
/// the state broadcast loop does not hit the filesystem every time.
class ClaudeSessionScanner {
    static let shared = ClaudeSessionScanner()

    struct DiscoveredSession: Identifiable {
        var id: String { uuid }
        let uuid: String
        let projectPath: String  // decoded real path e.g. /Users/foo/myproject
        let projectName: String  // last path component e.g. myproject
        let lastModified: Date
        let sizeBytes: Int64
    }

    private var cache: [DiscoveredSession] = []
    private var lastScanTime: Date = .distantPast
    private let cacheTTL: TimeInterval = 30  // 30 second cache

    /// Scan and return recent CC sessions (cached).
    func recentSessions(limit: Int = 30) -> [DiscoveredSession] {
        let now = Date()
        if now.timeIntervalSince(lastScanTime) > cacheTTL {
            cache = scanSessions()
            lastScanTime = now
        }
        return Array(cache.prefix(limit))
    }

    /// Force-refresh the cache on next access.
    func invalidateCache() {
        lastScanTime = .distantPast
    }

    /// Decode an encoded project path: -Users-foo-bar -> /Users/foo/bar
    ///
    /// The encoding replaces `/` with `-`.  The leading `-` represents the
    /// root `/`, so we simply swap all dashes back to slashes and ensure
    /// the result starts with `/`.
    private func decodePath(_ encoded: String) -> String {
        var path = encoded.replacingOccurrences(of: "-", with: "/")
        // Ensure it starts with /
        if !path.hasPrefix("/") { path = "/" + path }
        return path
    }

    private func scanSessions() -> [DiscoveredSession] {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var sessions: [DiscoveredSession] = []

        for dirName in projectDirs {
            // Encoded paths start with - (representing the root /)
            guard dirName.hasPrefix("-") else { continue }
            let dirPath = projectsDir + "/" + dirName

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let decodedPath = decodePath(dirName)
            let projectName = (decodedPath as NSString).lastPathComponent

            // Find .jsonl files in this directory
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for file in files {
                guard file.hasSuffix(".jsonl") else { continue }
                let filePath = dirPath + "/" + file
                let uuid = (file as NSString).deletingPathExtension

                // Get file attributes
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int64 else { continue }

                sessions.append(DiscoveredSession(
                    uuid: uuid,
                    projectPath: decodedPath,
                    projectName: projectName,
                    lastModified: modDate,
                    sizeBytes: size
                ))
            }
        }

        // Sort by most recent first
        sessions.sort { $0.lastModified > $1.lastModified }
        return sessions
    }
}
