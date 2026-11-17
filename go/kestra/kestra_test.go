package kestra

import (
	"bytes"
	"context"
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

func TestAssets(t *testing.T) {
	lines := capture(t, func() {
		must(t, Assets(map[string]any{
			"inputs":  []map[string]any{{"id": "raw.orders"}},
			"outputs": []map[string]any{{"id": "sales.orders", "type": "TABLE", "metadata": map[string]string{"owner": "team_a"}}},
		}))
	})

	want := `::{"assets":{"inputs":[{"id":"raw.orders"}],"outputs":[{"id":"sales.orders","metadata":{"owner":"team_a"},"type":"TABLE"}]}}::`
	if len(lines) != 1 || lines[0] != want {
		t.Fatalf("got %q, want %q", lines, want)
	}
	if err := Assets(nil); err == nil {
		t.Fatal("empty assets: want an error")
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
		log.Info("retry", "time", 3, "level", "high", "msg", "x")
	})

	want := []string{
		`::{"logs":[{"level":"TRACE","message":"trace"}]}::`,
		`::{"logs":[{"level":"DEBUG","message":"debug"}]}::`,
		`::{"logs":[{"level":"INFO","message":"info"}]}::`,
		`::{"logs":[{"level":"WARN","message":"slow query job=import db.ms=250"}]}::`,
		`::{"logs":[{"level":"ERROR","message":"failed err=timeout"}]}::`,
		`::{"logs":[{"level":"INFO","message":"retry time=3 level=high msg=x"}]}::`,
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
				if err := Counter("rows", 1, nil); err != nil {
					t.Error(err)
				}
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

type loggingError struct{}

func (loggingError) Error() string {
	Logger().Warn("inner")
	return "boom"
}

func TestLoggingFromAnAttributeDoesNotDeadlock(t *testing.T) {
	done := make(chan []string)
	go func() {
		done <- capture(t, func() { Logger().Error("outer", "err", loggingError{}) })
	}()

	select {
	case lines := <-done:
		want := []string{
			`::{"logs":[{"level":"WARN","message":"inner"}]}::`,
			`::{"logs":[{"level":"ERROR","message":"outer err=boom"}]}::`,
		}
		if strings.Join(lines, "\n") != strings.Join(want, "\n") {
			t.Fatalf("got %q", lines)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("deadlock: a log call made while rendering an attribute never returned")
	}
}
