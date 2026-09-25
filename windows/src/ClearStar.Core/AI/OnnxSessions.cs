using Microsoft.ML.OnnxRuntime;

namespace ClearStar.Core.AI;

/// <summary>
/// Creates ONNX Runtime sessions with GPU acceleration when possible. The DirectML execution
/// provider runs on any DirectX 12 capable GPU (NVIDIA, AMD, Intel); if it cannot be created
/// – or the user turned it off in the settings – the session silently falls back to the CPU.
/// </summary>
public static class OnnxSessions
{
    /// <summary>Settings key; "false" disables GPU acceleration.</summary>
    public const string GpuSettingKey = "ai.gpu";

    /// <summary>Which provider the most recently created session ended up with ("GPU" or "CPU").</summary>
    public static string LastProvider { get; private set; } = "CPU";

    public static bool GpuEnabled
    {
        get => !string.Equals(UserSettings.Get(GpuSettingKey), "false", StringComparison.OrdinalIgnoreCase);
        set => UserSettings.Set(GpuSettingKey, value ? null : "false");
    }

    public static InferenceSession Create(string modelPath)
    {
        if (GpuEnabled)
        {
            try
            {
                var options = new SessionOptions
                {
                    GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
                    ExecutionMode = ExecutionMode.ORT_SEQUENTIAL,
                    EnableMemoryPattern = false, // required by the DirectML provider
                };
                options.AppendExecutionProvider_DML(0);
                var session = new InferenceSession(modelPath, options);
                LastProvider = "GPU";
                return session;
            }
            catch (Exception ex) when (ex is OnnxRuntimeException or DllNotFoundException or EntryPointNotFoundException)
            {
                // No usable DirectX 12 device (or the native DirectML library is missing): use the CPU.
            }
        }
        LastProvider = "CPU";
        return new InferenceSession(modelPath);
    }
}
