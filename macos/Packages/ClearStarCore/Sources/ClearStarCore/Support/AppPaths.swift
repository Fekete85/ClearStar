import Foundation

/// The app's own folders (the %LOCALAPPDATA%\ClearStar of the Windows version).
public enum AppPaths {
    private static let override = Locked<URL?>(nil)

    /// `~/Library/Application Support/ClearStar` – settings, models, catalogues, languages.
    /// Tests may redirect it (and everything below it) with `useRoot(_:)`.
    public static var support: URL {
        if let o = override.current { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClearStar", isDirectory: true)
    }

    /// `~/Library/Caches/ClearStar` – the catalogue query cache.
    public static var caches: URL {
        if let o = override.current { return o.appendingPathComponent("Caches", isDirectory: true) }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ClearStar", isDirectory: true)
    }

    /// Temporary working folders (snapshots, StarNet files, downloads).
    public static var temporary: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ClearStar", isDirectory: true) }

    /// The user's home folder (the real one, not a container).
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Redirects the support and cache folders (tests); nil restores the defaults.
    public static func useRoot(_ root: URL?) { override.current = root }
}
