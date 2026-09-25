using Microsoft.ML.OnnxRuntime;

namespace ClearStar.Cli;

/// <summary>ONNX modell be- és kimeneteinek kiírása: clearstar-cli onnx &lt;model.onnx&gt;.</summary>
public static class OnnxProbe
{
    public static void Run(string path)
    {
        using var session = new InferenceSession(path);
        Console.WriteLine("Bemenetek:");
        foreach (var (name, meta) in session.InputMetadata) Console.WriteLine($"  {name}: {meta.ElementType} [{string.Join(",", meta.Dimensions)}]");
        Console.WriteLine("Kimenetek:");
        foreach (var (name, meta) in session.OutputMetadata) Console.WriteLine($"  {name}: {meta.ElementType} [{string.Join(",", meta.Dimensions)}]");
    }
}
