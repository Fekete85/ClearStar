import Foundation

/// Key–value settings in `~/Library/Application Support/ClearStar/settings.json` (language, model
/// choice…) – the same flat JSON object and the same keys as the Windows version's settings.json.
public enum UserSettings {
    public static let languageKey = "language"
    private static let lock = NSLock()

    public static var url: URL { AppPaths.support.appendingPathComponent("settings.json") }

    public static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[key]
    }

    public static func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        s[key] = value
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: url, options: .atomic) }
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

/// Web addresses the app points the user to.
public enum AppLinks {
    /// Where a grateful user can buy the author a coffee (welcome screen and About window).
    public static let support = "https://revolut.me/laszlohmy"

    /// The author's download mirror: AI models and the Siril offline catalogue, with a manifest.json
    /// listing every file's size and SHA-256. The `mirror.url` setting (or the CLEARSTAR_MIRROR
    /// environment variable) points elsewhere – used by the tests with a local mirror.
    public static var mirror: String {
        if let env = ProcessInfo.processInfo.environment["CLEARSTAR_MIRROR"], !env.isEmpty { return env }
        if let s = UserSettings.get("mirror.url"), !s.isEmpty { return s }
        return "https://csillag.blackit.hu/clearstar/"
    }
}
