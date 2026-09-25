import Foundation

/// The language database for the whole app – the counterpart of the C# static `L` class. Every text
/// comes from here by key. Built-in languages ship in the app bundle's `Languages` folder; further
/// `xx.json` files may be put into `~/Library/Application Support/ClearStar/Languages` (a file with
/// the same code overrides the built-in one). Missing keys come from the English fallback, finally
/// from the key itself.
public enum L {
    private static let state = Locked<(strings: Strings?, directories: [URL])>((nil, []))

    /// Folders searched for language files, in increasing priority.
    public static var directories: [URL] {
        get {
            let dirs = state.current.directories
            if !dirs.isEmpty { return dirs }
            var result: [URL] = []
            if let bundled = Bundle.main.url(forResource: "Languages", withExtension: nil) { result.append(bundled) }
            result.append(userLanguagesDirectory)
            return result
        }
        set { state.withLock { $0.directories = newValue } }
    }

    /// Where the user can drop new language files.
    public static var userLanguagesDirectory: URL { AppPaths.support.appendingPathComponent("Languages", isDirectory: true) }

    /// The loaded language's code ("" before anything was loaded).
    public static var language: String { state.current.strings?.language ?? "" }

    private static var strings: Strings {
        if let s = state.current.strings { return s }
        load(Strings.defaultLanguage)
        return state.current.strings!
    }

    /// Loads a language by code (the fallback is always English).
    public static func load(_ code: String) {
        let s = Strings(language: code, directories: directories)
        state.withLock { $0.strings = s }
    }

    /// Tests / CLI: set a table directly.
    public static func load(_ strings: Strings) { state.withLock { $0.strings = strings } }

    public static func available() -> [LanguageInfo] { Strings.available(in: directories) }
    public static func systemLanguage() -> String { Strings.systemLanguage(in: directories) }

    public static func t(_ key: String) -> String { strings.t(key) }

    /// Formatted text with the .NET placeholders ({0}, {1:0.0} …), in the user's number format.
    public static func f(_ key: String, _ args: Any...) -> String { strings.format(key, args, locale: .current) }

    /// List (e.g. slider labels): the "|"-separated items.
    public static func a(_ key: String) -> [String] { strings.a(key) }

    public static func has(_ key: String) -> Bool { strings.has(key) }
}
