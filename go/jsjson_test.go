package affordkit

import (
	"encoding/json"
	"math"
	"testing"
)

func TestJSNumber(t *testing.T) {
	tenth := 0.1
	for _, c := range []struct {
		in   float64
		want string
	}{
		{312, "312"}, {0, "0"}, {math.Copysign(0, -1), "0"}, {-3, "-3"}, {0.5, "0.5"}, {3.12, "3.12"}, {tenth + 2*tenth, "0.30000000000000004"},
		{1e21, "1e+21"}, {1e20, "100000000000000000000"}, {123456789012345680000, "123456789012345680000"}, {1.5e300, "1.5e+300"},
		{0.000001, "0.000001"}, {1e-7, "1e-7"}, {1.25e-7, "1.25e-7"}, {-2.5e-8, "-2.5e-8"}, {1792711772948, "1792711772948"},
		{math.NaN(), "NaN"}, {math.Inf(1), "Infinity"}, {math.Inf(-1), "-Infinity"}, {9007199254740993, "9007199254740992"},
	} {
		if got := jsNumber(c.in); got != c.want {
			t.Errorf("jsNumber(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestJSQuote(t *testing.T) {
	for in, want := range map[string]string{
		`a "b" \ c`:         `"a \"b\" \\ c"`,
		"<b>&</b>":          `"<b>&</b>"`,
		"line\nnext\ttab\r": `"line\nnext\ttab\r"`,
		"\x01\x1f\x7f":      `"\u0001\u001f` + "\x7f" + `"`,
		"   — é 你好 😀":       "\"   — é 你好 😀\"",
		"\b\f":              `"\b\f"`,
	} {
		if got := jsQuote(in); got != want {
			t.Errorf("jsQuote(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestJSStringify(t *testing.T) {
	for in, want := range map[string]string{
		`{ "b": 1, "a": [1.0, 2E2, -0.0, 1e400], "c": {"z": null, "y": true} }`: `{"b":1,"a":[1,200,0,null],"c":{"z":null,"y":true}}`,
		`{"b":1,"10":2,"2":3,"a":4,"01":5}`:                                     `{"2":3,"10":2,"b":1,"a":4,"01":5}`,
		`{"a":1,"b":2,"a":3}`:                                                   `{"a":3,"b":2}`,
		`"café <&>  "`:                                                          "\"café <&>  \"",
		`[]`:                                                                    `[]`,
		`{}`:                                                                    `{}`,
		`  42  `:                                                                `42`,
		`false`:                                                                 `false`,
	} {
		if got := jsStringify(json.RawMessage(in)); got != want {
			t.Errorf("jsStringify(%s) = %s, want %s", in, got, want)
		}
	}
	if got := jsStringify(nil); got != "undefined" {
		t.Errorf("jsStringify(nil) = %s", got)
	}
}

func TestJSToStringAndTruthy(t *testing.T) {
	for in, want := range map[string]string{`"x"`: "x", `3.0`: "3", `true`: "true", `null`: "null", `{"a":1}`: "[object Object]", `[1,null,"b",[2,3]]`: "1,,b,2,3", ``: "undefined"} {
		if got := jsToString(json.RawMessage(in)); got != want {
			t.Errorf("jsToString(%s) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]bool{``: false, `null`: false, `false`: false, `0`: false, `0.0`: false, `""`: false, `"0"`: true, `1`: true, `[]`: true, `{}`: true, `true`: true} {
		if got := jsTruthy(json.RawMessage(in)); got != want {
			t.Errorf("jsTruthy(%s) = %v, want %v", in, got, want)
		}
	}
	for _, c := range []struct {
		in   any
		want string
	}{{nil, "null"}, {"s", "s"}, {12.0, "12"}, {7, "7"}, {true, "true"}, {map[string]any{}, "[object Object]"}, {[]any{1.0, nil, "x"}, "1,,x"}} {
		if got := jsStringAny(c.in); got != c.want {
			t.Errorf("jsStringAny(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestJSTrimAndLength(t *testing.T) {
	if got := jsTrim("\ufeff\u00a0 hi \u2028\u3000"); got != "hi" {
		t.Errorf("jsTrim = %q", got)
	}
	// U+0085 is space to Go, not to JavaScript
	if got := jsTrim("\u0085hi"); got != "\u0085hi" {
		t.Errorf("jsTrim kept NEL? %q", got)
	}
	if n := jsLength("a😀é"); n != 4 {
		t.Errorf("jsLength = %d, want 4", n)
	}
}

func TestEntriesOrder(t *testing.T) {
	var e Entries[json.RawMessage]
	if err := json.Unmarshal([]byte(`{"length":7,"focused":true,"3":"x","1":"y","length":8}`), &e); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for _, x := range e {
		keys = append(keys, x.Key)
	}
	if got := jsonString(t, keys); got != `["1","3","length","focused"]` {
		t.Errorf("keys %s", got)
	}
	if v, _ := e.Get("length"); string(v) != "8" {
		t.Errorf("length = %s", v)
	}
	b, err := json.Marshal(e)
	if err != nil || string(b) != `{"1":"y","3":"x","length":8,"focused":true}` {
		t.Errorf("marshal %s %v", b, err)
	}
	var s Entries[string]
	if err := json.Unmarshal([]byte(`null`), &s); err != nil || s != nil {
		t.Errorf("null: %v %v", s, err)
	}
	if err := json.Unmarshal([]byte(`[1]`), &s); err == nil {
		t.Error("an array is not an object")
	}
}

func jsonString(t *testing.T, v any) string {
	t.Helper()
	b, err := marshalCompact(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
