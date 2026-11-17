package kestra

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"time"
)

var logger = slog.New(&handler{})

// Logger returns a slog.Logger whose records Kestra logs at the matching level.
// Attributes are appended to the message as key=value. Levels below Debug are sent as TRACE.
func Logger() *slog.Logger {
	return logger
}

// handler renders attributes with slog's text handler, then sends the record as a Kestra log line.
// It keeps no shared buffer or lock, so attributes whose String, Error or LogValue methods log are safe.
type handler struct {
	scopes []func(slog.Handler) slog.Handler
}

// The text handler always writes these built-ins first. A zero time is omitted, and caller attributes follow.
const builtins = `level=INFO msg=""`

func (h *handler) Enabled(context.Context, slog.Level) bool { return true }

func (h *handler) Handle(ctx context.Context, record slog.Record) error {
	var buf bytes.Buffer
	var text slog.Handler = slog.NewTextHandler(&buf, nil)
	for _, scope := range h.scopes {
		text = scope(text)
	}
	attrs := slog.NewRecord(time.Time{}, slog.LevelInfo, "", 0)
	record.Attrs(func(a slog.Attr) bool {
		attrs.AddAttrs(a)
		return true
	})
	if err := text.Handle(ctx, attrs); err != nil {
		return err
	}

	message := record.Message
	if rendered := strings.TrimSpace(strings.TrimPrefix(buf.String(), builtins)); rendered != "" {
		message += " " + rendered
	}
	return send(map[string]any{"logs": []map[string]string{{"level": level(record.Level), "message": message}}})
}

func (h *handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return h.with(func(text slog.Handler) slog.Handler { return text.WithAttrs(attrs) })
}

func (h *handler) WithGroup(name string) slog.Handler {
	return h.with(func(text slog.Handler) slog.Handler { return text.WithGroup(name) })
}

func (h *handler) with(scope func(slog.Handler) slog.Handler) *handler {
	scopes := make([]func(slog.Handler) slog.Handler, len(h.scopes), len(h.scopes)+1)
	copy(scopes, h.scopes)
	return &handler{scopes: append(scopes, scope)}
}

func level(l slog.Level) string {
	switch {
	case l < slog.LevelDebug:
		return "TRACE"
	case l < slog.LevelInfo:
		return "DEBUG"
	case l < slog.LevelWarn:
		return "INFO"
	case l < slog.LevelError:
		return "WARN"
	default:
		return "ERROR"
	}
}
