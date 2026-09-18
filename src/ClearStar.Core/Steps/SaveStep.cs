using ClearStar.Core.IO;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>17. lépés: mentés a felhasználás céljához illő formátumban.</summary>
public sealed class SaveStep : StepBase
{
    public const string PurposeKey = "purpose";
    public const string FolderKey = "folder";
    public const string FileNameKey = "filename";
    private const string S = "save";

    // Nyelvfüggetlen választóértékek (a feliratuk a nyelvi adatbázisból: step.save.purpose.<érték>).
    public const string PurposeShare = "share";
    public const string PurposePrint = "print";
    public const string PurposeEdit = "edit";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Save, StepGroup.Finish, S,
        [
            Choice(S, PurposeKey, PurposeShare, [PurposeShare, PurposePrint, PurposeEdit]),
            Folder(S, FolderKey),
            Text(S, FileNameKey, L.T("step.save.defaultName")),
        ]);

    public static ExportFormat FormatFor(string purpose) => purpose switch
    {
        PurposePrint => ExportFormat.Tiff16,
        PurposeEdit => ExportFormat.Fits,
        _ => ExportFormat.Jpeg,
    };

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        var p = context.Parameters;
        var format = FormatFor(p.GetString(PurposeKey, PurposeShare));
        string folder = p.GetString(FolderKey).Trim();
        if (folder.Length == 0) folder = context.Frames?.Folder ?? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        string defaultName = L.T("step.save.defaultName");
        string name = p.GetString(FileNameKey, defaultName).Trim();
        if (name.Length == 0) name = defaultName;
        foreach (var ch in Path.GetInvalidFileNameChars()) name = name.Replace(ch, '_');

        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, name + ImageFiles.ExtensionFor(format));
        context.Report(0.2, L.T("msg.save.saving"));
        ImageFiles.Save(path, input, format);
        long bytes = new FileInfo(path).Length;
        return new StepResult(null, L.F("msg.save.summary", Path.GetFileName(path), bytes / 1024.0 / 1024.0));
    }, context.CancellationToken);
}
