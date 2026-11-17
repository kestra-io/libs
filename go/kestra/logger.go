package kestra

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
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
	attrs := slog.NewTextHandler(buf, &slog.HandlerOptions{
		Level: slog.Level(-100),
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && (a.Key == slog.TimeKey || a.Key == slog.LevelKey || a.Key == slog.MessageKey) {
				return slog.Attr{}
			}
			return a
		},
	})
	return &handler{attrs: attrs, buf: buf, mu: &sync.Mutex{}}
}

func (h *handler) Enabled(context.Context, slog.Level) bool { return true }

func (h *handler) Handle(ctx context.Context, record slog.Record) error {
	h.mu.Lock()
	h.buf.Reset()
	err := h.attrs.Handle(ctx, record)
	rendered := strings.TrimSpace(h.buf.String())
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
