import SwiftUI
import ClearStarCore

@main
struct ClearStarApp: App {
    /// A közös nyelvi fájlok a bundle-ben (shared/Languages → Resources/Languages).
    private let strings: Strings = {
        let dir = Bundle.main.url(forResource: "Languages", withExtension: nil)!
        return Strings(language: Strings.systemLanguage(in: dir), directory: dir)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(strings: strings)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
