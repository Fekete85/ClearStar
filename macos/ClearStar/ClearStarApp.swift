import ClearStarAppModel
import ClearStarCore
import SwiftUI

@main
struct ClearStarApp: App {
    @State private var model: AppModel
    @State private var zoom: ZoomCommand?
    @FocusedValue(\.inspectorVisible) private var inspectorVisible
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    init() {
        // The languages: bundled (shared/Languages) and the user's folder; the choice from the settings,
        // otherwise the system language when there is a file for it.
        L.load(UserSettings.get(UserSettings.languageKey) ?? L.systemLanguage())
        let model = AppModel()
        _model = State(initialValue: model)
        // A folder or image given on the command line (like the Windows version): load and stack.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first, FileManager.default.fileExists(atPath: path) {
            model.showWelcome = false
            Task { @MainActor in await model.loadPath(path) }
        }
    }

    var body: some Scene {
        Window("ClearStar", id: "main") {
            MainView(model: model, zoom: $zoom)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1500, height: 950)
        .commands { commands }

        Window(L.t("mac.menu.about"), id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }

    @CommandsBuilder private var commands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L.t("mac.menu.about")) { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {
            Button(L.t("mac.menu.open")) {
                if let url = Panels.chooseFolderOrImage() { Task { await model.loadPath(url.path) } }
            }
            .keyboardShortcut("o")
            .disabled(model.isBusy)
        }
        CommandMenu(L.t("mac.menu.step")) {
            Button(L.t("mac.menu.apply")) { Task { await model.applySelected() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isBusy)
            Button(L.t("mac.menu.skip")) { if let s = model.selectedStep { model.skip(s) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.isBusy || model.selectedStep?.canSkip != true)
            Button(L.t("mac.menu.reset")) { if let s = model.selectedStep { model.resetParameters(s) } }
                .disabled(model.isBusy)
            Button(L.t("mac.menu.cancel")) { model.cancelRunning() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isBusy)
            Divider()
            Button(L.t("mac.menu.previous")) { model.selectPrevious() }.keyboardShortcut("[", modifiers: .command)
            Button(L.t("mac.menu.next")) { model.selectNext() }.keyboardShortcut("]", modifiers: .command)
            Divider()
            Button(L.t("mac.menu.starnet")) { model.showStarNetSetup = true }
            Button(L.t("mac.menu.catalog")) { model.showCatalogSetup = true }
        }
        CommandGroup(after: .toolbar) {
            Button(L.t("ui.viewer.zoomIn")) { zoom = ZoomCommand(kind: .zoomIn) }.keyboardShortcut("+")
            Button(L.t("ui.viewer.zoomOut")) { zoom = ZoomCommand(kind: .zoomOut) }.keyboardShortcut("-")
            Button(L.t("ui.viewer.fit")) { zoom = ZoomCommand(kind: .fit) }.keyboardShortcut("0")
            Divider()
            Toggle(L.t("ui.toolbar.split"), isOn: $model.splitView).keyboardShortcut("d")
            Toggle(L.t("ui.toolbar.boost"), isOn: $model.autoStretch).keyboardShortcut("b")
            Toggle(L.t("mac.menu.original"), isOn: $model.showOriginal).keyboardShortcut("o", modifiers: [.command, .option])
            if let inspectorVisible {
                Toggle(L.t("mac.menu.inspector"), isOn: inspectorVisible).keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        CommandGroup(replacing: .help) {
            Button(L.t("mac.menu.support")) { openURL(URL(string: AppLinks.support)!) }
            Button("clearstar.blackit.hu") { openURL(URL(string: "https://clearstar.blackit.hu/")!) }
        }
    }
}
