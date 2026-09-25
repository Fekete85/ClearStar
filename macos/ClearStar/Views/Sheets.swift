import AppKit
import ClearStarAppModel
import ClearStarCore
import SwiftUI
import UniformTypeIdentifiers

/// Open / choose panels.
enum Panels {
    static let imageTypes: [UTType] = ["fit", "fits", "fts", "tif", "tiff", "png", "jpg", "jpeg"].compactMap { UTType(filenameExtension: $0) }

    @MainActor static func chooseFolder(title: String, start: String = "") -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        if !start.isEmpty { p.directoryURL = URL(fileURLWithPath: start) }
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor static func chooseFile(title: String, types: [UTType] = [], packagesAsFiles: Bool = true) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.treatsFilePackagesAsDirectories = !packagesAsFiles
        if !types.isEmpty { p.allowedContentTypes = types }
        return p.runModal() == .OK ? p.url : nil
    }

    /// Open…: a folder or a single image.
    @MainActor static func chooseFolderOrImage() -> URL? {
        let p = NSOpenPanel()
        p.title = L.t("mac.menu.open")
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.allowedContentTypes = imageTypes + [.folder]
        return p.runModal() == .OK ? p.url : nil
    }
}

struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                Text(L.t("ui.welcome.title")).font(.largeTitle.weight(.semibold))
            }
            Text(L.t("ui.welcome.lead")).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                card(1, L.t("ui.welcome.s1"), L.t("ui.welcome.s1sub"))
                card(2, L.t("ui.welcome.s2"), L.t("ui.welcome.s2sub"))
                card(3, L.t("ui.welcome.s3"), L.t("ui.welcome.s3sub"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("ui.welcome.support")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L.t("ui.welcome.supportButton")) { openURL(URL(string: AppLinks.support)!) }
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button(L.t("ui.welcome.start")) { model.closeWelcome() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(34)
        .frame(width: 660)
    }

    private func card(_ n: Int, _ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(n)").font(.callout.weight(.bold)).frame(width: 24, height: 24).background(Color.accentColor, in: Circle()).foregroundStyle(.white)
            Text(title).font(.headline)
            Text(sub).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Explains StarNet2, opens its download page and lets the user point ClearStar to the program.
struct StarNetSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var exe = StarNet.locate()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("ui.starnet.title")).font(.title2.weight(.semibold))
            Text(L.t("ui.starnet.whatTitle")).font(.headline)
            Text(L.t("ui.starnet.what")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L.t("ui.starnet.howTitle")).font(.headline)
            Text(L.t("mac.starnet.how")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L.t("ui.starnet.sirilNote")).font(.callout).foregroundStyle(.secondary)
            Label(error ?? exe.map { L.f("ui.starnet.found", $0) } ?? L.t("ui.starnet.missing"),
                  systemImage: exe == nil ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(error != nil ? Color.red : exe == nil ? Color.orange : Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L.t("ui.starnet.download")) { openURL(URL(string: StarNet.downloadUrl)!) }
                Button(L.t("ui.starnet.browse")) {
                    guard let url = Panels.chooseFile(title: L.t("mac.starnet.pickTitle")) else { return }
                    if FileManager.default.isExecutableFile(atPath: url.path) {
                        StarNet.setExecutable(url.path)
                        error = nil
                        exe = StarNet.locate()
                    } else {
                        error = L.t("mac.starnet.notExecutable")
                    }
                }
                Spacer()
                Button(L.t("ui.dialog.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 600)
    }
}

/// The offline Gaia catalogue: explanation, in-app download with progress and cancel, or an existing file.
struct CatalogSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var catalog = CatalogDownloadState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("ui.catalog.title")).font(.title2.weight(.semibold))
            Text(L.t("ui.catalog.whatTitle")).font(.headline)
            Text(L.t("ui.catalog.what")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L.t("ui.catalog.howTitle")).font(.headline)
            Text(L.t("ui.catalog.how")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L.t("ui.catalog.sirilNote")).font(.callout).foregroundStyle(.secondary)
            Label(catalog.status, systemImage: catalog.found == nil ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(catalog.isError ? Color.red : catalog.found == nil ? Color.orange : Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            if catalog.isDownloading {
                ProgressView(value: catalog.progress)
                Text(catalog.progressText).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if catalog.found == nil || catalog.isDownloading {
                    Button(L.t("ui.catalog.download")) { catalog.start() }.disabled(catalog.isDownloading)
                }
                if catalog.isDownloading { Button(L.t("ui.catalog.cancel")) { catalog.cancel() } }
                Button(L.t("ui.catalog.browse")) {
                    guard let url = Panels.chooseFile(title: L.t("ui.catalog.pickTitle")) else { return }
                    catalog.choose(url)
                }
                Button(L.t("ui.catalog.manual")) { openURL(URL(string: CatalogDownloader.recordUrl)!) }.buttonStyle(.link)
                Spacer()
                Button(L.t("ui.dialog.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 640)
        .onAppear { catalog.refresh() }
    }
}

/// The catalogue download keeps running when the sheet closes; reopening it shows the progress.
@MainActor @Observable
final class CatalogDownloadState {
    static let shared = CatalogDownloadState()
    private(set) var found: String?
    private(set) var status = ""
    private(set) var isError = false
    private(set) var isDownloading = false
    private(set) var progress = 0.0
    private(set) var progressText = ""
    @ObservationIgnored private var token: CancellationToken?

    func refresh() {
        found = LocalGaiaCatalog.locate()
        if !isError { status = found.map { L.f("ui.catalog.found", $0) } ?? L.t("ui.catalog.missing") }
    }

    func choose(_ url: URL) {
        guard LocalGaiaCatalog.open(url.path) != nil else { status = L.t("ui.catalog.invalid"); isError = true; return }
        UserSettings.set(LocalGaiaCatalog.pathSettingKey, url.path)
        isError = false
        refresh()
    }

    func start() {
        if isDownloading { return }
        let t = CancellationToken()
        token = t
        isDownloading = true
        isError = false
        progress = 0
        Task {
            do {
                try await CatalogDownloader.download(progress: { p in
                    Task { @MainActor in
                        self.progress = p.fraction
                        self.progressText = p.phase == "done" ? L.t("ui.catalog.verifying")
                            : L.f("ui.catalog.downloading", p.bytesDownloaded / 1_048_576, p.bytesTotal / 1_048_576)
                    }
                }, t)
                status = L.t("ui.catalog.downloaded")
            } catch is CancellationError {
                status = L.t("ui.status.cancelled")
            } catch {
                isError = true
                status = L.f("ui.catalog.downloadFailed", error.localizedDescription)
            }
            isDownloading = false
            let keepStatus = status
            refresh()
            if isError || found == nil { status = keepStatus }
        }
    }

    func cancel() { token?.cancel() }
}
