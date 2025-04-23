package kestra

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"
)

// --- Kestra Communication Structs ---

type Kestra struct {
	Logger *KestraLogger
}

type KestraLogger struct{}

// KestraMetric represents a single metric entry to be sent to Kestra.
type KestraMetric struct {
	Type  string            `json:"type"` // "counter", "timer", "gauge"
	Name  string            `json:"name"`
	Value interface{}       `json:"value"` // Use float64 for Timer/Gauge, int/float64 for Counter
	Tags  map[string]string `json:"tags,omitempty"`
}

// outputsPayload is the structure for the final outputs JSON object.
type outputsPayload struct {
	Outputs map[string]interface{} `json:"outputs"`
}

// metricsPayload is the structure for the final metrics JSON object.
type metricsPayload struct {
	Metrics []KestraMetric `json:"metrics"`
}

// --- Metric Creation Helpers ---

// NewCounter creates a KestraMetric struct for a counter.
// Value can be int or float64.
func NewCounter(name string, value interface{}, tags map[string]string) KestraMetric {
	// Basic type check, Kestra might handle various numeric types
	switch value.(type) {
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64:
		// Allowed types
	default:
		log.Printf("Warning: Counter '%s' received non-numeric value type %T. Kestra might not process it correctly.", name, value)
	}
	return KestraMetric{
		Type:  "counter",
		Name:  name,
		Value: value,
		Tags:  tags,
	}
}

// NewTimer creates a KestraMetric struct for a timer.
// Value can be time.Duration or a numeric type representing seconds (float64 preferred).
func NewTimer(name string, value interface{}, tags map[string]string) KestraMetric {
	var durationSeconds float64
	switch v := value.(type) {
	case time.Duration:
		durationSeconds = v.Seconds()
	case int:
		durationSeconds = float64(v)
	case int32:
		durationSeconds = float64(v)
	case int64:
		durationSeconds = float64(v)
	case float32:
		durationSeconds = float64(v)
	case float64:
		durationSeconds = v
	default:
		log.Printf("Warning: Timer '%s' received unsupported value type %T. Defaulting to 0. Use time.Duration or numeric seconds.", name, value)
		durationSeconds = 0
	}

	return KestraMetric{
		Type:  "timer",
		Name:  name,
		Value: durationSeconds,
		Tags:  tags,
	}
}

// NewGauge creates a KestraMetric struct for a gauge.
// Value should ideally be float64 or convertible to it.
func NewGauge(name string, value interface{}, tags map[string]string) KestraMetric {
	var gaugeValue float64
	switch v := value.(type) {
	case int:
		gaugeValue = float64(v)
	case int8:
		gaugeValue = float64(v)
	case int16:
		gaugeValue = float64(v)
	case int32:
		gaugeValue = float64(v)
	case int64:
		gaugeValue = float64(v)
	case uint:
		gaugeValue = float64(v)
	case uint8:
		gaugeValue = float64(v)
	case uint16:
		gaugeValue = float64(v)
	case uint32:
		gaugeValue = float64(v)
	case uint64:
		gaugeValue = float64(v) // Potential precision loss for very large uint64
	case float32:
		gaugeValue = float64(v)
	case float64:
		gaugeValue = v
	default:
		// Attempt conversion from string representation if possible
		stringValue := fmt.Sprintf("%v", value)
		parsedValue, err := strconv.ParseFloat(stringValue, 64)
		if err != nil {
			log.Printf("Warning: Gauge '%s' received unsupported value type %T and failed string conversion. Defaulting to 0.", name, value)
			gaugeValue = 0
		} else {
			log.Printf("Warning: Gauge '%s' received value type %T. Converted via string representation.", name, value)
			gaugeValue = parsedValue
		}
	}
	return KestraMetric{
		Type:  "gauge",
		Name:  name,
		Value: gaugeValue,
		Tags:  tags,
	}
}

// --- Kestra Output Functions ---

// Outputs sends outputs back to Kestra by printing a formatted JSON string.
// The `outputs` argument should be a map containing the data to be outputted.
func Outputs(outputs map[string]interface{}) {
	if outputs == nil {
		log.Println("Warning: Outputs called with nil map.")
		return
	}
	payload := outputsPayload{Outputs: outputs}
	jsonBytes, err := json.Marshal(payload)
	if err != nil {
		log.Printf("Error marshaling outputs to JSON: %v\n", err)
		// Optionally print a Kestra-formatted error?
		// fmt.Printf("::{\"error\":\"Failed to marshal outputs: %v\"}::\n", err)
		return
	}
	// Print in the format Kestra expects: ::{"outputs":{...}}::
	fmt.Printf("::%s::\n", string(jsonBytes))
}

// Metrics sends metrics back to Kestra by printing a formatted JSON string.
// The `metrics` argument should be a slice of KestraMetric structs.
func Metrics(metrics []KestraMetric) {
	if metrics == nil {
		log.Println("Warning: Metrics called with nil slice.")
		return
	}
	// Filter out metrics with nil value before marshalling if necessary
	validMetrics := []KestraMetric{}
	for _, m := range metrics {
		if m.Value != nil {
			validMetrics = append(validMetrics, m)
		} else {
			log.Printf("Warning: Metric '%s' has nil value and will be skipped.", m.Name)
		}
	}

	if len(validMetrics) == 0 {
		log.Println("No valid metrics to send.")
		return
	}

	payload := metricsPayload{Metrics: validMetrics}
	jsonBytes, err := json.Marshal(payload)
	if err != nil {
		log.Printf("Error marshaling metrics to JSON: %v\n", err)
		// fmt.Printf("::{\"error\":\"Failed to marshal metrics: %v\"}::\n", err)
		return
	}
	// Print in the format Kestra expects: ::{"metrics":[...]}::
	fmt.Printf("::%s::\n", string(jsonBytes))
}

type LogEntry struct {
	Level   string `json:"level"`
	Message string `json:"message"`
}

type LogOutput struct {
	Logs []LogEntry `json:"logs"`
}

func (k *KestraLogger) logMessage(level, message string) {
	timestamp := time.Now().Format(time.RFC3339Nano)
	logEntry := LogEntry{
		Level:   level,
		Message: timestamp + " - " + message,
	}

	logOutput := LogOutput{
		Logs: []LogEntry{logEntry},
	}

	jsonOutput, err := json.Marshal(logOutput)
	if err != nil {
		log.Fatalf("Error marshalling log output: %v", err)
	}

	os.Stdout.Write([]byte("::" + string(jsonOutput) + "::\n"))
}

func (k *KestraLogger) Trace(message string) {
	k.logMessage("TRACE", message)
}

func (k *KestraLogger) Debug(message string) {
	k.logMessage("DEBUG", message)
}

func (k *KestraLogger) Info(message string) {
	k.logMessage("INFO", message)
}

func (k *KestraLogger) Warn(message string) {
	k.logMessage("WARN", message)
}

func (k *KestraLogger) Error(message string) {
	k.logMessage("ERROR", message)
}
