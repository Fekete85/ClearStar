using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Közös alap: definíció + kényelmi függvények a pixelenkénti műveletekhez. A paraméterek
/// feliratai a nyelvi adatbázisból jönnek: step.&lt;lépés&gt;.&lt;paraméter&gt;.label / .help / .ticks,
/// a választóértékek felirata step.&lt;lépés&gt;.&lt;paraméter&gt;.&lt;érték&gt;.
/// </summary>
public abstract class StepBase : IWorkflowStep
{
    public abstract StepDefinition Definition { get; }
    public virtual bool IsImplemented => true;

    public abstract Task<StepResult> RunAsync(WorkflowContext context);

    private static string Label(string step, string key) => L.T($"step.{step}.{key}.label");
    private static string? Help(string step, string key) => L.Has($"step.{step}.{key}.help") ? L.T($"step.{step}.{key}.help") : null;

    protected static ParameterDefinition Slider(string step, string key, double @default, double min = 0, double max = 1, bool advanced = false) =>
        new(key, Label(step, key), ParameterKind.Slider, @default, min, max, L.A($"step.{step}.{key}.ticks"), Advanced: advanced, Help: Help(step, key));

    protected static ParameterDefinition Toggle(string step, string key, bool @default, bool advanced = false) =>
        new(key, Label(step, key), ParameterKind.Toggle, @default, Advanced: advanced, Help: Help(step, key));

    protected static ParameterDefinition Choice(string step, string key, string @default, string[] values, bool advanced = false) =>
        new(key, Label(step, key), ParameterKind.Choice, @default, Choices: values, Advanced: advanced, Help: Help(step, key),
            ChoiceLabels: values.Select(v => L.T($"step.{step}.{key}.{v}")).ToArray());

    protected static ParameterDefinition Folder(string step, string key, string @default = "") =>
        new(key, Label(step, key), ParameterKind.Folder, @default);

    protected static ParameterDefinition Text(string step, string key, string @default = "") =>
        new(key, Label(step, key), ParameterKind.Text, @default);

    protected static ParameterDefinition Model(string step, string key, string tag, bool advanced = false) =>
        new(key, Label(step, key), ParameterKind.Model, "", Advanced: advanced, Help: Help(step, key), Tag: tag);

    protected static ParameterDefinition Hidden(string key, object @default) =>
        new(key, "", ParameterKind.Hidden, @default);

    /// <summary>Pixelenkénti művelet csatornánként, sorokra bontva párhuzamosan.</summary>
    protected static AstroImage MapPixels(AstroImage input, Func<float, int, float> fn, CancellationToken ct)
    {
        var output = input.CreateEmptyLike();
        int n = input.PixelsPerChannel;
        for (int c = 0; c < input.Channels; c++)
        {
            int channel = c;
            int offset = c * n;
            Parallel.For(0, input.Height, new ParallelOptions { CancellationToken = ct }, y =>
            {
                int start = offset + y * input.Width;
                var src = input.Data;
                var dst = output.Data;
                for (int i = start; i < start + input.Width; i++) dst[i] = fn(src[i], channel);
            });
        }
        return output;
    }

    /// <summary>RGB pixelenkénti művelet (a három csatorna együtt).</summary>
    protected static AstroImage MapRgb(AstroImage input, Func<float, float, float, (float r, float g, float b)> fn, CancellationToken ct)
    {
        if (input.Channels != 3) return input.Clone();
        var output = input.CreateEmptyLike();
        int n = input.PixelsPerChannel;
        Parallel.For(0, input.Height, new ParallelOptions { CancellationToken = ct }, y =>
        {
            var src = input.Data;
            var dst = output.Data;
            for (int i = y * input.Width; i < (y + 1) * input.Width; i++)
            {
                var (r, g, b) = fn(src[i], src[n + i], src[2 * n + i]);
                dst[i] = r;
                dst[n + i] = g;
                dst[2 * n + i] = b;
            }
        });
        return output;
    }

    protected static float Lerp(float a, float b, float t) => a + (b - a) * t;
}

/// <summary>Még el nem készült lépés: változatlanul továbbadja a képet, hogy a folyamat végigjárható legyen.</summary>
public sealed class NotImplementedStep : StepBase
{
    public override StepDefinition Definition { get; }
    public override bool IsImplemented => false;

    public NotImplementedStep(StepId id, StepGroup group, string key)
    {
        Definition = StepDefinition.FromLanguage(id, group, key, []);
    }

    public override Task<StepResult> RunAsync(WorkflowContext context) =>
        Task.FromResult(StepResult.Unchanged(context.RequireInput(), L.T("msg.notImplemented")));
}
