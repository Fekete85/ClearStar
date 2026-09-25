using ClearStar.Core.IO;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>1. lépés: mappa (vagy egyetlen kép) beolvasása és a képek típus szerinti szétválogatása.</summary>
public sealed class LoadFramesStep : StepBase
{
    public const string FolderKey = "folder";
    private const string S = "load";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.LoadFrames, StepGroup.Preparation, S,
        [Folder(S, FolderKey)]);

    public override Task<StepResult> RunAsync(WorkflowContext context)
    {
        string path = context.Parameters.GetString(FolderKey).Trim();
        if (path.Length == 0) throw new InvalidOperationException(L.T("msg.load.chooseFolder"));

        FrameSet frames;
        if (File.Exists(path))
        {
            if (!ImageFiles.IsSupported(path)) throw new NotSupportedException(L.T("msg.load.unsupported"));
            frames = new FrameSet(Path.GetDirectoryName(path) ?? path, [FrameSet.Inspect(path) with { Type = FrameType.Light }]);
        }
        else if (Directory.Exists(path))
        {
            context.Report(0, L.T("msg.load.searching"));
            frames = FrameSet.Scan(path, new Progress<double>(p => context.Report(p, L.T("msg.load.inspecting"))), context.CancellationToken);
            if (frames.Frames.Count == 0) throw new InvalidOperationException(L.T("msg.load.noImages"));
            if (!frames.Lights.Any()) throw new InvalidOperationException(L.T("msg.load.noLights"));
        }
        else throw new FileNotFoundException(L.T("msg.load.notFound"), path);

        return Task.FromResult(new StepResult(null, Describe(frames), frames));
    }

    public static string Describe(FrameSet frames)
    {
        var parts = new List<string> { L.F("msg.load.lights", frames.Count(FrameType.Light)) };
        if (frames.Count(FrameType.Dark) > 0) parts.Add(L.F("msg.load.darks", frames.Count(FrameType.Dark)));
        if (frames.Count(FrameType.Flat) > 0) parts.Add(L.F("msg.load.flats", frames.Count(FrameType.Flat)));
        if (frames.Count(FrameType.Bias) > 0) parts.Add(L.F("msg.load.bias", frames.Count(FrameType.Bias)));
        string s = string.Join(", ", parts);
        if (frames.TotalLightExposure > 0)
        {
            var t = TimeSpan.FromSeconds(frames.TotalLightExposure);
            s += " · " + (t.TotalHours >= 1 ? L.F("msg.load.hours", (int)t.TotalHours, t.Minutes) : L.F("msg.load.minutes", (int)t.TotalMinutes));
        }
        return s;
    }
}
