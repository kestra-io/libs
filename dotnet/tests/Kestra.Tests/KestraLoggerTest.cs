using System;
using System.Collections.Generic;
using System.Text.Json;
using Xunit;

namespace Kestra.Tests;

public class KestraLoggerTest : IDisposable
{
    private readonly List<string> _captured = new();

    public KestraLoggerTest()
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

    [Theory]
    [InlineData("TRACE")]
    [InlineData("DEBUG")]
    [InlineData("INFO")]
    [InlineData("WARN")]
    [InlineData("ERROR")]
    public void Logger_EmitsLevelsCorrectly(string level)
    {
        switch (level)
        {
            case "TRACE": KestraClient.Logger.Trace("Trace message"); break;
            case "DEBUG": KestraClient.Logger.Debug("Debug message"); break;
            case "INFO": KestraClient.Logger.Info("Info message"); break;
            case "WARN": KestraClient.Logger.Warn("Warn message"); break;
            case "ERROR": KestraClient.Logger.Error("Error message"); break;
        }

        using var doc = GetLastParsed();
        var logs = doc.RootElement.GetProperty("logs");
        Assert.Equal(1, logs.GetArrayLength());
        Assert.Equal(level, logs[0].GetProperty("level").GetString());
        Assert.Contains(level.Substring(0, 1) + level.Substring(1).ToLower(), logs[0].GetProperty("message").GetString());
    }

    [Fact]
    public void Logger_MultipleMessages_EmitsAllInArray()
    {
        KestraClient.Logger.Info("Step 1", "Step 2", "Step 3");

        using var doc = GetLastParsed();
        var logs = doc.RootElement.GetProperty("logs");
        Assert.Equal(3, logs.GetArrayLength());
        Assert.Equal("Step 1", logs[0].GetProperty("message").GetString());
        Assert.Equal("Step 2", logs[1].GetProperty("message").GetString());
        Assert.Equal("Step 3", logs[2].GetProperty("message").GetString());
    }
}
