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

/// Settings live in `~/.config/roach-explorer/`, confirmed — not Application Support.
enum SettingsStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("roach-explorer", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

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
}
