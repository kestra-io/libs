using System.Collections;
using System.Numerics;
using System.Text;
using System.Text.Json;
using Xunit;

// Tests swap Console.Out, the environment and the working directory, which are process-wide.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

public enum Tier { Gold, Silver }

public sealed class Fields
{
    public int Count = 42;
}

public sealed class Throwing
{
    public int Value => throw new InvalidOperationException("getter");
}

public sealed class Unprintable
{
    public override string ToString() => throw new InvalidOperationException("boom");
}

public class KestraTests : IDisposable
{
    private readonly string startDir = Directory.GetCurrentDirectory();
    private readonly List<string> dirs = new();

    public KestraTests()
    {
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", null);
        Environment.SetEnvironmentVariable("KESTRA_EXECUTION_CONTEXT_FILE", null);
        Kestra.ResetContext();
    }

    public void Dispose()
    {
        Directory.SetCurrentDirectory(startDir);
        dirs.ForEach(dir => Directory.Delete(dir, true));
    }

    private static string Capture(Action action)
    {
        var real = Console.Out;
        var writer = new StringWriter();
        Console.SetOut(writer);
        try
        {
            action();
        }
        finally
        {
            Console.SetOut(real);
        }
        return writer.ToString();
    }

    private static T ErrorOf<T>(Action action) where T : Exception
    {
        var output = "";
        var error = Assert.Throws<T>(() => output = Capture(action));
        Assert.Equal("", output);
        return error;
    }

    private string InDir(params (string Name, string Content)[] files)
    {
        var dir = Directory.CreateTempSubdirectory("kestra-ctx-").FullName;
        dirs.Add(dir);
        foreach (var (name, content) in files)
        {
            File.WriteAllText(Path.Combine(dir, name), content, new UTF8Encoding(false));
        }
        Directory.SetCurrentDirectory(dir);
        return dir;
    }

    private static string Base64(string json) => Convert.ToBase64String(Encoding.UTF8.GetBytes(json));

    [Fact]
    public void ALineEscapesLineTerminatorsAndNonAscii()
    {
        var line = Kestra.Format(new { outputs = new { v = "a\nb\"\\ \u0001 \u0085 \u2028 \u2029 café 😀" } });
        Assert.Equal("::{\"outputs\":{\"v\":\"a\\nb\\u0022\\\\ \\u0001 \\u0085 \\u2028 \\u2029 caf\\u00E9 \\uD83D\\uDE00\"}}::", line);
    }

    [Fact]
    public void OutputsSendEverydayValues()
    {
        var output = Capture(() => Kestra.Outputs(new
        {
            rows = 42,
            ok = 3 < 1,
            ratio = 1.5m,
            big = BigInteger.Pow(2, 70),
            f32 = 0.1f,
            none = (string?)null,
            day = new DateOnly(2026, 1, 2),
            at = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc),
            took = TimeSpan.FromSeconds(90.5),
            fields = new Fields(),
            tier = Tier.Gold,
            ids = new[] { 1, 2 },
            pair = (1, "a"),
            triple = Tuple.Create(1, 2, 3),
            set = new HashSet<string> { "a" },
            nested = new Dictionary<string, object> { ["country"] = "FR", ["tiers"] = new List<string> { "gold" } },
            id = Guid.Empty,
        }));
        Assert.Equal("::{\"outputs\":{\"rows\":42,\"ok\":false,\"ratio\":1.5,\"big\":1180591620717411303424,\"f32\":0.1,\"none\":null," +
            "\"day\":\"2026-01-02\",\"at\":\"2026-01-02T03:04:05Z\",\"took\":\"PT1M30.5S\",\"fields\":{\"Count\":42},\"tier\":\"Gold\",\"ids\":[1,2],\"pair\":[1,\"a\"],\"triple\":[1,2,3],\"set\":[\"a\"]," +
            "\"nested\":{\"country\":\"FR\",\"tiers\":[\"gold\"]},\"id\":\"00000000-0000-0000-0000-000000000000\"}}::\n", output);
    }

    [Fact]
    public void AnEmptyOutputOrAssetSendsNothingAsInPython()
    {
        Assert.Equal("", Capture(() =>
        {
            Kestra.Outputs(new { });
            Kestra.Outputs(new Dictionary<string, object>());
            Kestra.Assets(new { });
        }));
    }

    [Fact]
    public void ValuesKestraCannotReadFailBeforeAnythingIsSent()
    {
        var loop = new List<object>();
        loop.Add(loop);
        var colliding = new Hashtable { [1] = "a", ["1"] = "b" };
        foreach (var (value, message) in new (object, string)[]
        {
            (double.NaN, "This value cannot be sent to Kestra as JSON: replace NaN and Infinity with null."),
            (float.PositiveInfinity, "This value cannot be sent to Kestra as JSON: replace NaN and Infinity with null."),
            (BigInteger.Pow(10, 400), "past the double range"),
            (loop, "This value cannot be sent to Kestra as JSON: it is nested too deep or contains itself."),
            (colliding, "This value cannot be sent to Kestra as JSON: two keys read as the same text, such as 1 and \"1\"."),
            (new Throwing(), "Convert it first"),
            (typeof(int), "This value cannot be sent to Kestra as JSON: it holds a value that is not an object, dictionary, list, string, number, boolean " +
                "or date, or whose property throws. Convert it first, for example with ToString()."),
        })
        {
            Assert.Contains(message, ErrorOf<ArgumentException>(() => Kestra.Outputs(new { v = value })).Message);
        }
        Assert.StartsWith("Outputs must be an object", ErrorOf<ArgumentException>(() => Kestra.Outputs(new[] { 1, 2 })).Message);
        Assert.StartsWith("Outputs must be an object", ErrorOf<ArgumentException>(() => Kestra.Outputs("rows")).Message);
    }

    [Fact]
    public void AssetsKeepEmptyListsAndEmptyMetadata()
    {
        var line = Capture(() => Kestra.Assets(new { inputs = Array.Empty<object>(), outputs = new[] { new { id = "sales.orders", type = "TABLE", metadata = new { } } } }));
        Assert.Equal("::{\"assets\":{\"inputs\":[],\"outputs\":[{\"id\":\"sales.orders\",\"type\":\"TABLE\",\"metadata\":{}}]}}::\n", line);
    }

    [Fact]
    public void AssetsNeedInputsAndOutputsAsListsAndNoOtherKeys()
    {
        Assert.Equal("Asset outputs must be a list, for example new[] { new { id = \"sales.orders\", type = \"TABLE\" } }. (Parameter 'assets')",
            ErrorOf<ArgumentException>(() => Kestra.Assets(new { outputs = new { id = "a", type = "TABLE" } })).Message);
        Assert.Equal("Assets hold only inputs and outputs, not 'foo'. (Parameter 'assets')",
            ErrorOf<ArgumentException>(() => Kestra.Assets(new { foo = 1 })).Message);
    }

    [Fact]
    public void MetricsSendNumbersAndStringTagsAndEmptyTagsAsAnObject()
    {
        var lines = Capture(() =>
        {
            Kestra.Counter("rows", 3, new { source = "shop", retried = false, shard = 2, ratio = 0.5, day = new DateOnly(2026, 1, 2) });
            Kestra.Gauge("size", 2.5, new Dictionary<int, string> { [7] = "x" });
            Kestra.Timer("fetch", 1.5);
            Kestra.Timer("fetch", TimeSpan.FromMilliseconds(1500));
        });
        Assert.Equal(
            "::{\"metrics\":[{\"name\":\"rows\",\"type\":\"counter\",\"value\":3,\"tags\":{\"source\":\"shop\",\"retried\":\"false\",\"shard\":\"2\",\"ratio\":\"0.5\",\"day\":\"2026-01-02\"}}]}::\n" +
            "::{\"metrics\":[{\"name\":\"size\",\"type\":\"gauge\",\"value\":2.5,\"tags\":{\"7\":\"x\"}}]}::\n" +
            "::{\"metrics\":[{\"name\":\"fetch\",\"type\":\"timer\",\"value\":1.5,\"tags\":{}}]}::\n" +
            "::{\"metrics\":[{\"name\":\"fetch\",\"type\":\"timer\",\"value\":1.5,\"tags\":{}}]}::\n", lines);
    }

    [Fact]
    public void MetricsRefuseValuesKestraWouldDrop()
    {
        Assert.StartsWith("Metric name must be a non-empty string.", ErrorOf<ArgumentException>(() => Kestra.Counter("", 1)).Message);
        foreach (var value in new[] { double.NaN, double.PositiveInfinity })
        {
            Assert.StartsWith("Metric 'rows' value must be a finite number.", ErrorOf<ArgumentException>(() => Kestra.Counter("rows", value)).Message);
        }
        Assert.StartsWith("Metric 'rows' tags must be an object", ErrorOf<ArgumentException>(() => Kestra.Counter("rows", 1, "prod")).Message);
        Assert.Equal("Metric 'rows' has two tags named '1'. (Parameter 'tags')",
            ErrorOf<ArgumentException>(() => Kestra.Counter("rows", 1, new Hashtable { [1] = "a", ["1"] = "b" })).Message);
        foreach (var tag in new object?[] { null, new[] { 1 }, new { a = 1 } })
        {
            Assert.StartsWith("Metric 'rows' tag 'env' must be a single value",
                ErrorOf<ArgumentException>(() => Kestra.Counter("rows", 1, new Dictionary<string, object?> { ["env"] = tag })).Message);
        }
    }

    [Fact]
    public async Task ATimedFunctionReturnsItsResultAndSendsNothingWhenItThrows()
    {
        var result = 0;
        var line = Capture(() => result = Kestra.Timer("fetch", () => { Thread.Sleep(20); return 7; }, new { env = "qa" }));
        Assert.Equal(7, result);
        var match = System.Text.RegularExpressions.Regex.Match(line, "^::\\{\"metrics\":\\[\\{\"name\":\"fetch\",\"type\":\"timer\",\"value\":([0-9.E-]+),\"tags\":\\{\"env\":\"qa\"\\}\\}\\]\\}::\n$");
        Assert.True(match.Success && double.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture) >= 0.02, line);
        Assert.Equal("boom", ErrorOf<InvalidOperationException>(() => Kestra.Timer("fetch", () => throw new InvalidOperationException("boom"))).Message);
        Assert.StartsWith("Timer 'fetch' got an async function", ErrorOf<ArgumentException>(() => Kestra.Timer("fetch", () => Task.Delay(1))).Message);
        var isRun = false;
        ErrorOf<ArgumentException>(() => Kestra.Timer("fetch", () => isRun = true, new { env = new[] { 1 } }));
        Assert.False(isRun);

        var real = Console.Out;
        var writer = new StringWriter();
        Console.SetOut(writer);
        try
        {
            Assert.Equal(3, await Kestra.TimerAsync("fetch", async () => { await Task.Delay(30); return 3; }));
        }
        finally
        {
            Console.SetOut(real);
        }
        var asyncValue = System.Text.RegularExpressions.Regex.Match(writer.ToString(), "\"value\":([0-9.E-]+)").Groups[1].Value;
        Assert.True(double.Parse(asyncValue, System.Globalization.CultureInfo.InvariantCulture) >= 0.03, writer.ToString());
    }

    [Fact]
    public void LinesFromSeveralThreadsNeverMix()
    {
        var output = Capture(() => Parallel.For(0, 200, i => Kestra.Counter("rows", i, new { thread = Environment.CurrentManagedThreadId })));
        var lines = output.TrimEnd('\n').Split('\n');
        Assert.Equal(200, lines.Length);
        Assert.All(lines, line => Assert.Matches("^::\\{\"metrics\".*\\}::$", line));
    }

    [Fact]
    public void TheLoggerSendsEachLevelFillsTemplatesAndNeverFails()
    {
        var error = new InvalidOperationException("db down");
        var rows = new SinglePass();
        var lines = Capture(() =>
        {
            Kestra.Logger.Trace("t");
            Kestra.Logger.Debug("{Count} rows, {Missing}", 3);
            Kestra.Logger.Information("{Ratio:F1} of {{all}} {Tags} {Bad}", 0.26, new[] { "a", "b" }, new Unprintable());
            Kestra.Logger.Warning("caf\u00e9 \u2028 two\nlines \ud800");
            Kestra.Logger.Error(error, "query failed");
            Kestra.Logger.Critical("down {Value}", null);
            Kestra.Logger.Error("failed {Id}", "x", error);
            var loop = new List<object>();
            loop.Add(loop);
            Kestra.Logger.Information("[{Count,4}] [{Name,-3}] {Loop}", 3, "a", loop);
            Kestra.Logger.Information("{Many} {Set}", Enumerable.Range(1, 1001).ToArray(), new HashSet<int> { 7 });
            Kestra.Logger.Information("{Rows}", rows);
        }).TrimEnd('\n').Split('\n');
        Assert.Equal(new[]
        {
            "::{\"logs\":[{\"level\":\"TRACE\",\"message\":\"t\"}]}::",
            "::{\"logs\":[{\"level\":\"DEBUG\",\"message\":\"3 rows, {Missing}\"}]}::",
            "::{\"logs\":[{\"level\":\"INFO\",\"message\":\"0.3 of {all} [a, b] [FAILED ToString()]\"}]}::",
            "::{\"logs\":[{\"level\":\"WARN\",\"message\":\"caf\\u00E9 \\u2028 two\\nlines \\uFFFD\"}]}::",
            "::{\"logs\":[{\"level\":\"ERROR\",\"message\":\"query failed\\nSystem.InvalidOperationException: db down\"}]}::",
            "::{\"logs\":[{\"level\":\"ERROR\",\"message\":\"down null\"}]}::",
            "::{\"logs\":[{\"level\":\"ERROR\",\"message\":\"failed x\\nSystem.InvalidOperationException: db down\"}]}::",
            "::{\"logs\":[{\"level\":\"INFO\",\"message\":\"[   3] [a  ] [List\\u00601]\"}]}::",
            "::{\"logs\":[{\"level\":\"INFO\",\"message\":\"[" + string.Join(", ", Enumerable.Range(1, 1000)) + ", ...] [7]\"}]}::",
            $"::{{\"logs\":[{{\"level\":\"INFO\",\"message\":\"{rows}\"}}]}}::",
        }, lines);
        Assert.Equal(new[] { 1, 2 }, rows.ToArray());
    }

    private sealed class SinglePass : IEnumerable<int>
    {
        private bool isRead;

        public IEnumerator<int> GetEnumerator()
        {
            if (isRead)
            {
                yield break;
            }
            isRead = true;
            yield return 1;
            yield return 2;
        }

        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

        public override string ToString() => "rows";
    }

    [Fact]
    public void ContextIsReadFromTheDefaultFileOnceAndEachCallReturnsANewObject()
    {
        InDir((Kestra.ContextFile, "{\"labels\":{\"team\":\"caf\\u00e9\"},\"inputs\":{\"list\":[1,null,2.5,true]},\"vars\":{\"big\":123456789012345678901234567890}}"));
        var context = Kestra.Context();
        Assert.Equal("café", (string?)context["labels"]!["team"]);
        Assert.Equal("[1,null,2.5,true]", context["inputs"]!["list"]!.ToJsonString());
        Assert.Equal("123456789012345678901234567890", context["vars"]!["big"]!.ToJsonString());
        File.Delete(Kestra.ContextFile);
        context["labels"] = null;
        Assert.Equal("café", (string?)Kestra.Context()["labels"]!["team"]);
    }

    [Fact]
    public void AFileWinsOverKestraContextAndTheEnvFileOverTheDefaultFile()
    {
        InDir((Kestra.ContextFile, "{\"id\":\"default\"}"), ("other.json", "{\"id\":\"env-file\"}"));
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", Base64("{\"id\":\"from-env\"}"));
        Assert.Equal("default", (string?)Kestra.Context()["id"]);
        Kestra.ResetContext();
        Environment.SetEnvironmentVariable("KESTRA_EXECUTION_CONTEXT_FILE", "other.json");
        Assert.Equal("env-file", (string?)Kestra.Context()["id"]);
    }

    [Fact]
    public void FallsBackToKestraContextWithoutAFileAlsoForAnEmptyPath()
    {
        InDir();
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", Base64("{\"id\":\"from-env\"}"));
        Assert.Equal(new[] { "from-env", "from-env" }, new[] { (string?)Kestra.Context("")["id"], (string?)Kestra.Context()["id"] });
    }

    [Fact]
    public void AnExplicitPathIsNeverCachedAndNeverFallsBack()
    {
        InDir((Kestra.ContextFile, "{\"id\":\"default\"}"), ("explicit.json", "{\"id\":\"explicit\"}"));
        Assert.Equal(new[] { "explicit", "default", "explicit" },
            new[] { (string?)Kestra.Context("explicit.json")["id"], (string?)Kestra.Context()["id"], (string?)Kestra.Context("explicit.json")["id"] });
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", Base64("{}"));
        Assert.Equal("Kestra execution context file 'typo.json' does not exist.", Assert.Throws<FileNotFoundException>(() => Kestra.Context("typo.json")).Message);
    }

    [Fact]
    public void ADirectoryFailsInsteadOfFallingBack()
    {
        var dir = InDir();
        Directory.CreateDirectory("ctx");
        Environment.SetEnvironmentVariable("KESTRA_EXECUTION_CONTEXT_FILE", "ctx");
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", Base64("{}"));
        Assert.Equal("Kestra execution context file 'ctx' is a directory, not a file.", Assert.Throws<IOException>(() => Kestra.Context()).Message);
    }

    [Theory]
    [InlineData("[1, 2]", "The execution context in .kestra-execution-context.json is not a JSON object.")]
    [InlineData("null", "The execution context in .kestra-execution-context.json is not a JSON object.")]
    [InlineData("{\"a\":", "The execution context in .kestra-execution-context.json is not valid JSON: ")]
    [InlineData("{\"a\":1} x", "The execution context in .kestra-execution-context.json is not valid JSON: ")]
    public void BadFileContentGetsAMessageThatNamesTheFile(string content, string message)
    {
        InDir((Kestra.ContextFile, content));
        Assert.StartsWith(message, Assert.Throws<JsonException>(() => Kestra.Context()).Message);
    }

    [Fact]
    public void DuplicateKeysAndInvalidUtf8InTheFileFailWhenRead()
    {
        InDir(("dup.json", "{\"a\":1,\"a\":2}"));
        Assert.StartsWith("The execution context in dup.json is not valid JSON: ", Assert.Throws<JsonException>(() => Kestra.Context("dup.json")).Message);
        File.WriteAllBytes("bad.json", new byte[] { (byte)'{', (byte)'"', (byte)'a', (byte)'"', (byte)':', (byte)'"', 0xff, (byte)'"', (byte)'}' });
        Assert.Equal("The execution context in bad.json is not valid JSON: it is not valid UTF-8.", Assert.Throws<JsonException>(() => Kestra.Context("bad.json")).Message);
    }

    [Fact]
    public void BadKestraContextGetsADistinctMessage()
    {
        InDir();
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", "{\"a\":1}");
        Assert.Equal("The KESTRA_CONTEXT environment variable is not valid base64.", Assert.Throws<FormatException>(() => Kestra.Context()).Message);
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", "e30");
        Assert.Equal("The KESTRA_CONTEXT environment variable is not valid base64.", Assert.Throws<FormatException>(() => Kestra.Context()).Message);
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", Base64("[]"));
        Assert.Equal("The execution context in KESTRA_CONTEXT is not a JSON object.", Assert.Throws<JsonException>(() => Kestra.Context()).Message);
    }

    [Fact]
    public void FailsClearlyOutsideKestra()
    {
        InDir();
        Assert.Contains("only available when the script runs inside a Kestra task", Assert.Throws<FileNotFoundException>(() => Kestra.Context()).Message);
    }
}
