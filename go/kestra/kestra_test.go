package kestra

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// --- Test Helpers ---

// captureStdout captures everything written to os.Stdout during the execution of f.
func captureStdout(f func()) (string, error) {
	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		return "", err // Return error if pipe creation fails
	}
	os.Stdout = w

	// Channel to signal completion of the function f
	done := make(chan struct{})
	// Buffer to store the output
	var buf bytes.Buffer
	// Goroutine to read from the pipe
	go func() {
		_, _ = io.Copy(&buf, r) // Copy everything from reader to buffer
		r.Close()               // Close reader when writer is closed
		close(done)             // Signal that reading is finished
	}()

	// Execute the function that writes to stdout
	f()

	// Restore original stdout *before* closing the writer
	// This ensures any buffered output is flushed before the pipe is closed.
	os.Stdout = oldStdout
	// Close the writer end of the pipe. This signals EOF to the reader goroutine.
	w.Close()

	// Wait for the reading goroutine to finish
	<-done

	return buf.String(), nil // Return the full buffer content
}

// assertEqual checks if two values are equal and fails the test if not.
func assertEqual(t *testing.T, expected, actual interface{}, msg string) {
	t.Helper() // Marks this function as a test helper
	if !reflect.DeepEqual(expected, actual) {
		t.Errorf("%s: Expected '%v' (%T), but got '%v' (%T)", msg, expected, expected, actual, actual)
	}
}

// assertJSON checks if the captured output string contains valid Kestra-formatted JSON
// and compares the unmarshalled data with the expected structure for semantic equality.
func assertJSON(t *testing.T, output string, expectedPayload interface{}, prefix string) {
	t.Helper()
	trimmedOutput := strings.TrimSpace(output)

	// Check for Kestra's ::{...}:: format
	if !strings.HasPrefix(trimmedOutput, "::") || !strings.HasSuffix(trimmedOutput, "::") {
		t.Errorf("%s: Output format incorrect. Expected '::{}::', got '%s'", prefix, trimmedOutput)
		return
	}

	// Extract JSON part
	jsonStr := strings.TrimPrefix(trimmedOutput, "::")
	jsonStr = strings.TrimSuffix(jsonStr, "::")

	// --- Modification Start ---
	// Unmarshal actual JSON into a generic map
	var actualMap map[string]interface{}
	err := json.Unmarshal([]byte(jsonStr), &actualMap)
	if err != nil {
		t.Errorf("%s: Failed to unmarshal actual JSON output '%s' into map: %v", prefix, jsonStr, err)
		return
	}

	// Marshal the expected payload back to JSON
	expectedJSONBytes, err := json.Marshal(expectedPayload)
	if err != nil {
		t.Errorf("%s: Failed to marshal expected payload to JSON: %v", prefix, err)
		return
	}

	// Unmarshal expected JSON into a generic map
	var expectedMap map[string]interface{}
	err = json.Unmarshal(expectedJSONBytes, &expectedMap)
	if err != nil {
		t.Errorf("%s: Failed to unmarshal expected payload JSON '%s' into map: %v", prefix, string(expectedJSONBytes), err)
		return
	}

	// Compare the two generic maps using reflect.DeepEqual
	if !reflect.DeepEqual(expectedMap, actualMap) {
		// Use MarshalIndent for readable diff output
		expectedJSONPretty, _ := json.MarshalIndent(expectedMap, "", "  ")
		actualJSONPretty, _ := json.MarshalIndent(actualMap, "", "  ")
		t.Errorf("%s: JSON content mismatch.\nExpected (as map):\n%s\nGot (as map):\n%s", prefix, string(expectedJSONPretty), string(actualJSONPretty))
	}
	// --- Modification End ---
}

// --- Test Functions ---

func TestNewCounter(t *testing.T) {
	t.Run("ValidIntCounter", func(t *testing.T) {
		tags := map[string]string{"env": "test"}
		expected := KestraMetric{Type: "counter", Name: "int_count", Value: 10, Tags: tags}
		actual := NewCounter("int_count", 10, tags)
		assertEqual(t, expected, actual, "TestNewCounter Int")
	})

	t.Run("ValidFloatCounter", func(t *testing.T) {
		tags := map[string]string{"region": "us-east"}
		expected := KestraMetric{Type: "counter", Name: "float_count", Value: 15.5, Tags: tags}
		actual := NewCounter("float_count", 15.5, tags)
		assertEqual(t, expected, actual, "TestNewCounter Float")
	})

	t.Run("CounterNoTags", func(t *testing.T) {
		expected := KestraMetric{Type: "counter", Name: "no_tags", Value: 1, Tags: nil}
		actual := NewCounter("no_tags", 1, nil)
		assertEqual(t, expected, actual, "TestNewCounter No Tags")
	})

	t.Run("CounterUnsupportedType", func(t *testing.T) {
		// Suppress log output specifically for this sub-test
		originalLogOutput := log.Writer()
		log.SetOutput(io.Discard)
		defer log.SetOutput(originalLogOutput)

		tags := map[string]string{}
		expected := KestraMetric{Type: "counter", Name: "string_val", Value: "invalid", Tags: tags}
		actual := NewCounter("string_val", "invalid", tags)
		assertEqual(t, expected, actual, "TestNewCounter Unsupported Type")
	})
}

func TestNewTimer(t *testing.T) {
	t.Run("ValidDurationTimer", func(t *testing.T) {
		tags := map[string]string{"unit": "ms"}
		duration := 500 * time.Millisecond
		expected := KestraMetric{Type: "timer", Name: "duration_timer", Value: 0.5, Tags: tags} // Value in seconds
		actual := NewTimer("duration_timer", duration, tags)
		assertEqual(t, expected, actual, "TestNewTimer Duration")
	})

	t.Run("ValidFloatTimer", func(t *testing.T) {
		tags := map[string]string{"op": "read"}
		expected := KestraMetric{Type: "timer", Name: "float_timer", Value: 1.25, Tags: tags}
		actual := NewTimer("float_timer", 1.25, tags)
		assertEqual(t, expected, actual, "TestNewTimer Float")
	})

	t.Run("ValidIntTimer", func(t *testing.T) {
		tags := map[string]string{}
		expected := KestraMetric{Type: "timer", Name: "int_timer", Value: float64(2), Tags: tags} // Value converted to float seconds
		actual := NewTimer("int_timer", 2, tags)
		assertEqual(t, expected, actual, "TestNewTimer Int")
	})

	t.Run("TimerNoTags", func(t *testing.T) {
		expected := KestraMetric{Type: "timer", Name: "no_tags_timer", Value: 0.1, Tags: nil}
		actual := NewTimer("no_tags_timer", 100*time.Millisecond, nil)
		assertEqual(t, expected, actual, "TestNewTimer No Tags")
	})

	t.Run("TimerUnsupportedType", func(t *testing.T) {
		// Suppress log output specifically for this sub-test
		originalLogOutput := log.Writer()
		log.SetOutput(io.Discard)
		defer log.SetOutput(originalLogOutput)

		tags := map[string]string{}
		expected := KestraMetric{Type: "timer", Name: "string_timer", Value: float64(0), Tags: tags}
		actual := NewTimer("string_timer", "invalid", tags)
		assertEqual(t, expected, actual, "TestNewTimer Unsupported Type")
	})
}

func TestNewGauge(t *testing.T) {
	t.Run("ValidFloatGauge", func(t *testing.T) {
		tags := map[string]string{"sensor": "temp"}
		expected := KestraMetric{Type: "gauge", Name: "float_gauge", Value: 98.6, Tags: tags}
		actual := NewGauge("float_gauge", 98.6, tags)
		assertEqual(t, expected, actual, "TestNewGauge Float")
	})

	t.Run("ValidIntGauge", func(t *testing.T) {
		tags := map[string]string{"level": "high"}
		expected := KestraMetric{Type: "gauge", Name: "int_gauge", Value: float64(100), Tags: tags} // Converted to float
		actual := NewGauge("int_gauge", 100, tags)
		assertEqual(t, expected, actual, "TestNewGauge Int")
	})

	t.Run("GaugeNoTags", func(t *testing.T) {
		expected := KestraMetric{Type: "gauge", Name: "no_tags_gauge", Value: 12.34, Tags: nil}
		actual := NewGauge("no_tags_gauge", 12.34, nil)
		assertEqual(t, expected, actual, "TestNewGauge No Tags")
	})

	t.Run("GaugeConvertibleString", func(t *testing.T) {
		// Suppress log output specifically for this sub-test
		originalLogOutput := log.Writer()
		log.SetOutput(io.Discard)
		defer log.SetOutput(originalLogOutput)

		tags := map[string]string{}
		expected := KestraMetric{Type: "gauge", Name: "string_gauge", Value: 77.7, Tags: tags}
		actual := NewGauge("string_gauge", "77.7", tags)
		assertEqual(t, expected, actual, "TestNewGauge Convertible String")
	})

	t.Run("GaugeUnconvertibleString", func(t *testing.T) {
		// Suppress log output specifically for this sub-test
		originalLogOutput := log.Writer()
		log.SetOutput(io.Discard)
		defer log.SetOutput(originalLogOutput)

		tags := map[string]string{}
		expected := KestraMetric{Type: "gauge", Name: "bad_string_gauge", Value: float64(0), Tags: tags}
		actual := NewGauge("bad_string_gauge", "invalid-float", tags)
		assertEqual(t, expected, actual, "TestNewGauge Unconvertible String")
	})

	t.Run("GaugeStructType", func(t *testing.T) {
		// Suppress log output specifically for this sub-test
		originalLogOutput := log.Writer()
		log.SetOutput(io.Discard)
		defer log.SetOutput(originalLogOutput)

		type dummyStruct struct{ val int }
		tags := map[string]string{}
		expected := KestraMetric{Type: "gauge", Name: "struct_gauge", Value: float64(0), Tags: tags}
		actual := NewGauge("struct_gauge", dummyStruct{val: 5}, tags)
		assertEqual(t, expected, actual, "TestNewGauge Struct Type")
	})
}

func TestOutputs(t *testing.T) {
	// Suppress log output for the whole test function if needed (e.g., for NilOutputs warning)
	originalLogOutput := log.Writer()
	log.SetOutput(io.Discard)              // Discard logs
	defer log.SetOutput(originalLogOutput) // Restore original log output

	t.Run("ValidOutputs", func(t *testing.T) {
		outputsMap := map[string]interface{}{
			"message": "success",
			"count":   5, // This is an int
			"valid":   true,
		}
		// Expected payload still uses the original types
		expectedPayload := outputsPayload{Outputs: outputsMap}

		output, _ := captureStdout(func() {
			Outputs(outputsMap)
		})

		// assertJSON now compares generic maps, handling the int vs float64 difference
		assertJSON(t, output, expectedPayload, "TestOutputs Valid")
	})

	t.Run("EmptyOutputs", func(t *testing.T) {
		outputsMap := map[string]interface{}{}
		expectedPayload := outputsPayload{Outputs: outputsMap}

		output, _ := captureStdout(func() {
			Outputs(outputsMap)
		})

		assertJSON(t, output, expectedPayload, "TestOutputs Empty")
	})

	t.Run("NilOutputs", func(t *testing.T) {
		// Expect a warning log (suppressed), and no output printed
		output, _ := captureStdout(func() {
			Outputs(nil)
		})
		if strings.TrimSpace(output) != "" {
			t.Errorf("TestOutputs Nil: Expected no output, got '%s'", output)
		}
	})

	t.Run("OutputsWithNestedData", func(t *testing.T) {
		outputsMap := map[string]interface{}{
			"config": map[string]interface{}{
				"host": "localhost",
				"port": 8080, // This is an int
			},
			"items": []string{"a", "b", "c"},
		}
		expectedPayload := outputsPayload{Outputs: outputsMap}

		output, _ := captureStdout(func() {
			Outputs(outputsMap)
		})

		assertJSON(t, output, expectedPayload, "TestOutputs Nested")
	})
}

func TestMetrics(t *testing.T) {
	// Suppress log output for the whole test function if needed (e.g., for NilMetricsList warning)
	originalLogOutput := log.Writer()
	log.SetOutput(io.Discard)
	defer log.SetOutput(originalLogOutput)

	t.Run("ValidMetrics", func(t *testing.T) {
		metricsList := []KestraMetric{
			NewCounter("c1", 10, nil), // int
			NewTimer("t1", 0.5, nil),  // float64
			NewGauge("g1", 99.9, nil), // float64
		}
		expectedPayload := metricsPayload{Metrics: metricsList}

		output, _ := captureStdout(func() {
			Metrics(metricsList)
		})

		// assertJSON compares generic maps
		assertJSON(t, output, expectedPayload, "TestMetrics Valid")
	})

	t.Run("EmptyMetricsList", func(t *testing.T) {
		metricsList := []KestraMetric{}
		// Expect no output because the list is empty *after* filtering (if any)
		output, _ := captureStdout(func() {
			Metrics(metricsList)
		})
		if strings.TrimSpace(output) != "" {
			t.Errorf("TestMetrics Empty List: Expected no output, got '%s'", output)
		}
	})

	t.Run("NilMetricsList", func(t *testing.T) {
		// Expect a warning log (suppressed), and no output printed
		output, _ := captureStdout(func() {
			Metrics(nil)
		})
		if strings.TrimSpace(output) != "" {
			t.Errorf("TestMetrics Nil List: Expected no output, got '%s'", output)
		}
	})

	t.Run("MetricsWithTags", func(t *testing.T) {
		metricsList := []KestraMetric{
			NewCounter("c_tags", 5, map[string]string{"env": "prod", "app": "api"}), // int
			NewGauge("g_tags", 123, map[string]string{"region": "eu-west-1"}),       // int -> float64 in struct
		}
		// Adjust expected value for gauge if necessary
		expectedMetrics := []KestraMetric{
			{Type: "counter", Name: "c_tags", Value: 5, Tags: map[string]string{"env": "prod", "app": "api"}},
			{Type: "gauge", Name: "g_tags", Value: float64(123), Tags: map[string]string{"region": "eu-west-1"}},
		}
		expectedPayload := metricsPayload{Metrics: expectedMetrics}

		output, _ := captureStdout(func() {
			Metrics(metricsList)
		})

		assertJSON(t, output, expectedPayload, "TestMetrics With Tags")
	})

	t.Run("MetricsWithNilValueSkipped", func(t *testing.T) {
		// Create a metric that might end up with a nil value (though our helpers avoid this)
		// For testing the filtering logic in Metrics function itself:
		metricsList := []KestraMetric{
			{Type: "counter", Name: "valid_counter", Value: 1}, // int
			{Type: "gauge", Name: "nil_gauge", Value: nil},     // Explicitly nil value
			{Type: "timer", Name: "valid_timer", Value: 1.5},   // float64
		}
		// Only valid metrics should be included in the output
		expectedMetrics := []KestraMetric{
			{Type: "counter", Name: "valid_counter", Value: 1},
			{Type: "timer", Name: "valid_timer", Value: 1.5},
		}
		expectedPayload := metricsPayload{Metrics: expectedMetrics}

		output, _ := captureStdout(func() {
			Metrics(metricsList)
		})

		// Need to check if the nil metric was actually excluded
		if len(expectedMetrics) > 0 {
			assertJSON(t, output, expectedPayload, "TestMetrics Nil Value Skipped")
		} else {
			// If all metrics were nil, expect no output
			if strings.TrimSpace(output) != "" {
				t.Errorf("TestMetrics Nil Value Skipped: Expected no output when all metrics are nil, got '%s'", output)
			}
		}
	})
}

func TestKestraLogger(t *testing.T) {
	logger := &KestraLogger{}

	testCases := []struct {
		name         string
		level        string
		logFunc      func(string)
		testMessage  string
		expectPrefix string
		expectSuffix string
	}{
		{
			name:         "Trace Level",
			level:        "TRACE",
			logFunc:      logger.Trace,
			testMessage:  "This is a trace message",
			expectPrefix: `::{"logs":[{"level":"TRACE","message":"`,
			expectSuffix: "\"}]}::\n",
		},
		{
			name:         "Debug Level",
			level:        "DEBUG",
			logFunc:      logger.Debug,
			testMessage:  "This is a debug message",
			expectPrefix: `::{"logs":[{"level":"DEBUG","message":"`,
			expectSuffix: "\"}]}::\n",
		},
		{
			name:         "Info Level",
			level:        "INFO",
			logFunc:      logger.Info,
			testMessage:  "This is an info message",
			expectPrefix: `::{"logs":[{"level":"INFO","message":"`,
			expectSuffix: "\"}]}::\n",
		},
		{
			name:         "Warn Level",
			level:        "WARN",
			logFunc:      logger.Warn,
			testMessage:  "This is a warning message",
			expectPrefix: `::{"logs":[{"level":"WARN","message":"`,
			expectSuffix: "\"}]}::\n",
		},
		{
			name:         "Error Level",
			level:        "ERROR",
			logFunc:      logger.Error,
			testMessage:  "This is an error message",
			expectPrefix: `::{"logs":[{"level":"ERROR","message":"`,
			expectSuffix: "\"}]}::\n",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Capture stdout for this specific log call
			output, err := captureStdout(func() {
				tc.logFunc(tc.testMessage)
			})
			if err != nil {
				t.Fatalf("Failed to capture stdout: %v", err)
			}

			t.Logf("Captured output (quoted): %q", output)

			// 1. Check the overall structure (prefix and suffix)
			if !strings.HasPrefix(output, tc.expectPrefix) {
				t.Errorf("Expected output to start with '%s', but got '%s'", tc.expectPrefix, output)
			}
			if !strings.HasSuffix(output, tc.expectSuffix) {
				// Use %q for BOTH expected and actual suffix in the error message
				// Also report lengths
				t.Errorf("Suffix check failed:\n"+
					"  Expected Suffix (%d bytes): %q\n"+
					"  Actual Output   (%d bytes): %q",
					len(tc.expectSuffix), tc.expectSuffix,
					len(output), output) // Log the full actual output with %q
			}

			// 2. Extract and Parse the JSON part
			if len(output) < len(tc.expectPrefix)+len(tc.expectSuffix) {
				t.Fatalf("Output is too short to contain valid JSON: '%s'", output)
			}
			// Extract the JSON payload (handling potential edge cases if prefix/suffix overlap)
			jsonPart := strings.TrimPrefix(output, "::")
			jsonPart = strings.TrimSuffix(jsonPart, "::\n")

			var logOutput LogOutput
			err = json.Unmarshal([]byte(jsonPart), &logOutput)
			if err != nil {
				t.Fatalf("Failed to unmarshal JSON output '%s': %v", jsonPart, err)
			}

			// 3. Verify JSON Content
			if len(logOutput.Logs) != 1 {
				t.Fatalf("Expected 1 log entry in JSON, got %d", len(logOutput.Logs))
			}

			logEntry := logOutput.Logs[0]

			// Check Level
			if logEntry.Level != tc.level {
				t.Errorf("Expected log level '%s', got '%s'", tc.level, logEntry.Level)
			}

			// Check Message Content (Timestamp + Separator + Original Message)
			expectedMessageSuffix := " - " + tc.testMessage
			if !strings.HasSuffix(logEntry.Message, expectedMessageSuffix) {
				t.Errorf("Expected log message to end with '%s', got '%s'", expectedMessageSuffix, logEntry.Message)
			}

			// Check Timestamp part (basic validation)
			timestampPart := strings.TrimSuffix(logEntry.Message, expectedMessageSuffix)
			_, err = time.Parse(time.RFC3339Nano, timestampPart)
			if err != nil {
				t.Errorf("Expected message prefix to be a valid RFC3339Nano timestamp, but parsing failed for '%s': %v", timestampPart, err)
			}
		})
	}
}
