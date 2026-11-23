package kestra

import (
	"encoding/base64"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withContextFile(t *testing.T) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "context.json")
	if err := os.WriteFile(file, []byte(`{"labels":{"env":"prod"},"inputs":{"text":"a\nb caf\u00e9"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KESTRA_EXECUTION_CONTEXT_FILE", file)
	t.Setenv("KESTRA_CONTEXT", "")
	cachedContext = nil
	t.Cleanup(func() { cachedContext = nil })
	return file
}

func TestContextIsReadOnce(t *testing.T) {
	file := withContextFile(t)

	context, err := Context()
	must(t, err)
	if env := context["labels"].(map[string]any)["env"]; env != "prod" {
		t.Fatalf("labels.env = %v", env)
	}
	if text := context["inputs"].(map[string]any)["text"]; text != "a\nb caf\u00e9" {
		t.Fatalf("inputs.text = %q", text)
	}

	must(t, os.Remove(file))
	context["labels"].(map[string]any)["env"] = "changed"
	again, err := Context()
	must(t, err)
	if env := again["labels"].(map[string]any)["env"]; env != "prod" {
		t.Fatalf("cached context changed by a caller: labels.env = %v", env)
	}
}

func TestLoadContextFromPathOrBase64(t *testing.T) {
	file := withContextFile(t)

	context, err := LoadContext(file)
	must(t, err)
	if context["labels"].(map[string]any)["env"] != "prod" {
		t.Fatalf("got %v", context)
	}

	t.Setenv("KESTRA_EXECUTION_CONTEXT_FILE", filepath.Join(t.TempDir(), "missing.json"))
	t.Setenv("KESTRA_CONTEXT", base64.StdEncoding.EncodeToString([]byte(`{"vars":{"n":42}}`)))
	context, err = LoadContext("")
	must(t, err)
	if n := context["vars"].(map[string]any)["n"]; n != 42.0 {
		t.Fatalf("vars.n = %v", n)
	}
}

func TestLoadContextDoesNotFallBackForAnExplicitPath(t *testing.T) {
	withContextFile(t)
	t.Setenv("KESTRA_CONTEXT", base64.StdEncoding.EncodeToString([]byte(`{"vars":{"n":42}}`)))

	_, err := LoadContext(filepath.Join(t.TempDir(), "typo.json"))
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("got %v, want a not-exist error", err)
	}
}

func TestContextThatIsNotAnObjectNamesTheSource(t *testing.T) {
	for content, want := range map[string]string{"": "is not valid JSON", "{": "is not valid JSON", "null": "is JSON but not an object", "[1]": "is JSON but not an object"} {
		file := filepath.Join(t.TempDir(), "context.json")
		must(t, os.WriteFile(file, []byte(content), 0o600))

		_, err := LoadContext(file)
		if err == nil || !strings.Contains(err.Error(), file+" "+want) {
			t.Errorf("content %q: got %v, want an error naming %s", content, err, file)
		}
	}

	withContextFile(t)
	t.Setenv("KESTRA_EXECUTION_CONTEXT_FILE", filepath.Join(t.TempDir(), "missing.json"))
	for encoded, want := range map[string]string{
		"not base64!": "KESTRA_CONTEXT environment variable is not valid base64",
		base64.StdEncoding.EncodeToString([]byte("[1]")): "KESTRA_CONTEXT is JSON but not an object",
	} {
		t.Setenv("KESTRA_CONTEXT", encoded)
		if _, err := LoadContext(""); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("KESTRA_CONTEXT %q: got %v, want %q", encoded, err, want)
		}
	}
}

func TestADirectoryFailsInsteadOfFallingBack(t *testing.T) {
	withContextFile(t)
	t.Setenv("KESTRA_EXECUTION_CONTEXT_FILE", t.TempDir())
	t.Setenv("KESTRA_CONTEXT", base64.StdEncoding.EncodeToString([]byte(`{"vars":{"n":42}}`)))

	if _, err := Context(); err == nil || !strings.Contains(err.Error(), "is a directory") {
		t.Fatalf("got %v, want a read error", err)
	}
}

func TestContextFailsClearlyOutsideKestra(t *testing.T) {
	withContextFile(t)
	t.Setenv("KESTRA_EXECUTION_CONTEXT_FILE", filepath.Join(t.TempDir(), "missing.json"))

	_, err := Context()
	if !errors.Is(err, fs.ErrNotExist) || !strings.Contains(err.Error(), "no execution context found") {
		t.Fatalf("got %v", err)
	}
}
