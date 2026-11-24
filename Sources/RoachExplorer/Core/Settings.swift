import Foundation

struct Settings: Codable {
    var lastPath: String?
    var windowFrame: WindowFrame?
    /// Favorite folder paths. Missing from older files, so decode must not fail.
    var favorites: [String]

    init(lastPath: String? = nil, windowFrame: WindowFrame? = nil, favorites: [String] = []) {
        self.lastPath = lastPath
        self.windowFrame = windowFrame
        self.favorites = favorites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastPath = try container.decodeIfPresent(String.self, forKey: .lastPath)
        windowFrame = try container.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
    }
}

struct WindowFrame: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Per-folder view settings: sort column/direction and column widths.
struct FolderViewSettings: Codable, Equatable {
    var sortColumn: String
    var sortAscending: Bool
    var columnWidths: [String: Double]

    static let `default` = FolderViewSettings(
        sortColumn: "Name",
        sortAscending: true,
        columnWidths: [
            "Name": 300,
            "Date modified": 120,
            "Size": 80,
            "Kind": 180
        ]
    )
}

/// One entry in the MRU list of folder views.
struct FolderViewEntry: Codable {
    let path: String
    let settings: FolderViewSettings

    /// The list after remembering `path` again: it moves to the front, and the
    /// tail past `cap` falls off. Pure, so it can be tested without a file.
    static func updating(
        _ entries: [FolderViewEntry],
        path: String,
        settings: FolderViewSettings,
        cap: Int
    ) -> [FolderViewEntry] {
        var updated = entries.filter { $0.path != path }
        updated.insert(FolderViewEntry(path: path, settings: settings), at: 0)
        return Array(updated.prefix(cap))
    }
}

/// Settings live in `~/.config/roach-explorer/`, confirmed — not Application Support.
enum SettingsStore {
    /// `ROACH_CONFIG_DIR` moves the whole settings folder, so a test run
    /// never writes over the real favourites. Same idea as `ROACH_START_PATH`.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ROACH_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("roach-explorer", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    private static var folderViewsURL: URL {
        directory.appendingPathComponent("folderViews.json")
    }

    /// Maximum number of folder view entries to keep. Oldest are dropped.
    static let maxFolderViews = 100

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    static func save(_ settings: Settings) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Roach Explorer: could not save settings: \(error)")
        }
    }

    /// Load the per-folder view list, most-recent-first. Entries that are just the
/// defaults are ignored, so an older build's noise does not count as "custom".
    static func loadFolderViews() -> [FolderViewEntry] {
        guard let data = try? Data(contentsOf: folderViewsURL) else { return [] }
        let entries = (try? JSONDecoder().decode([FolderViewEntry].self, from: data)) ?? []
        return entries.filter { $0.settings != FolderViewSettings.default }
    }

    /// Save the per-folder view list (already ordered most-recent-first, capped).
    static func saveFolderViews(_ entries: [FolderViewEntry]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: folderViewsURL, options: .atomic)
        } catch {
            NSLog("Roach Explorer: could not save folder views: \(error)")
        }
    }

    /// Upsert a folder's view settings and move it to the front (MRU).
    /// Drops entries past `maxFolderViews`.
    static func upsertFolderView(path: String, settings: FolderViewSettings) {
        let updated = FolderViewEntry.updating(
            loadFolderViews(),
            path: (path as NSString).standardizingPath,
            settings: settings,
            cap: maxFolderViews
        )
        saveFolderViews(updated)
    }

    /// Forget a folder's custom view. Used when it drifts back to the defaults,
    /// so the list only ever holds folders someone actually tuned.
    static func removeFolderView(path: String) {
        let normalized = (path as NSString).standardizingPath
        var entries = loadFolderViews()
        let before = entries.count
        entries.removeAll { $0.path == normalized }
        if entries.count != before { saveFolderViews(entries) }
    }

    /// Fetch a folder's view settings. Reading does not reorder the file.
    static func fetchFolderView(path: String) -> FolderViewSettings? {
        let normalized = (path as NSString).standardizingPath
        return loadFolderViews().first { $0.path == normalized }?.settings
    }
}
