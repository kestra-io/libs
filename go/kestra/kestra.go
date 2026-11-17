// Package kestra sends outputs, metrics and logs from Go script tasks to Kestra.
// Each call prints one `::{...}::` line to stdout, which Kestra parses.
package kestra

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"sync"
	"time"
)

var (
	mu     sync.Mutex
	stdout io.Writer = os.Stdout
	// encoding/json escapes U+2028 and U+2029 itself, but Java also ends a line at U+0085.
	nextLine        = []byte("\u0085")
	nextLineEscaped = []byte(`\u0085`)
)

// Outputs sends task outputs, readable in later tasks as `outputs.<task>.vars.<key>`.
func Outputs(outputs map[string]any) error {
	if len(outputs) == 0 {
		return errors.New("kestra: outputs must contain at least one key, for example map[string]any{\"rows\": 42}")
	}
	return send(map[string]any{"outputs": outputs})
}

// Counter sends a counter metric. tags may be nil.
func Counter(name string, value float64, tags map[string]string) error {
	return sendMetric(name, "counter", value, tags)
}

// Gauge sends a gauge metric. tags may be nil.
func Gauge(name string, value float64, tags map[string]string) error {
	return sendMetric(name, "gauge", value, tags)
}

// Timer sends a timer metric, for example kestra.Timer("fetch", time.Since(start), nil). tags may be nil.
func Timer(name string, duration time.Duration, tags map[string]string) error {
	return sendMetric(name, "timer", duration.Seconds(), tags)
}

type metric struct {
	Name  string            `json:"name"`
	Type  string            `json:"type"`
	Value float64           `json:"value"`
	Tags  map[string]string `json:"tags"`
}

func sendMetric(name, kind string, value float64, tags map[string]string) error {
	if name == "" {
		return errors.New("kestra: metric name must not be empty")
	}
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return fmt.Errorf("kestra: metric %q value must be a finite number", name)
	}
	if tags == nil {
		tags = map[string]string{}
	}
	return send(map[string]any{"metrics": []metric{{name, kind, value, tags}}})
}

func send(message any) error {
	var buf bytes.Buffer
	buf.WriteString("::")
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(message); err != nil {
		return fmt.Errorf("kestra: %w", err)
	}
	line := bytes.ReplaceAll(bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nextLine, nextLineEscaped)
	line = append(line, "::\n"...)

	// One write per line under a lock, so lines from concurrent goroutines never interleave.
	mu.Lock()
	defer mu.Unlock()
	_, err := stdout.Write(line)
	return err
}
