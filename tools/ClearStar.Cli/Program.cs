using ClearStar.Core.Imaging;
using ClearStar.Core.IO;
using ClearStar.Core.Pipeline;
using ClearStar.Core.Steps;

if (args.Length >= 2 && args[0] == "bench") { ClearStar.Cli.Bench.Run(args[1]); return; }
if (args.Length >= 2 && args[0] == "onnx") { ClearStar.Cli.OnnxProbe.Run(args[1]); return; }
// --lang <kód> (alapértelmezés: a settings.json nyelve, különben magyar)
int li = Array.IndexOf(args, "--lang");
bool linkedPreview = Array.IndexOf(args, "--linked") >= 0; // preview JPEGs with a channel-linked stretch (keeps colour balance visible)
ClearStar.Core.Localization.L.Load(li >= 0 && li + 1 < args.Length ? args[li + 1] : ClearStar.Core.UserSettings.Get(ClearStar.Core.UserSettings.LanguageKey) ?? ClearStar.Core.Localization.L.DefaultLanguage);
string folder = args[0], outDir = args[1];
Directory.CreateDirectory(outDir);
using var wf = StepCatalog.CreateWorkflow();
// --set <lépésszám>.<kulcs>=<érték>  pl. --set 2.gradient=false
for (int a = 2; a + 1 < args.Length; a++)
{
    if (args[a] != "--set") continue;
    var m = System.Text.RegularExpressions.Regex.Match(args[++a], @"^(\d+)\.(\w+)=(.*)$");
    if (!m.Success) { Console.WriteLine($"Hibás --set: {args[a]}"); continue; }
    var entry = wf[(StepId)int.Parse(m.Groups[1].Value)];
    object value = bool.TryParse(m.Groups[3].Value, out var b) ? b : double.TryParse(m.Groups[3].Value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : m.Groups[3].Value;
    entry.Parameters[m.Groups[2].Value] = value;
}
wf[StepId.LoadFrames].Parameters[LoadFramesStep.FolderKey] = folder;
wf[StepId.Save].Parameters[SaveStep.FolderKey] = outDir;
wf[StepId.Save].Parameters[SaveStep.FileNameKey] = "final";
var progress = new Progress<ProgressInfo>(_ => { });
foreach (var entry in wf.Steps)
{
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var r = await wf.RunAsync(entry.Id, progress);
    var img = wf.Current;
    string stats = img is null ? "" : string.Join(" | ", ImageStats.ComputeAll(img).Select(s => $"med {s.Median:0.0000} mad {s.Mad:0.0000} max {s.Max:0.000}"));
    Console.WriteLine($"{entry.Definition.Number,2}. {entry.Definition.Name,-28} {sw.ElapsedMilliseconds,6} ms  {r.Summary}  {stats}");
    if (img is not null && entry.Id is StepId.Stack or StepId.BackgroundExtraction or StepId.Deconvolution or StepId.Denoise or StepId.ColorCalibration or StepId.StarlessStretch or StepId.Saturation)
    {
        // Előnézet-kép a képernyőn látható formában (lineárisnál autostretch-csel)
        var view = img.Clone();
        if (Workflow.IsLinearPhase(entry.Id)) { var p = DisplayStretch.ComputeAll(view, linked: linkedPreview); for (int c = 0; c < view.Channels; c++) { var ch = view.Channel(c); for (int i = 0; i < ch.Length; i++) ch[i] = p[c].Apply(ch[i]); } }
        ImageFiles.Save(Path.Combine(outDir, $"step{entry.Definition.Number:D2}.jpg"), view, ExportFormat.Jpeg);
    }
}
