import Foundation

/// Step 1: read a folder (or a single image) and sort the frames by type.
public final class LoadFramesStep: WorkflowStep {
    public static let folderKey = "folder"
    private static let s = "load"

    public let definition = StepDefinition.fromLanguage(.loadFrames, .preparation, s, [StepKit.folder(s, folderKey)])

    public init() {}

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let path = context.parameters.getString(Self.folderKey).trimmingCharacters(in: .whitespaces)
        if path.isEmpty { throw ClearStarError(L.t("msg.load.chooseFolder")) }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let frames: FrameSet
        if exists && !isDir.boolValue {
            if !ImageFiles.isSupported(path) { throw ClearStarError(L.t("msg.load.unsupported")) }
            var info = FrameSet.inspect(path)
            info.type = .light
            frames = FrameSet(folder: (path as NSString).deletingLastPathComponent, frames: [info])
        } else if exists {
            context.report(0, L.t("msg.load.searching"))
            frames = try FrameSet.scan(path, progress: { p in context.report(p, L.t("msg.load.inspecting")) }, ct: context.cancellation)
            if frames.frames.isEmpty { throw ClearStarError(L.t("msg.load.noImages")) }
            if frames.lights.isEmpty { throw ClearStarError(L.t("msg.load.noLights")) }
        } else {
            throw ClearStarError(L.t("msg.load.notFound"))
        }
        return StepResult(image: nil, summary: Self.describe(frames), frames: frames)
    }

    public static func describe(_ frames: FrameSet) -> String {
        var parts = [L.f("msg.load.lights", frames.count(.light))]
        if frames.count(.dark) > 0 { parts.append(L.f("msg.load.darks", frames.count(.dark))) }
        if frames.count(.flat) > 0 { parts.append(L.f("msg.load.flats", frames.count(.flat))) }
        if frames.count(.bias) > 0 { parts.append(L.f("msg.load.bias", frames.count(.bias))) }
        var s = parts.joined(separator: ", ")
        if frames.totalLightExposure > 0 {
            let total = frames.totalLightExposure
            let hours = Int(total / 3600), minutes = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
            s += " · " + (total >= 3600 ? L.f("msg.load.hours", hours, minutes) : L.f("msg.load.minutes", Int(total / 60)))
        }
        return s
    }
}
