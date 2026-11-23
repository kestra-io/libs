package kestra

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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

func TestEmptyOutputsAndAssetsSendNothing(t *testing.T) {
	var buf bytes.Buffer
	old := stdout
	stdout = &buf
	t.Cleanup(func() { stdout = old })

	must(t, Outputs(nil))
	must(t, Outputs(map[string]any{}))
	must(t, Assets(nil))
	if buf.Len() != 0 {
		t.Fatalf("got %q, want nothing", buf.String())
	}
}

func TestValuesJSONCannotEncodeFailWithAPlainSentence(t *testing.T) {
	self := map[string]any{}
	self["self"] = self
	for value, want := range map[string]any{
		"replace NaN and Inf with nil": math.NaN(),
		"chan int is not a map, slice": make(chan int),
		"it contains itself":           self,
	} {
		err := Outputs(map[string]any{"x": want})
		if err == nil || !strings.Contains(err.Error(), "cannot be sent to Kestra as JSON: "+value) || strings.Contains(err.Error(), "json:") {
			t.Errorf("got %v, want an error containing %q", err, value)
		}
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
	lines = capture(t, func() { must(t, Assets(map[string]any{"inputs": []any{}})) })
	if want := `::{"assets":{"inputs":[]}}::`; lines[0] != want {
		t.Fatalf("got %q, want %q", lines, want)
	}
}

func TestAssetsMustBeListsOfInputsOrOutputs(t *testing.T) {
	for want, assets := range map[string]map[string]any{
		`assets hold only inputs and outputs, not "output"`: {"output": []any{}},
		"asset inputs must be a list":                       {"inputs": map[string]any{"id": "raw.orders"}},
		"asset outputs must be a list":                      {"outputs": nil},
	} {
		if err := Assets(assets); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("got %v, want an error containing %q", err, want)
		}
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

func TestLoggingAValueThatContainsItselfIsCapped(t *testing.T) {
	list := []any{1, nil}
	list[1] = list
	dict := map[string]any{"a": 1}
	dict["self"] = dict
	long := make([]int, 5000)

	lines := capture(t, func() {
		Logger().Info("cyclic", "list", list, "dict", dict, "long", long)
	})

	message := payload(t, lines[0])["logs"].([]any)[0].(map[string]any)["message"].(string)
	if !strings.HasPrefix(message, `cyclic list="[1 [1 [1 [1 [1 [1 [1 [1 [1 [1 [...]]]]]]]]]]]" dict="map[a:1 self:map[a:1 self:map[a:1`) {
		t.Fatalf("got %q", message)
	}
	if !strings.HasSuffix(message, ` 0 ...]"`) || len(message) > 5000 {
		t.Fatalf("long slice not capped: %d bytes", len(message))
	}
}

func TestLoggingDecodedJSONShowsEveryLevel(t *testing.T) {
	var v any
	if err := json.Unmarshal([]byte(`{"a":{"b":{"c":{"d":{"e":{"f":1}}}}}}`), &v); err != nil {
		t.Fatal(err)
	}

	lines := capture(t, func() { Logger().Info("ctx", "v", v) })

	want := `::{"logs":[{"level":"INFO","message":"ctx v=map[a:map[b:map[c:map[d:map[e:map[f:1]]]]]]"}]}::`
	if len(lines) != 1 || lines[0] != want {
		t.Fatalf("got %q, want %q", lines, want)
	}
}

func TestLoggingANamedByteSliceShowsItsText(t *testing.T) {
	lines := capture(t, func() { Logger().Info("x", "body", json.RawMessage(`{"a":1}`)) })

	want := `::{"logs":[{"level":"INFO","message":"x body=\"{\\\"a\\\":1}\""}]}::`
	if len(lines) != 1 || lines[0] != want {
		t.Fatalf("got %q, want %q", lines, want)
	}
}

type panicking struct{}

func (panicking) String() string { panic("boom") }

func (*panicking) MarshalText() ([]byte, error) { panic("boom") }

func TestLoggingAValueWhoseMethodsPanicDoesNotFail(t *testing.T) {
	lines := capture(t, func() {
		Logger().Info("x", "s", panicking{}, "m", &panicking{}, "nil", (*panicking)(nil), "list", []fmt.Stringer{panicking{}})
	})
	want := `::{"logs":[{"level":"INFO","message":"x s=\"%!v(PANIC=String method: boom)\" m=\"%!v(PANIC=boom)\" nil=\"%!v(PANIC=boom)\" list=\"[%!v(PANIC=String method: boom)]\""}]}::`
	if len(lines) != 1 || lines[0] != want {
		t.Fatalf("got %q, want %q", lines, want)
	}
}
