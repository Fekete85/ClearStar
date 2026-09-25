using System.Globalization;

namespace ClearStar.Core.Pipeline;

/// <summary>Egy lépés aktuális beállításai kulcs–érték formában, típusos olvasókkal.</summary>
public sealed class StepParameters
{
    private readonly Dictionary<string, object> _values = new(StringComparer.OrdinalIgnoreCase);

    public StepParameters() { }

    public StepParameters(IEnumerable<ParameterDefinition> definitions)
    {
        foreach (var d in definitions) _values[d.Key] = d.Default;
    }

    public object? this[string key]
    {
        get => _values.TryGetValue(key, out var v) ? v : null;
        set { if (value is null) _values.Remove(key); else _values[key] = value; }
    }

    public IReadOnlyDictionary<string, object> Values => _values;

    public double GetDouble(string key, double fallback = 0) => this[key] switch
    {
        double d => d,
        float f => f,
        int i => i,
        string s when double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) => v,
        _ => fallback,
    };

    public float GetFloat(string key, float fallback = 0) => (float)GetDouble(key, fallback);

    public bool GetBool(string key, bool fallback = false) => this[key] switch
    {
        bool b => b,
        string s when bool.TryParse(s, out var v) => v,
        _ => fallback,
    };

    public string GetString(string key, string fallback = "") => this[key]?.ToString() ?? fallback;

    public StepParameters Clone()
    {
        var p = new StepParameters();
        foreach (var (k, v) in _values) p._values[k] = v;
        return p;
    }

    public bool ValuesEqual(StepParameters other)
    {
        if (_values.Count != other._values.Count) return false;
        foreach (var (k, v) in _values)
            if (!other._values.TryGetValue(k, out var o) || !Equals(v, o)) return false;
        return true;
    }
}
