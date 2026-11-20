using System.Collections;
using System.Globalization;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

/// <summary>
/// Sends outputs, metrics, logs and assets from C# and F# script tasks to Kestra, and reads the execution context.
/// Each send call prints one <c>::{...}::</c> line to stdout, which Kestra parses. All members are thread-safe.
/// </summary>
/// <remarks>In the global namespace, so a script needs no <c>using</c> after <c>#r "Kestra.dll"</c>.</remarks>
#pragma warning disable CA1050
public static class Kestra
#pragma warning restore CA1050
{
    /// <summary>The file the task writes when it sets <c>executionContext: true</c>.</summary>
    public const string ContextFile = ".kestra-execution-context.json";

    private const int MaxDepth = 512;

    // The default encoder escapes all non-ASCII, which covers U+0085, U+2028 and U+2029 (line terminators in Java)
    // and keeps the text intact whatever the console code page.
    private static readonly JsonSerializerOptions Options = new()
    {
        MaxDepth = MaxDepth,
        // Fields too, or a class or struct with public fields would be sent as {}.
        IncludeFields = true,
        // Without compiler-generated fields, such as the name@ backing fields F# 8 makes public in anonymous records.
        TypeInfoResolver = new DefaultJsonTypeInfoResolver
        {
            Modifiers =
            {
                info =>
                {
                    for (var i = info.Properties.Count - 1; i >= 0; i--)
                    {
                        if (info.Properties[i].AttributeProvider is System.Reflection.FieldInfo field
                            && field.IsDefined(typeof(CompilerGeneratedAttribute), false))
                        {
                            info.Properties.RemoveAt(i);
                        }
                    }
                },
            },
        },
        Converters =
        {
            new JsonStringEnumConverter(), new BigIntegerConverter(), new TupleConverterFactory(),
            new FiniteDoubleConverter(), new FiniteSingleConverter(), new DurationConverter(),
        },
    };

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static string? contextJson;

    /// <summary>The logger that sends lines to Kestra at TRACE, DEBUG, INFO, WARN and ERROR.</summary>
    public static KestraLogger Logger { get; } = new();

    /// <summary>Returns the <c>::{...}::</c> line for an object or dictionary, without sending it.</summary>
    /// <exception cref="ArgumentException">The value cannot be sent as a JSON object.</exception>
    public static string Format(object map) => "::" + ToObject(map, "Kestra lines hold an object or a dictionary, for example new { outputs = new { rows = 42 } }.").ToJsonString(Options) + "::";

    /// <summary>
    /// Sends task outputs, read in later tasks as <c>outputs.&lt;task&gt;.vars</c>. Takes an anonymous object, a record or a
    /// dictionary. An empty one sends nothing, as in Python, so outputs built in a loop over no rows do not fail the task.
    /// </summary>
    /// <exception cref="ArgumentException">The outputs are not an object, or hold a value Kestra cannot read.</exception>
    public static void Outputs(object outputs)
    {
        var map = ToObject(outputs, "Outputs must be an object or a dictionary, for example Kestra.Outputs(new { rows = 42 }).");
        if (map.Count > 0)
        {
            Send(new JsonObject { ["outputs"] = map });
        }
    }

    /// <summary>Declares the input and output assets of the task, as lists in <c>inputs</c> and <c>outputs</c>. An empty one sends nothing.</summary>
    /// <exception cref="ArgumentException">Another key is used, or <c>inputs</c> or <c>outputs</c> is not a list.</exception>
    public static void Assets(object assets)
    {
        var map = ToObject(assets, "Assets must be an object or a dictionary, for example Kestra.Assets(new { outputs = new[] { new { id = \"sales.orders\", type = \"TABLE\" } } }).");
        foreach (var (key, value) in map)
        {
            if (key != "inputs" && key != "outputs")
            {
                throw new ArgumentException($"Assets hold only inputs and outputs, not '{key}'.", nameof(assets));
            }
            if (value is not JsonArray)
            {
                throw new ArgumentException($"Asset {key} must be a list, for example new[] {{ new {{ id = \"sales.orders\", type = \"TABLE\" }} }}.", nameof(assets));
            }
        }
        if (map.Count > 0)
        {
            Send(new JsonObject { ["assets"] = map });
        }
    }

    /// <summary>Sends a counter metric. <paramref name="tags"/> is an object or dictionary of single values, sent as strings.</summary>
    /// <exception cref="ArgumentException">The name is empty, the value is not finite, or a tag is not a single value.</exception>
    public static void Counter(string name, double value, object? tags = null) => SendMetric(name, "counter", value, tags);

    /// <summary>Sends a gauge metric. <paramref name="tags"/> is an object or dictionary of single values, sent as strings.</summary>
    /// <exception cref="ArgumentException">The name is empty, the value is not finite, or a tag is not a single value.</exception>
    public static void Gauge(string name, double value, object? tags = null) => SendMetric(name, "gauge", value, tags);

    /// <summary>Sends a timer metric, in seconds.</summary>
    public static void Timer(string name, double seconds, object? tags = null) => SendMetric(name, "timer", seconds, tags);

    /// <summary>Sends a timer metric for a duration, for example <c>stopwatch.Elapsed</c>.</summary>
    public static void Timer(string name, TimeSpan duration, object? tags = null) => SendMetric(name, "timer", duration.TotalSeconds, tags);

    /// <summary>Times the function and returns its result. No metric is sent if it throws. Use <see cref="TimerAsync{T}"/> for async code.</summary>
    /// <exception cref="ArgumentException">The function returns a task, which this overload would not wait for.</exception>
    public static T Timer<T>(string name, Func<T> function, object? tags = null)
    {
        // Timing an async lambda here would measure only the start of the task.
        if (typeof(Task).IsAssignableFrom(typeof(T)) || typeof(T).Name.StartsWith("ValueTask", StringComparison.Ordinal)
            || (typeof(T).FullName?.StartsWith("Microsoft.FSharp.Control.FSharpAsync", StringComparison.Ordinal) ?? false))
        {
            throw new ArgumentException($"Timer '{name}' got an async function. Use await Kestra.TimerAsync(...) so the time covers the whole task, " +
                "with Async.StartAsTask in F#.", nameof(function));
        }
        // Checked first, so a bad name or tag does not fail after the function has done its work.
        MetricTags(name, tags);
        var start = Stopwatch();
        var result = function();
        SendMetric(name, "timer", Elapsed(start), tags);
        return result;
    }

    /// <summary>Times the action. No metric is sent if it throws.</summary>
    public static void Timer(string name, Action action, object? tags = null)
    {
        MetricTags(name, tags);
        var start = Stopwatch();
        action();
        SendMetric(name, "timer", Elapsed(start), tags);
    }

    /// <summary>Times the async function until its task completes, and returns its result. No metric is sent if it throws.</summary>
    public static async Task<T> TimerAsync<T>(string name, Func<Task<T>> function, object? tags = null)
    {
        MetricTags(name, tags);
        var start = Stopwatch();
        var result = await function().ConfigureAwait(false);
        SendMetric(name, "timer", Elapsed(start), tags);
        return result;
    }

    /// <summary>Times the async function until its task completes. No metric is sent if it throws.</summary>
    public static async Task TimerAsync(string name, Func<Task> function, object? tags = null)
    {
        MetricTags(name, tags);
        var start = Stopwatch();
        await function().ConfigureAwait(false);
        SendMetric(name, "timer", Elapsed(start), tags);
    }

    /// <summary>
    /// The execution context, read from <paramref name="path"/>, <c>KESTRA_EXECUTION_CONTEXT_FILE</c> or <see cref="ContextFile"/>.
    /// Without a path, or with an empty one, falls back to the base64 <c>KESTRA_CONTEXT</c> variable. The default context is
    /// read once, and each call returns a new object the caller may change.
    /// </summary>
    /// <exception cref="FileNotFoundException">No context is found, or <paramref name="path"/> does not exist.</exception>
    /// <exception cref="IOException">The context file is a directory.</exception>
    /// <exception cref="UnauthorizedAccessException">The context file cannot be read.</exception>
    /// <exception cref="FormatException"><c>KESTRA_CONTEXT</c> is not base64.</exception>
    /// <exception cref="JsonException">The context is not valid JSON, or not a JSON object.</exception>
    public static JsonObject Context(string? path = null)
    {
        var isExplicit = !string.IsNullOrEmpty(path);
        var json = isExplicit ? null : Volatile.Read(ref contextJson);
        var source = "";
        if (json is null)
        {
            var file = isExplicit ? path! : NonEmpty(Environment.GetEnvironmentVariable("KESTRA_EXECUTION_CONTEXT_FILE")) ?? ContextFile;
            source = file;
            if (Directory.Exists(file))
            {
                throw new IOException($"Kestra execution context file '{file}' is a directory, not a file.");
            }
            try
            {
                json = File.ReadAllText(file, StrictUtf8);
            }
            catch (DecoderFallbackException e)
            {
                throw new JsonException($"The execution context in {file} is not valid JSON: it is not valid UTF-8.", e);
            }
            // Only a missing file falls back. An unreadable file is a misconfiguration to report.
            catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
            {
                if (isExplicit)
                {
                    throw new FileNotFoundException($"Kestra execution context file '{file}' does not exist.", file, e);
                }
                var encoded = string.Concat((Environment.GetEnvironmentVariable("KESTRA_CONTEXT") ?? "").Where(c => !char.IsWhiteSpace(c)));
                if (encoded.Length == 0)
                {
                    throw new FileNotFoundException($"No Kestra execution context found: '{file}' does not exist and the KESTRA_CONTEXT environment variable " +
                        "is not set. The execution context is only available when the script runs inside a Kestra task.", file, e);
                }
                byte[] bytes;
                try
                {
                    bytes = Convert.FromBase64String(encoded);
                }
                catch (FormatException formatException)
                {
                    throw new FormatException("The KESTRA_CONTEXT environment variable is not valid base64.", formatException);
                }
                source = "KESTRA_CONTEXT";
                try
                {
                    json = StrictUtf8.GetString(bytes);
                }
                catch (DecoderFallbackException decoderException)
                {
                    throw new JsonException($"The execution context in {source} is not valid JSON: it is not valid UTF-8.", decoderException);
                }
            }
        }
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json, null, new JsonDocumentOptions { MaxDepth = MaxDepth });
            // JsonObject finds duplicate keys only when read, so read them all now instead of failing later on a key.
            Validate(node);
        }
        catch (Exception e) when (e is JsonException or ArgumentException)
        {
            throw new JsonException($"The execution context in {source} is not valid JSON: {e.Message}", e);
        }
        if (node is not JsonObject context)
        {
            throw new JsonException($"The execution context in {source} is not a JSON object.");
        }
        if (!isExplicit)
        {
            Volatile.Write(ref contextJson, json);
        }
        return context;
    }

    internal static void ResetContext() => Volatile.Write(ref contextJson, null);

    private static string? NonEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;

    private static long Stopwatch() => System.Diagnostics.Stopwatch.GetTimestamp();

    private static double Elapsed(long start) => (double)(System.Diagnostics.Stopwatch.GetTimestamp() - start) / System.Diagnostics.Stopwatch.Frequency;

    private static JsonObject ToObject(object? value, string message)
    {
        var node = ToNode(value);
        return node as JsonObject ?? throw new ArgumentException(message);
    }

    private static JsonNode? ToNode(object? value)
    {
        var node = JsonSerializer.SerializeToNode(ToElement(value));
        try
        {
            // A Hashtable with the keys 1 and "1" serializes two equal JSON keys. JsonObject finds them only when read,
            // so read them all now and fail instead of sending one value twice.
            Validate(node);
        }
        catch (ArgumentException e)
        {
            throw new ArgumentException("This value cannot be sent to Kestra as JSON: two keys read as the same text, such as 1 and \"1\".", e);
        }
        return node;
    }

    private static JsonElement ToElement(object? value)
    {
        try
        {
            return JsonSerializer.SerializeToElement(value, Options);
        }
        // Any error, including one thrown by a property getter, means the value cannot be sent. The cause stays as the inner exception.
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            var reason = e switch
            {
                NotFiniteException => e.Message,
                JsonException when e.Message.Contains("cycle", StringComparison.Ordinal) => "it is nested too deep or contains itself.",
                _ => "it holds a value that is not an object, dictionary, list, string, number, boolean or date, or whose property throws. " +
                    "Convert it first, for example with ToString().",
            };
            throw new ArgumentException($"This value cannot be sent to Kestra as JSON: {reason}", e);
        }
    }

    private static void Validate(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject map:
                foreach (var (_, item) in map)
                {
                    Validate(item);
                }
                break;
            case JsonArray list:
                foreach (var item in list)
                {
                    Validate(item);
                }
                break;
        }
    }

    private static void SendMetric(string name, string type, double value, object? tags)
    {
        var stringTags = MetricTags(name, tags);
        if (!double.IsFinite(value))
        {
            throw new ArgumentException($"Metric '{name}' value must be a finite number.", nameof(value));
        }
        Send(new JsonObject
        {
            ["metrics"] = new JsonArray(new JsonObject { ["name"] = name, ["type"] = type, ["value"] = value, ["tags"] = stringTags }),
        });
    }

    private static JsonObject MetricTags(string name, object? tags)
    {
        if (string.IsNullOrEmpty(name))
        {
            throw new ArgumentException("Metric name must be a non-empty string.", nameof(name));
        }
        var stringTags = new JsonObject();
        if (tags is null)
        {
            return stringTags;
        }
        // An element, not a JsonObject, so the keys 1 and "1" of a Hashtable both show up and can be named.
        var map = ToElement(tags);
        if (map.ValueKind != JsonValueKind.Object)
        {
            throw new ArgumentException($"Metric '{name}' tags must be an object or a dictionary, for example new {{ env = \"prod\" }}.", nameof(tags));
        }
        foreach (var tag in map.EnumerateObject())
        {
            if (stringTags.ContainsKey(tag.Name))
            {
                throw new ArgumentException($"Metric '{name}' has two tags named '{tag.Name}'.", nameof(tags));
            }
            // Kestra reads tags as a map of strings.
            stringTags[tag.Name] = tag.Value.ValueKind switch
            {
                JsonValueKind.String => tag.Value.GetString(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                JsonValueKind.Number => tag.Value.GetRawText(),
                _ => throw new ArgumentException($"Metric '{name}' tag '{tag.Name}' must be a single value, for example new {{ env = \"prod\" }}.", nameof(tags)),
            };
        }
        return stringTags;
    }

    private static void Send(JsonObject map) => SendLine("::" + map.ToJsonString(Options) + "::");

    internal static void SendLine(string line)
    {
        // One write per line, flushed, so Kestra gets each line when it is written and not at exit.
        var output = Console.Out;
        lock (output)
        {
            output.Write(line + "\n");
            output.Flush();
        }
    }

    // System.Text.Json sends a Tuple as {"Item1":...} and a ValueTuple, such as (1, "a"), as {}. Python sends tuples as lists.
    private sealed class TupleConverterFactory : JsonConverterFactory
    {
        public override bool CanConvert(Type typeToConvert) => typeof(ITuple).IsAssignableFrom(typeToConvert);

        public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options) =>
            (JsonConverter)Activator.CreateInstance(typeof(TupleConverter<>).MakeGenericType(typeToConvert))!;
    }

    private sealed class TupleConverter<T> : JsonConverter<T> where T : ITuple
    {
        public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => throw new NotSupportedException();

        public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
        {
            writer.WriteStartArray();
            for (var i = 0; i < value.Length; i++)
            {
                JsonSerializer.Serialize(writer, value[i], options);
            }
            writer.WriteEndArray();
        }
    }

    private sealed class NotFiniteException(string reason = "replace NaN and Infinity with null.") : Exception(reason)
    {
    }

    // Throws a type of its own for NaN and Infinity, so the error says what to do instead of naming serializer options.
    private sealed class FiniteDoubleConverter : JsonConverter<double>
    {
        public override double Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => throw new NotSupportedException();

        public override void Write(Utf8JsonWriter writer, double value, JsonSerializerOptions options) =>
            writer.WriteNumberValue(double.IsFinite(value) ? value : throw new NotFiniteException());
    }

    private sealed class FiniteSingleConverter : JsonConverter<float>
    {
        public override float Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => throw new NotSupportedException();

        public override void Write(Utf8JsonWriter writer, float value, JsonSerializerOptions options) =>
            writer.WriteNumberValue(float.IsFinite(value) ? value : throw new NotFiniteException());
    }

    // ISO 8601, such as PT1M30.5S, which Kestra reads as a duration, instead of 00:01:30.5000000.
    private sealed class DurationConverter : JsonConverter<TimeSpan>
    {
        public override TimeSpan Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => throw new NotSupportedException();

        public override void Write(Utf8JsonWriter writer, TimeSpan value, JsonSerializerOptions options) =>
            writer.WriteStringValue(System.Xml.XmlConvert.ToString(value));
    }

    // System.Text.Json has no BigInteger support and would send its properties. Kestra reads numbers as doubles.
    private sealed class BigIntegerConverter : JsonConverter<BigInteger>
    {
        public override BigInteger Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => throw new NotSupportedException();

        public override void Write(Utf8JsonWriter writer, BigInteger value, JsonSerializerOptions options)
        {
            if (!double.IsFinite((double)value))
            {
                throw new NotFiniteException($"the number {value} is past the double range and would read as Infinity.");
            }
            writer.WriteRawValue(value.ToString(CultureInfo.InvariantCulture));
        }
    }
}

/// <summary>
/// Sends log lines to Kestra, with the method names of Microsoft.Extensions.Logging. A message template such as
/// <c>"{Count} orders had no customer"</c> is filled with the arguments in order, and <c>{{</c> and <c>}}</c> are literal braces.
/// An exception is added with its stack trace. A log call never fails on its values.
/// </summary>
public sealed class KestraLogger
{
    private const int MaxLoggedItems = 1000;

    internal KestraLogger()
    {
    }

    /// <summary>Sends a TRACE line.</summary>
    public void Trace(string? message, params object?[]? args) => Log("TRACE", null, message, args);

    /// <summary>Sends a TRACE line with an exception.</summary>
    public void Trace(Exception? exception, string? message, params object?[]? args) => Log("TRACE", exception, message, args);

    /// <summary>Sends a DEBUG line.</summary>
    public void Debug(string? message, params object?[]? args) => Log("DEBUG", null, message, args);

    /// <summary>Sends a DEBUG line with an exception.</summary>
    public void Debug(Exception? exception, string? message, params object?[]? args) => Log("DEBUG", exception, message, args);

    /// <summary>Sends an INFO line.</summary>
    public void Information(string? message, params object?[]? args) => Log("INFO", null, message, args);

    /// <summary>Sends an INFO line with an exception.</summary>
    public void Information(Exception? exception, string? message, params object?[]? args) => Log("INFO", exception, message, args);

    /// <summary>Sends a WARN line.</summary>
    public void Warning(string? message, params object?[]? args) => Log("WARN", null, message, args);

    /// <summary>Sends a WARN line with an exception.</summary>
    public void Warning(Exception? exception, string? message, params object?[]? args) => Log("WARN", exception, message, args);

    /// <summary>Sends an ERROR line.</summary>
    public void Error(string? message, params object?[]? args) => Log("ERROR", null, message, args);

    /// <summary>Sends an ERROR line with an exception.</summary>
    public void Error(Exception? exception, string? message, params object?[]? args) => Log("ERROR", exception, message, args);

    /// <summary>Sends an ERROR line, as Kestra has no level above ERROR.</summary>
    public void Critical(string? message, params object?[]? args) => Log("ERROR", null, message, args);

    /// <summary>Sends an ERROR line with an exception, as Kestra has no level above ERROR.</summary>
    public void Critical(Exception? exception, string? message, params object?[]? args) => Log("ERROR", exception, message, args);

    private static void Log(string level, Exception? exception, string? message, object?[]? args)
    {
        args ??= new object?[] { null };
        var text = Fill(message ?? "", args, out var used);
        // Error("failed", e) puts the exception in args. A trailing exception the template does not use is logged as the exception.
        if (exception is null && used < args.Length && args[^1] is Exception trailing)
        {
            exception = trailing;
        }
        if (exception is not null)
        {
            text += "\n" + Text(exception);
        }
        var line = new JsonObject { ["logs"] = new JsonArray(new JsonObject { ["level"] = level, ["message"] = text }) };
        Kestra.SendLine("::" + line.ToJsonString() + "::");
    }

    // Fills {Name}, {Name:format} and {Name,alignment} in order, as Microsoft.Extensions.Logging does.
    private static string Fill(string template, object?[] args, out int used)
    {
        var builder = new StringBuilder();
        used = 0;
        for (var i = 0; i < template.Length; i++)
        {
            var c = template[i];
            if ((c == '{' || c == '}') && i + 1 < template.Length && template[i + 1] == c)
            {
                builder.Append(c);
                i++;
                continue;
            }
            var end = c == '{' ? template.IndexOf('}', i + 1) : -1;
            if (end < 0 || used >= args.Length)
            {
                builder.Append(c);
                continue;
            }
            var hole = template.Substring(i + 1, end - i - 1);
            var colon = hole.IndexOf(':');
            var format = colon >= 0 ? hole[(colon + 1)..] : null;
            var name = colon >= 0 ? hole[..colon] : hole;
            var text = Text(args[used++], format);
            var comma = name.IndexOf(',');
            if (comma >= 0 && int.TryParse(name[(comma + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var width))
            {
                text = width < 0 ? text.PadRight(-width) : text.PadLeft(width);
            }
            builder.Append(text);
            i = end;
        }
        return builder.ToString();
    }

    private static string Text(object? value, string? format = null)
    {
        try
        {
            return value switch
            {
                null => "null",
                IFormattable formattable => formattable.ToString(format, CultureInfo.InvariantCulture),
                string or Exception => value.ToString() ?? "",
                IEnumerable items when IsCollection(items) => List(items),
                _ => value.ToString() ?? "",
            };
        }
        catch (Exception)
        {
            return "[FAILED ToString()]";
        }
    }

    // Lazy sequences are not enumerated: they can be infinite or single-pass, like a yield iterator or a DataReader.
    private static bool IsCollection(object value) =>
        value is ICollection || value.GetType().GetInterfaces().Any(type => type.IsGenericType && type.GetGenericTypeDefinition() == typeof(IReadOnlyCollection<>));

    // Items are not expanded further, so a list that contains itself cannot recurse.
    private static string List(IEnumerable items)
    {
        var texts = items.Cast<object?>().Take(MaxLoggedItems + 1).Select(item => Text(item is string or not IEnumerable ? item : item.GetType().Name)).ToList();
        if (texts.Count > MaxLoggedItems)
        {
            texts[MaxLoggedItems] = "...";
        }
        return "[" + string.Join(", ", texts) + "]";
    }
}
