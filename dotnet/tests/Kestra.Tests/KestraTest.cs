using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using Xunit;

namespace Kestra.Tests;

public class KestraTest : IDisposable
{
    private readonly List<string> _captured = new();

    public KestraTest()
    {
        KestraClient.SetOutputSink(msg => _captured.Add(msg));
    }

    public void Dispose()
    {
        KestraClient.SetOutputSink(null);
    }

    private JsonDocument GetLastParsed()
    {
        Assert.NotEmpty(_captured);
        string raw = _captured[^1];
        Assert.StartsWith("::", raw);
        Assert.EndsWith("::", raw);
        string json = raw.Substring(2, raw.Length - 4);
        return JsonDocument.Parse(json);
    }

    [Fact]
    public void Outputs_EmitsCorrectJson()
    {
        KestraClient.Outputs(new
        {
            my_string = "hello",
            my_number = 42,
            my_bool = true
        });

        using var doc = GetLastParsed();
        var root = doc.RootElement;
        Assert.True(root.TryGetProperty("outputs", out var outputs));
        Assert.Equal("hello", outputs.GetProperty("my_string").GetString());
        Assert.Equal(42, outputs.GetProperty("my_number").GetInt32());
        Assert.True(outputs.GetProperty("my_bool").GetBoolean());
    }

    [Fact]
    public void Assets_EmitsCorrectJson()
    {
        KestraClient.Assets(new
        {
            inputs = new[] { new { id = "in-1", type = "FILE" } },
            outputs = new[] { new { id = "out-1", type = "TABLE" } }
        });

        using var doc = GetLastParsed();
        var root = doc.RootElement;
        Assert.True(root.TryGetProperty("assets", out var assets));
        Assert.Equal("in-1", assets.GetProperty("inputs")[0].GetProperty("id").GetString());
        Assert.Equal("TABLE", assets.GetProperty("outputs")[0].GetProperty("type").GetString());
    }

    [Fact]
    public void Counter_EmitsCounterMetric()
    {
        KestraClient.Counter("requests_total", 100);

        using var doc = GetLastParsed();
        var metric = doc.RootElement.GetProperty("metrics")[0];
        Assert.Equal("requests_total", metric.GetProperty("name").GetString());
        Assert.Equal("counter", metric.GetProperty("type").GetString());
        Assert.Equal(100, metric.GetProperty("value").GetDouble());
    }

    [Fact]
    public void Counter_WithTags_EmitsTags()
    {
        KestraClient.Counter("errors_total", 5, new { env = "prod", service = "api" });

        using var doc = GetLastParsed();
        var metric = doc.RootElement.GetProperty("metrics")[0];
        Assert.Equal("errors_total", metric.GetProperty("name").GetString());
        var tags = metric.GetProperty("tags");
        Assert.Equal("prod", tags.GetProperty("env").GetString());
        Assert.Equal("api", tags.GetProperty("service").GetString());
    }

    [Fact]
    public void Timer_Numeric_EmitsDuration()
    {
        KestraClient.Timer("query_duration", 1.45, new { db = "postgres" });

        using var doc = GetLastParsed();
        var metric = doc.RootElement.GetProperty("metrics")[0];
        Assert.Equal("query_duration", metric.GetProperty("name").GetString());
        Assert.Equal("timer", metric.GetProperty("type").GetString());
        Assert.Equal(1.45, metric.GetProperty("value").GetDouble());
    }

    [Fact]
    public void Timer_Callable_MeasuresDuration()
    {
        KestraClient.Timer("operation_time", () =>
        {
            Thread.Sleep(10);
        });

        using var doc = GetLastParsed();
        var metric = doc.RootElement.GetProperty("metrics")[0];
        Assert.Equal("operation_time", metric.GetProperty("name").GetString());
        Assert.Equal("timer", metric.GetProperty("type").GetString());
        Assert.True(metric.GetProperty("value").GetDouble() > 0.0);
    }

    [Fact]
    public void Gauge_EmitsGaugeMetric()
    {
        KestraClient.Gauge("memory_usage_mb", 256.5);

        using var doc = GetLastParsed();
        var metric = doc.RootElement.GetProperty("metrics")[0];
        Assert.Equal("memory_usage_mb", metric.GetProperty("name").GetString());
        Assert.Equal("gauge", metric.GetProperty("type").GetString());
        Assert.Equal(256.5, metric.GetProperty("value").GetDouble());
    }

    [Fact]
    public void Gauge_ZeroAndNegativeValues()
    {
        KestraClient.Gauge("temp_zero", 0);
        using (var doc = GetLastParsed())
        {
            Assert.Equal(0, doc.RootElement.GetProperty("metrics")[0].GetProperty("value").GetDouble());
        }

        KestraClient.Gauge("temp_neg", -12.4);
        using (var doc = GetLastParsed())
        {
            Assert.Equal(-12.4, doc.RootElement.GetProperty("metrics")[0].GetProperty("value").GetDouble());
        }
    }

    [Fact]
    public void Format_EscapesUnicodeLineSeparators()
    {
        string formatted = KestraClient.Format(new { msg = "line1\u2028line2\u2029line3\u0085line4" });
        Assert.Contains("\\u2028", formatted);
        Assert.Contains("\\u2029", formatted);
        Assert.Contains("\\u0085", formatted);
    }

    [Fact]
    public void Context_ReadsFromFile()
    {
        string tmpFile = Path.GetTempFileName();
        try
        {
            File.WriteAllText(tmpFile, "{\"flow\":{\"id\":\"my-flow\"}}", Encoding.UTF8);
            using var doc = KestraClient.Context(tmpFile);
            Assert.Equal("my-flow", doc.RootElement.GetProperty("flow").GetProperty("id").GetString());
        }
        finally
        {
            if (File.Exists(tmpFile)) File.Delete(tmpFile);
        }
    }

    [Fact]
    public void Context_ReadsFromEnv()
    {
        string json = "{\"execution\":{\"id\":\"exec-99\"}}";
        string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", b64);

        try
        {
            using var doc = KestraClient.Context("/non/existent/file.json");
            Assert.Equal("exec-99", doc.RootElement.GetProperty("execution").GetProperty("id").GetString());
        }
        finally
        {
            Environment.SetEnvironmentVariable("KESTRA_CONTEXT", null);
        }
    }

    [Fact]
    public void Context_ThrowsWhenMissing()
    {
        Environment.SetEnvironmentVariable("KESTRA_CONTEXT", null);
        Environment.SetEnvironmentVariable("KESTRA_EXECUTION_CONTEXT_FILE", null);

        Assert.Throws<InvalidOperationException>(() =>
        {
            KestraClient.Context("/non/existent/file_does_not_exist.json");
        });
    }
}
