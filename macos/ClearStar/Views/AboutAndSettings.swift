import AppKit
import ClearStarAppModel
import ClearStarCore
import SwiftUI

/// About: version, author, summary, support, the licence, the third-party notices and the model licences.
struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var tab = "about"

    private var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "") + " (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClearStar").font(.largeTitle.weight(.semibold))
                    Text(L.t("ui.about.tagline")).foregroundStyle(.secondary)
                    Text(L.f("ui.about.version", version)).font(.caption).foregroundStyle(.secondary)
                    Text(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $tab) {
                Text(L.t("ui.about.tabAbout")).tag("about")
                Text(L.t("ui.about.tabLicense")).tag("license")
                Text(L.t("ui.about.tabThirdParty")).tag("thirdparty")
                Text(L.t("ui.about.tabModels")).tag("models")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                Group {
                    switch tab {
                    case "license": Text(Legal.text("LICENSE")).font(.system(.caption, design: .monospaced))
                    case "thirdparty": Text(Legal.markdown("THIRD-PARTY-NOTICES.md"))
                    case "models":
                        VStack(alignment: .leading, spacing: 16) {
                            modelSection(L.t("ui.about.modelBge"), "GraXpert-BGE-Model-LICENSE.txt")
                            modelSection(L.t("ui.about.modelDenoise"), "GraXpert-Denoise-Model-LICENSE.txt")
                            modelSection(L.t("ui.about.modelDeconv"), "GraXpert-Deconvolution-Model-LICENSE.txt")
                        }
                    default:
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L.t("ui.about.summary")).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button(L.t("mac.about.support")) { openURL(URL(string: AppLinks.support)!) }
                                Button(L.t("mac.about.website")) { openURL(URL(string: "https://clearstar.blackit.hu/")!) }
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
    }

    private func modelSection(_ title: String, _ file: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(Legal.text(file)).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The legal texts bundled with the app (Resources/Legal).
enum Legal {
    static func text(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Legal") ??
                Bundle.main.url(forResource: name, withExtension: nil),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return name }
        return s
    }

    static func markdown(_ name: String) -> AttributedString {
        let s = text(name)
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Settings: interface language, GPU for the AI models.
struct SettingsView: View {
    @State private var language = UserSettings.get(UserSettings.languageKey) ?? L.language
    @State private var gpu = CoreMLRunner.gpuEnabled
    private let startLanguage = L.language

    var body: some View {
        Form {
            Section(L.t("ui.about.language")) {
                Picker(L.t("ui.about.language"), selection: $language) {
                    ForEach(L.available(), id: \.code) { Text($0.name).tag($0.code) }
                }
                .onChange(of: language) { _, new in UserSettings.set(UserSettings.languageKey, new) }
                Text(L.t("mac.settings.languageNote")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L.t("ui.about.languageFolder")) {
                        try? FileManager.default.createDirectory(at: L.userLanguagesDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(L.userLanguagesDirectory)
                    }
                    if language.lowercased() != startLanguage.lowercased() {
                        Button(L.t("mac.settings.restart")) { Relauncher.relaunch() }.buttonStyle(.glassProminent)
                    }
                }
            }
            Section("AI") {
                Toggle(L.t("mac.settings.gpu"), isOn: $gpu)
                    .onChange(of: gpu) { _, new in CoreMLRunner.gpuEnabled = new; CoreMLRunner.unloadAll() }
                Text(L.t("mac.settings.gpuNote")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

enum Relauncher {
    @MainActor static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
