using System.Diagnostics;
using ClearStar.Core.Imaging;
using ClearStar.Core.IO;
using ClearStar.Core.Registration;
using ClearStar.Core.Steps;

namespace ClearStar.Cli;

/// <summary>Egy kép feldolgozási lépéseinek időmérése: clearstar-cli bench &lt;fájl&gt;.</summary>
public static class Bench
{
    public static void Run(string path)
    {
        var sw = Stopwatch.StartNew();
        var img = ImageFiles.Load(path);
        Console.WriteLine($"betöltés+debayer   {sw.ElapsedMilliseconds,6} ms  ({img.Width}x{img.Height}x{img.Channels})");
        sw.Restart(); var st = ImageStats.ComputeAll(img); Console.WriteLine($"statisztika (2M)   {sw.ElapsedMilliseconds,6} ms");
        sw.Restart(); ImageStats.Compute(img.Channel(0), 200_000); Console.WriteLine($"statisztika (200k) {sw.ElapsedMilliseconds,6} ms");
        sw.Restart(); BackgroundExtractionStep.Flatten(img, img, 1, 1f, 24, default); Console.WriteLine($"gradiens kivonás   {sw.ElapsedMilliseconds,6} ms");
        sw.Restart(); var stars = StarDetector.Detect(img); Console.WriteLine($"csillagkeresés     {sw.ElapsedMilliseconds,6} ms  ({stars.Count} csillag)");
        sw.Restart(); ImageWarp.Resample(img, new SimilarityTransform(1f, 0.01f, 3f, -2f), img.Width, img.Height, (_, _, _) => { }); Console.WriteLine($"átmintavételezés   {sw.ElapsedMilliseconds,6} ms");
    }
}
