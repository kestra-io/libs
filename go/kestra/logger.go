package kestra

import (
	"bytes"
	"context"
	"encoding"
	"fmt"
	"log/slog"
	"reflect"
	"sort"
	"strings"
	"time"
)

// fmt recurses forever into a map or slice that contains itself, so attribute values are rendered with these limits.
const (
	maxDepth = 10
	maxItems = 1000
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
	var text slog.Handler = slog.NewTextHandler(&buf, &slog.HandlerOptions{ReplaceAttr: renderAttr})
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

func renderAttr(_ []string, a slog.Attr) slog.Attr {
	if a.Value.Kind() != slog.KindAny {
		return a
	}
	// Any byte slice, such as json.RawMessage, stays with slog, which prints it as text.
	if t := reflect.TypeOf(a.Value.Any()); t == nil || t.Kind() != reflect.Slice || t.Elem().Kind() != reflect.Uint8 {
		a.Value = slog.StringValue(render(a.Value.Any()))
	}
	return a
}

// render formats v like fmt's %+v, but stops at maxDepth and after maxItems elements, and never panics.
func render(v any) (text string) {
	defer func() {
		if r := recover(); r != nil {
			text = fmt.Sprintf("%%!v(PANIC=%v)", r)
		}
	}()
	if marshaler, ok := v.(encoding.TextMarshaler); ok {
		data, err := marshaler.MarshalText()
		if err != nil {
			return "!ERROR:" + err.Error()
		}
		return string(data)
	}
	var b strings.Builder
	items := maxItems
	appendValue(&b, reflect.ValueOf(v), 0, &items)
	return b.String()
}

func appendValue(b *strings.Builder, v reflect.Value, depth int, items *int) {
	if !v.IsValid() {
		b.WriteString("<nil>")
		return
	}
	if v.CanInterface() {
		switch v.Interface().(type) {
		case error, fmt.Stringer, fmt.Formatter:
			// fmt calls the method and recovers its panics.
			fmt.Fprintf(b, "%+v", v.Interface())
			return
		}
	}
	switch v.Kind() {
	case reflect.Interface:
		appendValue(b, v.Elem(), depth, items)
	case reflect.Pointer:
		kind := v.Type().Elem().Kind()
		switch {
		case v.IsNil():
			b.WriteString("<nil>")
		case depth == 0 && (kind == reflect.Array || kind == reflect.Slice || kind == reflect.Struct || kind == reflect.Map):
			b.WriteByte('&')
			appendValue(b, v.Elem(), depth+1, items)
		default:
			fmt.Fprintf(b, "0x%x", v.Pointer())
		}
	case reflect.Map:
		b.WriteString("map[")
		keys := v.MapKeys()
		sort.Slice(keys, func(i, j int) bool { return lessKey(keys[i], keys[j]) })
		appendItems(b, len(keys), depth, items, func(i int) {
			appendValue(b, keys[i], depth+1, items)
			b.WriteByte(':')
			appendValue(b, v.MapIndex(keys[i]), depth+1, items)
		})
		b.WriteByte(']')
	case reflect.Slice, reflect.Array:
		b.WriteByte('[')
		appendItems(b, v.Len(), depth, items, func(i int) { appendValue(b, v.Index(i), depth+1, items) })
		b.WriteByte(']')
	case reflect.Struct:
		b.WriteByte('{')
		appendItems(b, v.NumField(), depth, items, func(i int) {
			b.WriteString(v.Type().Field(i).Name + ":")
			appendValue(b, v.Field(i), depth+1, items)
		})
		b.WriteByte('}')
	default:
		fmt.Fprintf(b, "%+v", v)
	}
}

func appendItems(b *strings.Builder, n, depth int, items *int, appendItem func(int)) {
	for i := 0; i < n; i++ {
		if i > 0 {
			b.WriteByte(' ')
		}
		if depth >= maxDepth || *items <= 0 {
			b.WriteString("...")
			return
		}
		*items--
		appendItem(i)
	}
}

func lessKey(a, b reflect.Value) bool {
	// Keys of a map[any]any are interfaces: compare what they hold, ordered by type first as fmt does.
	if a.Kind() == reflect.Interface {
		a, b = a.Elem(), b.Elem()
		if !a.IsValid() || !b.IsValid() {
			return !a.IsValid() && b.IsValid()
		}
		if a.Type() != b.Type() {
			return a.Type().String() < b.Type().String()
		}
	}
	switch a.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return a.Int() < b.Int()
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return a.Uint() < b.Uint()
	case reflect.Float32, reflect.Float64:
		return a.Float() < b.Float()
	case reflect.String:
		return a.String() < b.String()
	}
	return fmt.Sprint(a) < fmt.Sprint(b)
}
