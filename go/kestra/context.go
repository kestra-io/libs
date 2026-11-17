package kestra

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sync"
)

const contextFile = ".kestra-execution-context.json"

var (
	contextMu     sync.Mutex
	cachedContext []byte
)

// Context returns the execution context (labels, inputs, vars, trigger, outputs of earlier tasks).
// It is read once, like LoadContext(""), and each call returns a new map the caller may change.
func Context() (map[string]any, error) {
	contextMu.Lock()
	defer contextMu.Unlock()
	if cachedContext == nil {
		data, err := readContext("")
		if err != nil {
			return nil, err
		}
		cachedContext = data
	}
	return decodeContext(cachedContext)
}

// LoadContext reads the execution context from path. An empty path reads KESTRA_EXECUTION_CONTEXT_FILE or
// .kestra-execution-context.json (written when the task sets executionContext: true), falling back to the
// base64-encoded KESTRA_CONTEXT variable. Outside a Kestra task the error wraps fs.ErrNotExist.
func LoadContext(path string) (map[string]any, error) {
	data, err := readContext(path)
	if err != nil {
		return nil, err
	}
	return decodeContext(data)
}

func readContext(path string) ([]byte, error) {
	isExplicit := path != ""
	if !isExplicit {
		path = os.Getenv("KESTRA_EXECUTION_CONTEXT_FILE")
	}
	if path == "" {
		path = contextFile
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) && !isExplicit {
		encoded := os.Getenv("KESTRA_CONTEXT")
		if encoded == "" {
			return nil, fmt.Errorf("kestra: no execution context found: %q does not exist and the KESTRA_CONTEXT "+
				"environment variable is not set, the execution context is only available inside a Kestra task: %w", path, fs.ErrNotExist)
		}
		data, err = base64.StdEncoding.DecodeString(encoded)
	}
	if err != nil {
		return nil, fmt.Errorf("kestra: read execution context: %w", err)
	}
	return data, nil
}

func decodeContext(data []byte) (map[string]any, error) {
	var context map[string]any
	if err := json.Unmarshal(data, &context); err != nil {
		return nil, fmt.Errorf("kestra: parse execution context: %w", err)
	}
	return context, nil
}
