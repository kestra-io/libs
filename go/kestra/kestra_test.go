package kestra

import (
	"context"
	"bytes"
	"encoding/json"
	"log/slog"
	"math"
	"strings"
	"sync"
	"testing"
	"time"
)

func capture(t *testing.T, f func()) []string {
	t.Helper()
	var buf bytes.Buffer
	old := stdout
	stdout = &buf
	t.Cleanup(func() { stdout = old })
	f()
	return strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
}

func payload(t *testing.T, line string) map[string]any {
	t.Helper()
	if !strings.HasPrefix(line, "::{") || !strings.HasSuffix(line, "}::") {
		t.Fatalf("not a Kestra line: %q", line)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(line[2:len(line)-2]), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestOutputsAreOneLineWithNestedValues(t *testing.T) {
	lines := capture(t, func() {
		must(t, Outputs(map[string]any{"rows": 42, "model": "<glm>", "nested": map[string]any{"ok": true}, "missing": nil}))
	})

	want := `::{"outputs":{"missing":null,"model":"<glm>","nested":{"ok":true},"rows":42}}::`
	if len(lines) != 1 || lines[0] != want {
		t.Fatalf("got %q, want %q", lines, want)
	}
}

func TestLineTerminatorsAndNonASCIIStayOnOneLine(t *testing.T) {
	text := "a\nb\u2028c\u2029d\u0085e caf\u00e9"
	lines := capture(t, func() { must(t, Outputs(map[string]any{"text": text})) })

	if len(lines) != 1 || !strings.Contains(lines[0], `a\nb\u2028c\u2029d\u0085e caf`+"\u00e9") {
		t.Fatalf("got %q", lines)
	}
	if got := payload(t, lines[0])["outputs"].(map[string]any)["text"]; got != text {
		t.Fatalf("round trip got %q", got)
	}
}

func TestInvalidOutputsReturnAnError(t *testing.T) {
	if err := Outputs(nil); err == nil {
		t.Fatal("empty outputs: want an error")
	}
	if err := Outputs(map[string]any{"bad": math.NaN()}); err == nil {
		t.Fatal("NaN output: want an error")
	}
}

func TestMetrics(t *testing.T) {
	lines := capture(t, func() {
		must(t, Counter("rows", 15000, nil))
		must(t, Gauge("queue", 3, map[string]string{"env": "prod"}))
		must(t, Timer("fetch", 1500*time.Millisecond, nil))
	})

	want := []string{
		`::{"metrics":[{"name":"rows","type":"counter","value":15000,"tags":{}}]}::`,
		`::{"metrics":[{"name":"queue","type":"gauge","value":3,"tags":{"env":"prod"}}]}::`,
		`::{"metrics":[{"name":"fetch","type":"timer","value":1.5,"tags":{}}]}::`,
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got %q", lines)
	}
}

func TestInvalidMetricsReturnAnError(t *testing.T) {
	for name, err := range map[string]error{
		"empty name": Counter("", 1, nil),
		"NaN":        Gauge("queue", math.NaN(), nil),
		"infinity":   Gauge("queue", math.Inf(1), nil),
	} {
		if err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestLoggerMapsLevelsAndAppendsAttributes(t *testing.T) {
	lines := capture(t, func() {
		log := Logger()
		log.Log(context.Background(), slog.LevelDebug-4, "trace")
		log.Debug("debug")
		log.Info("info")
		log.With("job", "import").WithGroup("db").Warn("slow query", "ms", 250)
		log.Error("failed", "err", "timeout")
	})

	want := []string{
		`::{"logs":[{"level":"TRACE","message":"trace"}]}::`,
		`::{"logs":[{"level":"DEBUG","message":"debug"}]}::`,
		`::{"logs":[{"level":"INFO","message":"info"}]}::`,
		`::{"logs":[{"level":"WARN","message":"slow query job=import db.ms=250"}]}::`,
		`::{"logs":[{"level":"ERROR","message":"failed err=timeout"}]}::`,
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got %q", lines)
	}
}

func TestConcurrentCallsWriteWholeLines(t *testing.T) {
	lines := capture(t, func() {
		var wg sync.WaitGroup
		for i := 0; i < 50; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				must(t, Counter("rows", 1, nil))
				Logger().Info("done", "worker", 1)
			}()
		}
		wg.Wait()
	})

	if len(lines) != 100 {
		t.Fatalf("got %d lines, want 100", len(lines))
	}
	for _, line := range lines {
		payload(t, line)
	}
}
