package kestra

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"
)

var logger = slog.New(newHandler())

// Logger returns a slog.Logger whose records Kestra logs at the matching level.
// Attributes are appended to the message as key=value. Levels below Debug are sent as TRACE.
func Logger() *slog.Logger {
	return logger
}

// handler renders attributes with slog's text handler, then sends the record as a Kestra log line.
type handler struct {
	attrs slog.Handler
	buf   *bytes.Buffer
	mu    *sync.Mutex
}

func newHandler() *handler {
	buf := &bytes.Buffer{}
	return &handler{attrs: slog.NewTextHandler(buf, nil), buf: buf, mu: &sync.Mutex{}}
}

// The text handler always writes these built-ins first. A zero time is omitted, and caller attributes follow.
const builtins = `level=INFO msg=""`

func (h *handler) Enabled(context.Context, slog.Level) bool { return true }

func (h *handler) Handle(ctx context.Context, record slog.Record) error {
	attrs := slog.NewRecord(time.Time{}, slog.LevelInfo, "", 0)
	record.Attrs(func(a slog.Attr) bool {
		attrs.AddAttrs(a)
		return true
	})

	h.mu.Lock()
	h.buf.Reset()
	err := h.attrs.Handle(ctx, attrs)
	rendered := strings.TrimSpace(strings.TrimPrefix(h.buf.String(), builtins))
	h.mu.Unlock()
	if err != nil {
		return err
	}

	message := record.Message
	if rendered != "" {
		message += " " + rendered
	}
	return send(map[string]any{"logs": []map[string]string{{"level": level(record.Level), "message": message}}})
}

func (h *handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &handler{attrs: h.attrs.WithAttrs(attrs), buf: h.buf, mu: h.mu}
}

func (h *handler) WithGroup(name string) slog.Handler {
	return &handler{attrs: h.attrs.WithGroup(name), buf: h.buf, mu: h.mu}
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
