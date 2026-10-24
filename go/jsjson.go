package affordkit

// JavaScript's ways of turning values into text, for the text the model reads to be byte for byte what the TypeScript reference
// gives: JSON.stringify (compact, keys in the order JavaScript keeps them, non-ASCII as it is), numbers as JavaScript prints them
// (312, 0.5, 1e+21), String(v) / `${v}` in a template, and truthiness. Values from the app are kept as raw JSON (json.RawMessage)
// until they are printed, so the app's key order is never lost.

import (
	"bytes"
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
)

// jsNumber prints a number as JavaScript's Number.prototype.toString does.
func jsNumber(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	case f == 0:
		return "0"
	}
	sign := ""
	if f < 0 {
		sign = "-"
		f = -f
	}
	// The shortest digits that read back as f (the same digits JavaScript picks), and where the decimal point goes
	e := strconv.FormatFloat(f, 'e', -1, 64)
	mant, exp, _ := strings.Cut(e, "e")
	digits := strings.Replace(mant, ".", "", 1)
	x, _ := strconv.Atoi(exp)
	n := x + 1
	k := len(digits)
	switch {
	case k <= n && n <= 21:
		return sign + digits + strings.Repeat("0", n-k)
	case 0 < n && n <= 21:
		return sign + digits[:n] + "." + digits[n:]
	case -6 < n && n <= 0:
		return sign + "0." + strings.Repeat("0", -n) + digits
	}
	es := "+"
	if n-1 < 0 {
		es = "-"
	}
	ex := strconv.Itoa(abs(n - 1))
	if k == 1 {
		return sign + digits + "e" + es + ex
	}
	return sign + digits[:1] + "." + digits[1:] + "e" + es + ex
}

func abs(i int) int {
	if i < 0 {
		return -i
	}
	return i
}

// jsQuote is JSON.stringify of a string: only ", \ and control characters escaped (no HTML escaping, U+2028 as it is).
func jsQuote(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte("0123456789abcdef"[r>>4])
				b.WriteByte("0123456789abcdef"[r&0xf])
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// jsLength is a string's length as JavaScript counts it (UTF-16 code units).
func jsLength(s string) int {
	n := 0
	for _, r := range s {
		n += len(utf16.Encode([]rune{r}))
	}
	return n
}

// jsTrim is String.prototype.trim: JavaScript's white space and line terminators, which are not quite Go's unicode.IsSpace.
func jsTrim(s string) string {
	return strings.TrimFunc(s, func(r rune) bool {
		switch r {
		case '\t', '\n', '\v', '\f', '\r', ' ', 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
			return true
		}
		return r >= 0x2000 && r <= 0x200a
	})
}

// rawKind is what a raw JSON value is, by its first byte: '{', '[', '"', 'n' (null), 't', 'f', '0' (a number), or 0 when absent.
func rawKind(raw json.RawMessage) byte {
	t := bytes.TrimLeft(raw, " \t\r\n")
	if len(t) == 0 {
		return 0
	}
	switch c := t[0]; c {
	case '{', '[', '"', 'n', 't', 'f':
		return c
	}
	return '0'
}

// rawString is a raw JSON string's value (ok false when it is not a string).
func rawString(raw json.RawMessage) (string, bool) {
	if rawKind(raw) != '"' {
		return "", false
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

// rawNumber is a raw JSON number's value (ok false when it is not a number).
func rawNumber(raw json.RawMessage) (float64, bool) {
	if rawKind(raw) != '0' {
		return 0, false
	}
	f, err := strconv.ParseFloat(string(bytes.TrimSpace(raw)), 64)
	if err != nil && !math.IsInf(f, 0) {
		return 0, false
	}
	return f, true
}

// jsonField is one key of an object, in the order JavaScript has it.
type jsonField struct {
	Key   string
	Value json.RawMessage
}

// isArrayIndex says whether JavaScript treats an object key as an integer index (those come first, in ascending order).
func isArrayIndex(k string) (uint64, bool) {
	if k == "" || len(k) > 10 || (len(k) > 1 && k[0] == '0') {
		return 0, false
	}
	for i := 0; i < len(k); i++ {
		if k[i] < '0' || k[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(k, 10, 64)
	if err != nil || n >= 4294967295 {
		return 0, false
	}
	return n, true
}

// rawFields reads a raw JSON object's keys as JSON.parse would leave them: a repeated key keeps its first place and its last
// value, integer keys come first in ascending order, then the others in the order they came.
func rawFields(raw json.RawMessage) ([]jsonField, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return nil, &json.UnmarshalTypeError{Value: "non-object", Type: nil}
	}
	var fields []jsonField
	at := map[string]int{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, _ := tok.(string)
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		if i, ok := at[key]; ok {
			fields[i].Value = v
			continue
		}
		at[key] = len(fields)
		fields = append(fields, jsonField{key, v})
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	sort.SliceStable(fields, func(i, j int) bool {
		a, aok := isArrayIndex(fields[i].Key)
		b, bok := isArrayIndex(fields[j].Key)
		if aok && bok {
			return a < b
		}
		return aok && !bok
	})
	return fields, nil
}

// jsStringify is JSON.stringify of a raw JSON value ("undefined" when there is none, as a template would print it).
func jsStringify(raw json.RawMessage) string {
	if rawKind(raw) == 0 {
		return "undefined"
	}
	var b strings.Builder
	writeJS(&b, raw)
	return b.String()
}

func writeJS(b *strings.Builder, raw json.RawMessage) {
	switch rawKind(raw) {
	case '{':
		fields, err := rawFields(raw)
		if err != nil {
			b.WriteString("null")
			return
		}
		b.WriteByte('{')
		for i, f := range fields {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(jsQuote(f.Key))
			b.WriteByte(':')
			writeJS(b, f.Value)
		}
		b.WriteByte('}')
	case '[':
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil {
			b.WriteString("null")
			return
		}
		b.WriteByte('[')
		for i, v := range items {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJS(b, v)
		}
		b.WriteByte(']')
	case '"':
		s, _ := rawString(raw)
		b.WriteString(jsQuote(s))
	case '0':
		f, ok := rawNumber(raw)
		if !ok || math.IsInf(f, 0) || math.IsNaN(f) {
			b.WriteString("null")
			return
		}
		b.WriteString(jsNumber(f))
	case 't':
		b.WriteString("true")
	case 'f':
		b.WriteString("false")
	default:
		b.WriteString("null")
	}
}

// jsToString is String(v), or `${v}` in a template, of a raw JSON value ("undefined" when there is none).
func jsToString(raw json.RawMessage) string {
	switch rawKind(raw) {
	case 0:
		return "undefined"
	case '"':
		s, _ := rawString(raw)
		return s
	case '0':
		f, _ := rawNumber(raw)
		return jsNumber(f)
	case 't':
		return "true"
	case 'f':
		return "false"
	case 'n':
		return "null"
	case '[':
		var items []json.RawMessage
		_ = json.Unmarshal(raw, &items)
		parts := make([]string, len(items))
		for i, v := range items {
			if k := rawKind(v); k != 'n' && k != 0 {
				parts[i] = jsToString(v)
			}
		}
		return strings.Join(parts, ",")
	}
	return "[object Object]"
}

// jsTruthy is whether a raw JSON value is truthy in JavaScript (absent, false, null, 0, NaN and "" are not).
func jsTruthy(raw json.RawMessage) bool {
	switch rawKind(raw) {
	case 0, 'n', 'f':
		return false
	case '"':
		s, _ := rawString(raw)
		return s != ""
	case '0':
		f, _ := rawNumber(raw)
		return f != 0 && !math.IsNaN(f)
	}
	return true
}

// jsStringAny is String(v) of a value decoded from JSON into Go (map[string]any, []any, float64, string, bool, nil), or given as Go
// values (other numbers too).
func jsStringAny(v any) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case float64:
		return jsNumber(x)
	case float32:
		return jsNumber(float64(x))
	case int:
		return jsNumber(float64(x))
	case int64:
		return jsNumber(float64(x))
	case int32:
		return jsNumber(float64(x))
	case json.Number:
		f, _ := x.Float64()
		return jsNumber(f)
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			if e != nil {
				parts[i] = jsStringAny(e)
			}
		}
		return strings.Join(parts, ",")
	}
	return "[object Object]"
}

// marshalCompact marshals v as JSON without HTML escaping (<, > and & as they are, as JavaScript writes them).
func marshalCompact(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// normalize turns Go values into what decoding JSON gives (float64 numbers, []any, map[string]any), so input built in Go and
// input decoded from a model's JSON are checked the same way. Values that can't be JSON are left as they are.
func normalize(input map[string]any) map[string]any {
	if input == nil {
		return map[string]any{}
	}
	b, err := json.Marshal(input)
	if err != nil {
		return input
	}
	var out map[string]any
	if json.Unmarshal(b, &out) != nil || out == nil {
		return input
	}
	return out
}
