using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Kestra;

/// <summary>
/// Main entry point for emitting outputs, metrics, assets, logs, and accessing execution context in Kestra .NET script tasks.
/// </summary>
public static class KestraClient
{
    private static readonly KestraLogger _logger = new();
    private static Action<string>? _outputSink = null;

    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false
    };

    private static readonly Regex _unicodeSeparatorsRegex = new(@"[\u0085\u2028\u2029]", RegexOptions.Compiled);

    /// <summary>
    /// Gets the structured logger instance.
    /// </summary>
    public static KestraLogger Logger => _logger;

    /// <summary>
    /// Formats an object as a JSON payload surrounded by Kestra's "::" delimiter protocol.
    /// </summary>
    public static string Format(object data)
    {
        string json = JsonSerializer.Serialize(data, _jsonOptions);

        json = _unicodeSeparatorsRegex.Replace(json, match =>
        {
            int code = match.Value[0];
            return $"\\u{code:x4}";
        });

        return $"::{json}::";
    }

    /// <summary>
    /// Sends a formatted message to standard output or the configured sink.
    /// </summary>
    public static void Send(object data)
    {
        string formatted = Format(data);
        if (_outputSink != null)
        {
            _outputSink(formatted);
            return;
        }

        Console.WriteLine(formatted);
    }

    /// <summary>
    /// Emits key-value outputs back to Kestra.
    /// </summary>
    public static void Outputs(object outputs)
    {
        Send(new Dictionary<string, object>
        {
            ["outputs"] = outputs
        });
    }

    /// <summary>
    /// Emits asset metadata back to Kestra.
    /// </summary>
    public static void Assets(object assets)
    {
        Send(new Dictionary<string, object>
        {
            ["assets"] = assets
        });
    }

    /// <summary>
    /// Emits a metric definition to Kestra.
    /// </summary>
    public static void Metric(string name, string type, double value, object? tags = null)
    {
        Send(new Dictionary<string, object>
        {
            ["metrics"] = new[]
            {
                new Dictionary<string, object>
                {
                    ["name"] = name,
                    ["type"] = type,
                    ["value"] = value,
                    ["tags"] = tags ?? new Dictionary<string, object>()
                }
            }
        });
    }

    /// <summary>
    /// Emits a counter metric.
    /// </summary>
    public static void Counter(string name, double value, object? tags = null)
    {
        Metric(name, "counter", value, tags);
    }

    /// <summary>
    /// Emits a timer metric with a numeric duration in seconds.
    /// </summary>
    public static void Timer(string name, double durationSeconds, object? tags = null)
    {
        Metric(name, "timer", durationSeconds, tags);
    }

    /// <summary>
    /// Executes an action, measures its elapsed execution time in seconds, and emits a timer metric.
    /// </summary>
    public static void Timer(string name, Action action, object? tags = null)
    {
        if (action == null) throw new ArgumentNullException(nameof(action));

        var stopwatch = Stopwatch.StartNew();
        action();
        stopwatch.Stop();

        Metric(name, "timer", stopwatch.Elapsed.TotalSeconds, tags);
    }

    /// <summary>
    /// Emits a gauge metric.
    /// </summary>
    public static void Gauge(string name, double value, object? tags = null)
    {
        Metric(name, "gauge", value, tags);
    }

    /// <summary>
    /// Reads the execution context injected by Kestra into the working directory.
    /// </summary>
    public static JsonDocument Context(string? path = null)
    {
        string filePath = path
            ?? Environment.GetEnvironmentVariable("KESTRA_EXECUTION_CONTEXT_FILE")
            ?? ".kestra-execution-context.json";

        if (File.Exists(filePath))
        {
            string content = File.ReadAllText(filePath, Encoding.UTF8);
            return JsonDocument.Parse(content);
        }

        string? envContext = Environment.GetEnvironmentVariable("KESTRA_CONTEXT");
        if (!string.IsNullOrEmpty(envContext))
        {
            byte[] bytes = Convert.FromBase64String(envContext);
            string decoded = Encoding.UTF8.GetString(bytes);
            return JsonDocument.Parse(decoded);
        }

        throw new InvalidOperationException(
            $"No Kestra execution context found: '{filePath}' does not exist and KESTRA_CONTEXT environment variable is not set."
        );
    }

    /// <summary>
    /// Injects an output sink for unit testing.
    /// </summary>
    internal static void SetOutputSink(Action<string>? sink)
    {
        _outputSink = sink;
    }
}
