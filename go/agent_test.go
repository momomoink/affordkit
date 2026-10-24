package affordkit

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func ctxOf(t *testing.T, s string) *AffordContext {
	t.Helper()
	var c AffordContext
	if err := json.Unmarshal([]byte(s), &c); err != nil {
		t.Fatalf("%s: %v", s, err)
	}
	return &c
}

func nodeOf(t *testing.T, s string) *AffordNode {
	t.Helper()
	var n AffordNode
	if err := json.Unmarshal([]byte(s), &n); err != nil {
		t.Fatalf("%s: %v", s, err)
	}
	return &n
}

func TestNodeLine(t *testing.T) {
	cases := []struct{ node, want string }{
		{`{"id":"w1","role":"button","name":"Send","ops":[{"name":"press","policy":"deny"}],"key":"compose.send"}`, `[w1 key=compose.send] button "Send" — press(deny)`},
		{`{"id":"w2","role":"heading","name":"Inbox","value":"Inbox","ops":[]}`, `[w2] heading "Inbox"`},
		{`{"id":"w3","role":"text","name":"","value":"He said \"hi\" <b>","ops":[{"name":"read","policy":"allow"}]}`, `[w3] text = "He said \"hi\" <b>" — read`},
		// (a value that isn't a string, against the type, is still shown as JSON, keys in order)
		{`{"id":"w4","role":"text","name":"x","value":{"b":1.0,"a":[true]},"ops":[]}`, `[w4] text "x" = {"b":1,"a":[true]}`},
		{`{"id":"w5","role":"textbox","name":"Body","state":{"length":12.0,"focused":true,"filled":false,"mode":"rich"},"description":"The mail","ops":[{"name":"write","policy":"confirm"},{"name":"clear","policy":"allow"}]}`, `[w5] textbox "Body" (length: 12, focused, filled: false, mode: rich) — The mail — write(confirm), clear`},
		{`{"id":"c","role":"container","name":"Inbox","key":"mail.list","state":{"busy":true,"count":1,"kind":"grid","first":0,"last":0},"ops":[]}`, `[c key=mail.list] container "Inbox" (grid) 1 entry, showing 0–0 (entry keys: mail.list[<id>]) (busy)`},
		{`{"id":"c","role":"container","name":"","state":{"first":3},"ops":[]}`, `[c] container, showing 3–undefined`},
		{`{"id":"c","role":"container","name":"T","state":{"count":"many","kind":""},"ops":[]}`, `[c] container "T"`},
		{`{"id":"s","role":"switch","name":"On","state":{"2":true,"1":"a"},"ops":[]}`, `[s] switch "On" (1: a, 2)`},
	}
	for _, c := range cases {
		if got := nodeLine(nodeOf(t, c.node)); got != c.want {
			t.Errorf("nodeLine:\n got  %s\n want %s", got, c.want)
		}
	}
}

func TestDescribe(t *testing.T) {
	ctx := ctxOf(t, `{"protocol":1,
		"route":{"current":"/settings/ai","pattern":"/settings/:tab","params":{"tab":"ai","x":"1"},"canGoBack":true,
			"routes":[{"path":"/settings/:tab","description":"Settings","params":{"tab":{"values":["ai","mail"],"description":"which page"}}},{"path":"/","description":"Home","params":{"q":{"values":[]}}}]},
		"tools":[{"name":"t1","description":"One","policy":"allow"},{"name":"t2","description":"Two","policy":"deny"}],
		"root":{"id":"app","role":"app","name":"","ops":[],"children":[
			{"id":"c","role":"container","name":"List","key":"l","state":{"count":312.0,"first":0,"last":1},"ops":[{"name":"items","policy":"allow"}],
			 "preview":[{"key":"l[1]","id":"1","index":0,"name":"Ünï \"q\"","description":"d"},{"id":"2","name":"B"}]}]}}`)
	want := strings.Join([]string{
		`Route: /settings/ai = /settings/:tab (tab=ai, x=1) — can go back`,
		`Routes:`,
		`  /settings/:tab — Settings; :tab ∈ {ai, mail} (which page)`,
		`  / — Home; :q ∈ {}`,
		`Tools: t1 — One; t2(deny) — Two`,
		`[app] app`,
		`  [c key=l] container "List" 312 entries, showing 0–1 (entry keys: l[<id>]) — items`,
		`    · [l[1]] #0 "Ünï \"q\"" — d`,
		`    · [2] "B"`,
		`    · … 310 more; op item fetches an entry's controls, items pages through them`,
	}, "\n")
	if got := Describe(ctx, DescribeOptions{}); got != want {
		t.Errorf("Describe:\n--- got\n%s\n--- want\n%s", got, want)
	}
	// Route the same as its pattern, no back, no tools
	ctx2 := ctxOf(t, `{"protocol":1,"route":{"current":"/drafts","pattern":"/drafts","routes":[]},"tools":[],"root":{"id":"app","role":"app","name":"Mail","ops":[]}}`)
	if got := Describe(ctx2, DescribeOptions{}); got != "Route: /drafts\n[app] app \"Mail\"" {
		t.Errorf("Describe 2: %q", got)
	}
}

func TestTreeLinesBudget(t *testing.T) {
	root := nodeOf(t, `{"id":"a","role":"app","name":"","ops":[],"children":[{"id":"b","role":"region","name":"","ops":[],"children":[{"id":"c","role":"text","name":"","ops":[]},{"id":"d","role":"text","name":"","ops":[]}]},{"id":"e","role":"text","name":"","ops":[]}]}`)
	if got := strings.Join(treeLines(root, 2), "\n"); got != "[a] app\n  [b] region\n… 3 more nodes" {
		t.Errorf("budget 2:\n%s", got)
	}
	if got := strings.Join(treeLines(root, 5), "\n"); strings.Contains(got, "more nodes") {
		t.Errorf("budget 5:\n%s", got)
	}
}

// A screen of n buttons, b0..b(n-1), with keys.
func buttons(t *testing.T, ids ...string) *AffordContext {
	var kids []string
	for _, id := range ids {
		kids = append(kids, fmt.Sprintf(`{"id":"%s","key":"k.%s","role":"button","name":"%s","ops":[{"name":"press","policy":"allow"}]}`, id, id, id))
	}
	return ctxOf(t, `{"protocol":1,"tools":[],"root":{"id":"app","role":"app","name":"","ops":[],"children":[`+strings.Join(kids, ",")+`]}}`)
}

func seq(prefix string, from, to int) []string {
	var out []string
	for i := from; i < to; i++ {
		out = append(out, fmt.Sprintf("%s%d", prefix, i))
	}
	return out
}

func TestDescribeChangeWholeScreenThreshold(t *testing.T) {
	isWhole := func(s string) bool { return strings.HasPrefix(s, "The screen now:") }
	// 20 nodes after (19 buttons + app): more than max(4, 10) came and went is another page
	before := buttons(t, seq("b", 0, 19)...)
	// 5 went, 5 came: 10, not more than 10
	after := buttons(t, append(seq("b", 0, 14), seq("n", 0, 5)...)...)
	if got := DescribeChange(before, after, ChangeOptions{}); isWhole(got) {
		t.Errorf("10 of 20 is not the whole screen:\n%s", got)
	}
	// 5 went, 6 came: 11, more than 10.5
	after = buttons(t, append(seq("b", 0, 14), seq("n", 0, 6)...)...)
	if got := DescribeChange(before, after, ChangeOptions{}); !isWhole(got) {
		t.Errorf("11 of 21 is the whole screen:\n%s", got)
	}
	// A small screen: up to 4 changes are always told one by one
	small := buttons(t, "a", "b")
	if got := DescribeChange(small, buttons(t, "c", "d"), ChangeOptions{}); isWhole(got) {
		t.Errorf("4 changes on a small screen:\n%s", got)
	}
	if got := DescribeChange(small, buttons(t, "c", "d", "e"), ChangeOptions{}); !isWhole(got) {
		t.Errorf("5 changes on a small screen:\n%s", got)
	}
	// WholeOver moves the line
	if got := DescribeChange(before, buttons(t, append(seq("b", 0, 14), seq("n", 0, 5)...)...), ChangeOptions{WholeOver: 0.2}); !isWhole(got) {
		t.Errorf("WholeOver 0.2:\n%s", got)
	}
}

func TestDescribeChangeLines(t *testing.T) {
	before := ctxOf(t, `{"protocol":1,"route":{"current":"/a","routes":[]},"tools":[],"root":{"id":"app","role":"app","name":"","ops":[],"children":[
		{"id":"r","role":"region","name":"Form","key":"form","ops":[],"children":[{"id":"x","role":"textbox","name":"X","state":{"length":0},"ops":[]}]},
		{"id":"gone","role":"button","name":"Gone","ops":[]}]}}`)
	after := ctxOf(t, `{"protocol":1,"route":{"current":"/b","canGoBack":true,"routes":[]},"tools":[],"root":{"id":"app","role":"app","name":"","ops":[],"children":[
		{"id":"r","role":"region","name":"Form","key":"form","ops":[],"children":[{"id":"x","role":"textbox","name":"X","state":{"length":3},"ops":[]},{"id":"y","role":"button","name":"","ops":[]}]}]}}`)
	want := strings.Join([]string{
		"The screen changed:",
		"Now at /b (was /a) — can go back.",
		"+ [y] button (in form \"Form\")",
		"- [gone] button \"Gone\"",
		"~ [x] textbox \"X\" (length: 3)",
	}, "\n")
	if got := DescribeChange(before, after, ChangeOptions{}); got != want {
		t.Errorf("DescribeChange:\n--- got\n%s\n--- want\n%s", got, want)
	}
	if got := DescribeChange(after, after, ChangeOptions{}); got != "The screen did not change." {
		t.Errorf("no change: %q", got)
	}
}

func TestDescribePageItemsImage(t *testing.T) {
	seen := 1792711772948.0
	root := nodeOf(t, `{"id":"app","role":"app","name":"","ops":[]}`)
	if got := DescribePage(&PagePeek{Route: "/drafts", Source: "seen", SeenAt: &seen, Root: root}, DescribeOptions{}); got != "Page /drafts — as it was when it last showed (2026-10-22T23:29:32.948Z)\n(Peek ids cannot be acted on: navigate there, then act by key, or look again for live ids.)\n[app] app" {
		t.Errorf("seen page: %q", got)
	}
	if got := DescribePage(&PagePeek{Route: "/a/1", Pattern: "/a/:id", Source: "declared", Description: "An a"}, DescribeOptions{}); got != "Page /a/1 = /a/:id — never seen: only what the route says. An a" {
		t.Errorf("declared: %q", got)
	}
	if got := DescribePage(&PagePeek{Route: "/a", Source: "live", Root: root}, DescribeOptions{}); got != "Page /a — showing now\n[app] app" {
		t.Errorf("live: %q", got)
	}
	count, idx := 7.0, 2.0
	if got := DescribeItems(&ItemsPage{Offset: 2, Count: &count, Items: []ItemSummary{{ID: "a", Index: &idx, Name: json.RawMessage(`"A"`)}}}); got != "Items 2–2 of 7:\n  [a] #2 \"A\"" {
		t.Errorf("items: %q", got)
	}
	if got := DescribeItems(&ItemsPage{Items: []ItemSummary{}}); got != "No items." {
		t.Errorf("no items: %q", got)
	}
	if got := DescribeItems(&ItemsPage{Offset: 9, Count: &count}); got != "No items from 9 (7 in all)." {
		t.Errorf("no items from: %q", got)
	}
	if got := DescribeItem(&ItemTree{ID: "4", Key: "l[4]", Source: "preview", Root: *root}, DescribeOptions{}); got != "Entry l[4] — built off screen: its ids cannot be acted on, act by key (that brings it in):\n[app] app" {
		t.Errorf("item: %q", got)
	}
	for _, c := range []struct {
		img  ImageValue
		want string
	}{
		{ImageValue{Mime: "image/png", Data: "AA", Width: 40, Height: 20}, "(A picture, 40×20 image/png: attached.)"},
		{ImageValue{Mime: "image/png", Data: "AA", Width: 40}, "(A picture, image/png: attached.)"},
		{ImageValue{Mime: "image/png", URL: "https://x/a.png", Width: 1.5, Height: 2}, "(A picture at https://x/a.png, 1.5×2: it could not be read here.)"},
		{ImageValue{Mime: "image/png"}, "(A picture at an unknown place: it could not be read here.)"},
	} {
		if got := DescribeImage(&c.img); got != c.want {
			t.Errorf("image: %q, want %q", got, c.want)
		}
	}
}

func TestDescribeResult(t *testing.T) {
	cases := []struct{ result, want string }{
		{`{"call":{"node":"a","op":"read"},"ok":true}`, "Done."},
		{`{"call":{"node":"a","op":"read"},"ok":true,"value":"text"}`, "text"},
		{`{"call":{"node":"a","op":"read"},"ok":true,"value":""}`, ""},
		{`{"call":{"node":"a","op":"read"},"ok":true,"value":null}`, "null"},
		{`{"call":{"tool":"t"},"ok":true,"value":{"z":1,"a":2.50,"u":"<é>"}}`, `{"z":1,"a":2.5,"u":"<é>"}`},
		{`{"call":{"tool":"t"},"ok":true,"value":312.0}`, "312"},
		{`{"call":{"navigate":"/a"},"ok":true}`, "Now at /a."},
		{`{"call":{"navigate":"/a"},"ok":true,"value":"/b"}`, "Now at /b."},
		{`{"call":{"node":"l","op":"items"},"ok":true,"value":{"offset":0,"items":[{"id":"1","name":"One"}]}}`, "Items 0–0:\n  [1] \"One\""},
		{`{"call":{"node":"l","op":"items"},"ok":true,"value":{"offset":0}}`, `{"offset":0}`},
		{`{"call":{"node":"l","op":"item"},"ok":true,"value":{"id":"1","source":"live","root":{"id":"e1","role":"listitem","name":"One","ops":[]}}}`, "Entry 1:\n[e1] listitem \"One\""},
		{`{"call":{"node":"w","op":"view"},"ok":true,"value":{"type":"image","mime":"image/png","data":"AA"}}`, "(A picture, image/png: attached.)"},
		{`{"call":{"node":"a","op":"press"},"ok":false,"error":"No"}`, "Failed: No"},
		{`{"call":{"node":"a","op":"press"},"ok":false,"code":"denied","error":"No"}`, "Failed (denied): No"},
		{`{"call":{"node":"a","op":"press"},"ok":false,"needsConfirm":true,"code":"needs_confirm","error":"Yes?"}`, "Waiting: Yes?"},
	}
	for _, c := range cases {
		var r CallResult
		if err := json.Unmarshal([]byte(c.result), &r); err != nil {
			t.Fatal(err)
		}
		if got := DescribeResult(&r); got != c.want {
			t.Errorf("DescribeResult(%s) = %q, want %q", c.result, got, c.want)
		}
	}
}

func TestDescribeUserActions(t *testing.T) {
	if DescribeUserActions(nil) != "" {
		t.Error("none")
	}
	var actions []UserAction
	_ = json.Unmarshal([]byte(`[{"at":1,"op":"navigate"},{"at":2,"op":"back","route":""},{"at":3,"op":"write","node":{"id":"w","role":"textbox","name":""},"value":""},{"at":4,"op":"zoom","node":{"id":"m","key":"map","role":"other","name":"Map"}},{"at":5,"op":"zoom"}]`), &actions)
	want := strings.Join([]string{
		"Meanwhile the user did this themselves:",
		"- went to another page",
		"- went back",
		`- typed "" into [w] textbox`,
		`- zoom [map] other "Map"`,
		"- zoom",
		"The screen below is as it is after that. Work with it: don't undo what they did; if it changes what they want, or gets in the way of the goal, stop and ask them.",
	}, "\n")
	if got := DescribeUserActions(actions); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestAgentToolsSchemas(t *testing.T) {
	want := []string{"ui_look", "ui_act", "ui_tool", "ui_navigate", "ui_peek", "ui_handoff"}
	if got := names(AgentTools); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("names %v", got)
	}
	for _, tool := range AgentTools {
		var m map[string]any
		if err := json.Unmarshal(tool.InputSchema, &m); err != nil || m["type"] != "object" {
			t.Errorf("%s schema: %v", tool.Name, err)
		}
	}
}
