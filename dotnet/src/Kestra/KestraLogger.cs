using System;
using System.Collections.Generic;

namespace Kestra;

/// <summary>
/// Structured logger that outputs logs formatted with Kestra's delimiter protocol:
/// ::{"logs":[{"level":"INFO","message":"..."}]}::
/// </summary>
public class KestraLogger
{
    public void Trace(params string[] messages) => Log("TRACE", messages);

    public void Debug(params string[] messages) => Log("DEBUG", messages);

    public void Info(params string[] messages) => Log("INFO", messages);

    public void Warn(params string[] messages) => Log("WARN", messages);

    public void Warning(params string[] messages) => Log("WARN", messages);

    public void Error(params string[] messages) => Log("ERROR", messages);

    public void Log(string level, params string[] messages)
    {
        if (messages == null || messages.Length == 0)
        {
            return;
        }

        var records = new List<Dictionary<string, string>>();
        foreach (var msg in messages)
        {
            records.Add(new Dictionary<string, string>
            {
                ["level"] = level.ToUpperInvariant(),
                ["message"] = msg
            });
        }

        KestraClient.Send(new Dictionary<string, object>
        {
            ["logs"] = records
        });
    }
}
