// Package kestra sends outputs, metrics, logs and assets from Go script tasks to Kestra, and reads the execution context.
// Each send call prints one `::{...}::` line to stdout, which Kestra parses.
package kestra

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"reflect"
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

// Outputs sends task outputs, readable in later tasks as `outputs.<task>.vars.<key>`. Empty outputs send nothing.
func Outputs(outputs map[string]any) error {
	if len(outputs) == 0 {
		return nil
	}
	return send(map[string]any{"outputs": outputs})
}

// Assets declares the task's input and output assets, each a list,
// for example map[string]any{"outputs": []map[string]any{{"id": "sales.orders", "type": "TABLE"}}}. Empty assets send nothing.
func Assets(assets map[string]any) error {
	for key, value := range assets {
		if key != "inputs" && key != "outputs" {
			return fmt.Errorf("kestra: assets hold only inputs and outputs, not %q", key)
		}
		if kind := reflect.ValueOf(value).Kind(); kind != reflect.Slice && kind != reflect.Array {
			return fmt.Errorf(`kestra: asset %s must be a list, for example []map[string]any{{"id": "sales.orders", "type": "TABLE"}}`, key)
		}
	}
	if len(assets) == 0 {
		return nil
	}
	return send(map[string]any{"assets": assets})
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
		return encodeError(err)
	}
	line := bytes.ReplaceAll(bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nextLine, nextLineEscaped)
	line = append(line, "::\n"...)

	// One write per line under a lock, so lines from concurrent goroutines never interleave.
	mu.Lock()
	defer mu.Unlock()
	_, err := stdout.Write(line)
	return err
}

func encodeError(err error) error {
	var valueErr *json.UnsupportedValueError
	var typeErr *json.UnsupportedTypeError
	switch {
	case errors.As(err, &valueErr) && (valueErr.Str == "NaN" || valueErr.Str == "+Inf" || valueErr.Str == "-Inf"):
		return errors.New("kestra: this value cannot be sent to Kestra as JSON: replace NaN and Inf with nil")
	case errors.As(err, &valueErr):
		return errors.New("kestra: this value cannot be sent to Kestra as JSON: it contains itself")
	case errors.As(err, &typeErr):
		return fmt.Errorf("kestra: this value cannot be sent to Kestra as JSON: %s is not a map, slice, string, number, bool or time, convert it first", typeErr.Type)
	}
	return fmt.Errorf("kestra: this value cannot be sent to Kestra as JSON: %w", err)
}
