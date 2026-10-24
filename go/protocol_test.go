package affordkit

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func decode(t *testing.T, s string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatalf("%s: %v", s, err)
	}
	return v
}

func TestToCall(t *testing.T) {
	cases := []struct {
		tool  string
		input string
		want  string // the call as JSON; "null" for none
	}{
		{"ui_look", `{"picture":true}`, `null`},
		{"ui_act", `{"node":"w4","op":"press"}`, `{"node":"w4","op":"press","args":{}}`},
		{"ui_act", `{"node":"mail.search","op":"write","args":{"text":"hi"}}`, `{"node":"mail.search","op":"write","args":{"text":"hi"}}`},
		{"ui_act", `{}`, `{"node":"","op":"","args":{}}`},
		{"ui_act", `{"node":12,"op":true,"args":"oops"}`, `{"node":"12","op":"true","args":{}}`},
		{"ui_act", `{"node":null,"op":"read","args":null}`, `{"node":"","op":"read","args":{}}`},
		{"ui_tool", `{"name":"set_theme","args":{"theme":"dark"}}`, `{"tool":"set_theme","args":{"theme":"dark"}}`},
		{"ui_tool", `{}`, `{"tool":"","args":{}}`},
		{"ui_navigate", `{"route":"back"}`, `{"navigate":"back"}`},
		{"ui_navigate", `{}`, `{"navigate":""}`},
		{"ui_peek", `{"route":"/settings/ai"}`, `{"peek":"/settings/ai"}`},
	}
	for _, c := range cases {
		call, err := ToCall(c.tool, decode(t, c.input).(map[string]any))
		if err != nil {
			t.Errorf("%s %s: %v", c.tool, c.input, err)
			continue
		}
		var got string
		if call == nil {
			got = "null"
		} else {
			got = jsonString(t, call)
		}
		if got != c.want {
			t.Errorf("ToCall(%s, %s) = %s, want %s", c.tool, c.input, got, c.want)
		}
	}
	if _, err := ToCall("ui_handoff", map[string]any{}); err == nil || !strings.Contains(err.Error(), "not a call to the app") {
		t.Errorf("ui_handoff: %v", err)
	}
	if _, err := ToCall("ui_fly", map[string]any{}); err == nil || err.Error() != "Not an AffordKit tool: ui_fly" {
		t.Errorf("ui_fly: %v", err)
	}
}

func TestCallJSON(t *testing.T) {
	for in, want := range map[string]CallKind{
		`{"node":"a","op":"press"}`:            CallNode,
		`{"tool":"x","args":{"a":1}}`:          CallTool,
		`{"navigate":"/a"}`:                    CallNavigate,
		`{"peek":"/a"}`:                        CallPeek,
		`{"something":"else"}`:                 CallNone,
		`{"peek":"/a","navigate":"/b","op":1}`: CallPeek,
	} {
		var c Call
		if err := json.Unmarshal([]byte(in), &c); err != nil || c.Kind != want {
			t.Errorf("%s: kind %v (%v), want %v", in, c.Kind, err, want)
		}
	}
	var c Call
	_ = json.Unmarshal([]byte(`{"tool":"x","args":{"a":1}}`), &c)
	if got := jsonString(t, c); got != `{"tool":"x","args":{"a":1}}` {
		t.Errorf("round trip %s", got)
	}
}

func TestHandoffProblem(t *testing.T) {
	calls := func(n int) string {
		parts := make([]string, n)
		for i := range parts {
			parts[i] = `{"key":"a","op":"press"}`
		}
		return "[" + strings.Join(parts, ",") + "]"
	}
	cases := []struct{ in, want string }{
		{`{"message":"Done."}`, ""},
		{`{"message":"  Done.  ","route":" /drafts ","calls":[{"key":"drafts.list[7]","op":"press","args":{}}],"expiresAt":5,"id":"h1","v":1}`, ""},
		{`{"message":"x","calls":[{"node":"drafts.list[7]","op":"press"}]}`, ""},
		{`{"message":"x","calls":null}`, ""},
		{`"hi"`, "A handoff is an object: { message, route?, calls? }"},
		{`[]`, "A handoff is an object: { message, route?, calls? }"},
		{`null`, "A handoff is an object: { message, route?, calls? }"},
		{`{"message":"x","v":2}`, "Unknown handoff version 2"},
		{`{"message":"x","v":null}`, "Unknown handoff version null"},
		{`{"message":"x","v":"1"}`, "Unknown handoff version 1"},
		{`{}`, "Say what you did in message: the user reads it"},
		{`{"message":" \n\t "}`, "Say what you did in message: the user reads it"},
		{`{"message":5}`, "Say what you did in message: the user reads it"},
		{`{"message":"` + strings.Repeat("x", 500) + `"}`, ""},
		{`{"message":"` + strings.Repeat("x", 501) + `"}`, "message is too long (501 characters, at most 500)"},
		// (an emoji is two characters to JavaScript)
		{`{"message":"` + strings.Repeat("😀", 251) + `"}`, "message is too long (502 characters, at most 500)"},
		{`{"message":"x","route":"back"}`, "route is a route of the app (e.g. /drafts), or left out"},
		{`{"message":"x","route":" "}`, "route is a route of the app (e.g. /drafts), or left out"},
		{`{"message":"x","route":null}`, "route is a route of the app (e.g. /drafts), or left out"},
		{`{"message":"x","route":3}`, "route is a route of the app (e.g. /drafts), or left out"},
		{`{"message":"x","expiresAt":"soon"}`, "expiresAt is a time in ms"},
		{`{"message":"x","id":3}`, "id is a string"},
		{`{"message":"x","calls":{}}`, "calls is a list of { key, op, args? }"},
		{`{"message":"x","calls":` + calls(20) + `}`, ""},
		{`{"message":"x","calls":` + calls(21) + `}`, "Too many calls (21, at most 20): take the user to the result, no more"},
		{`{"message":"x","calls":[{"op":"press"}]}`, "calls[0] is not { key, op, args? }"},
		{`{"message":"x","calls":[{"key":"a","op":"press"},{"key":"","op":"press"}]}`, "calls[1] is not { key, op, args? }"},
		{`{"message":"x","calls":[{"key":"a"}]}`, "calls[0] is not { key, op, args? }"},
		{`{"message":"x","calls":["a"]}`, "calls[0] is not { key, op, args? }"},
		{`{"message":"x","calls":[{"key":"w4","op":"press"}]}`, "calls[0]: w4 is an id from a look, gone by the time the user comes back: use the control's key"},
		{`{"message":"x","calls":[{"key":"app","op":"read"}]}`, "calls[0]: app is an id from a look, gone by the time the user comes back: use the control's key"},
		{`{"message":"x","calls":[{"key":"behind-2","op":"read"}]}`, "calls[0]: behind-2 is an id from a look, gone by the time the user comes back: use the control's key"},
		{`{"message":"x","calls":[{"key":"peek:n3","op":"read"}]}`, "calls[0]: peek:n3 is an id from a look, gone by the time the user comes back: use the control's key"},
		{`{"message":"x","calls":[{"key":"n12x","op":"read"},{"key":"apps","op":"read"},{"key":"w","op":"read"}]}`, ""},
		{`{"message":"x","calls":[{"key":"a","op":"press","args":[1]}]}`, "calls[0].args is an object"},
		{`{"message":"x","calls":[{"key":"a","op":"press","args":null}]}`, "calls[0].args is an object"},
	}
	for _, c := range cases {
		if got := HandoffProblem(decode(t, c.in)); got != c.want {
			t.Errorf("HandoffProblem(%.80s) = %q, want %q", c.in, got, c.want)
		}
	}
	// Go values are taken as their JSON
	if got := HandoffProblem(map[string]any{"message": "x", "calls": []map[string]any{{"key": "a", "op": "press"}}, "expiresAt": 10}); got != "" {
		t.Errorf("Go values: %q", got)
	}
}

func TestParseHandoff(t *testing.T) {
	h := ParseHandoff(decode(t, `{"message":"  Done. ","route":" /drafts ","calls":[{"node":"drafts.list[7]","op":"press","args":{}},{"key":"x","op":"read"}],"expiresAt":2000,"id":"h1"}`), 1000)
	if h == nil {
		t.Fatal("nil")
	}
	want := `{"v":1,"message":"Done.","route":"/drafts","calls":[{"key":"drafts.list[7]","op":"press","args":{}},{"key":"x","op":"read"}],"expiresAt":2000,"id":"h1"}`
	if got := jsonString(t, h); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if ParseHandoff(decode(t, `{"message":"x","expiresAt":1000}`), 1000) != nil {
		t.Error("expired at its time")
	}
	if ParseHandoff(decode(t, `{"message":"x","calls":[{"key":"w4","op":"press"}]}`), 0) != nil {
		t.Error("a look id")
	}
	if h := ParseHandoff(decode(t, `{"message":"x"}`), 1<<62); h == nil || h.ExpiresAt != 0 || h.Calls == nil || jsonString(t, h) != `{"v":1,"message":"x","calls":[]}` {
		t.Errorf("no expiry: %+v", h)
	}
	if HandoffExpired(&Handoff{}, 1<<62) || !HandoffExpired(&Handoff{ExpiresAt: 5}, 5) || HandoffExpired(&Handoff{ExpiresAt: 6}, 5) {
		t.Error("HandoffExpired")
	}
	var back Handoff
	if err := json.Unmarshal([]byte(want), &back); err != nil || !reflect.DeepEqual(back, *ParseHandoff(decode(t, want), 0)) {
		t.Errorf("unmarshal: %+v %v", back, err)
	}
}

func TestMatchRoute(t *testing.T) {
	cases := []struct {
		pattern, route string
		want           string // params as JSON; "null" for no match
	}{
		{"/settings/:tab", "/settings/ai", `{"tab":"ai"}`},
		{"/settings/:tab", "/settings/ai/", `{"tab":"ai"}`},
		{"/settings/:tab", "/settings/ai?x=1#top", `{"tab":"ai"}`},
		{"/settings/:tab", "/settings", `null`},
		{"/settings/:tab", "/settings/ai/more", `null`},
		{"/settings/:tab", "/other/ai", `null`},
		{"/mail/:box/:id", "/mail/inbox/a%20b", `{"box":"inbox","id":"a b"}`},
		{"/drafts", "/drafts", `{}`},
		{"/", "/", `{}`},
		{"/files/*", "/files", `{}`},
		{"/files/*", "/files/a/b/c", `{}`},
		{"/files/:dir/*", "/files", `null`},
		{"/files/:dir/*", "/files/docs/x", `{"dir":"docs"}`},
		{"/mail/:box", "/mail/%zz", `null`},
		{"/mail/:box", "/mail/%C3", `null`},
	}
	for _, c := range cases {
		got := MatchRoute(c.pattern, c.route)
		s := "null"
		if got != nil {
			s = jsonString(t, got)
		}
		if s != c.want {
			t.Errorf("MatchRoute(%s, %s) = %s, want %s", c.pattern, c.route, s, c.want)
		}
	}
}

func TestFindRoute(t *testing.T) {
	routes := []RouteSpec{{Path: "/mail/:box"}, {Path: "/mail/drafts"}, {Path: "/message/:id"}, {Path: "/*"}}
	for route, want := range map[string]string{"/mail/drafts": "/mail/drafts", "/elsewhere/x": "/*", "/": "/*",
		// (a catch-all only when nothing else matches)
		"/mail/inbox": "/mail/:box", "/message/4": "/message/:id"} {
		m := FindRoute(routes, route)
		if m == nil || m.Spec.Path != want {
			t.Errorf("FindRoute(%s) = %+v, want %s", route, m, want)
		}
	}
	if FindRoute(routes[:3], "/nowhere") != nil {
		t.Error("/nowhere matched")
	}
	if m := FindRoute(routes[:3], "/mail/inbox"); m.Spec.Path != "/mail/:box" || jsonString(t, m.Params) != `{"box":"inbox"}` {
		t.Errorf("params %v", m.Params)
	}
}

func TestFindRouteRanking(t *testing.T) {
	routes := []RouteSpec{{Path: "/*"}, {Path: "/mail/:box"}, {Path: "/:section/:page"}, {Path: "/mail/inbox"}, {Path: "/mail/*"}}
	for route, want := range map[string]string{"/mail/inbox": "/mail/inbox", "/mail/archive": "/mail/:box",
		"/settings/ai": "/:section/:page", "/mail/a/b": "/mail/*", "/x": "/*"} {
		m := FindRoute(routes, route)
		if m == nil || m.Spec.Path != want {
			t.Errorf("FindRoute(%s) = %+v, want %s", route, m, want)
		}
	}
	if m := FindRoute(routes, "/mail/archive"); jsonString(t, m.Params) != `{"box":"archive"}` {
		t.Errorf("params %v", m.Params)
	}
	if m := FindRoute(routes[1:3], "/mail/%zz"); m != nil {
		t.Errorf("/mail/%%zz matched %+v", m)
	}
}

func TestIsImage(t *testing.T) {
	for in, want := range map[string]bool{
		`{"type":"image","mime":"image/png","data":"AA"}`: true,
		`{"type":"image","mime":"image/png"}`:             true,
		`{"type":"image"}`:                                false,
		`{"type":"image","mime":3}`:                       false,
		`{"type":"text","mime":"image/png"}`:              false,
		`"image"`:                                         false,
		`null`:                                            false,
	} {
		if got := IsImage(json.RawMessage(in)); got != want {
			t.Errorf("IsImage(%s) = %v", in, got)
		}
	}
	if !IsImage(map[string]any{"type": "image", "mime": "image/jpeg"}) {
		t.Error("IsImage(map)")
	}
}
