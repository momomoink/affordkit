package affordkit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const smallScreen = `{"protocol":1,"route":{"current":"/a","routes":[{"path":"/a","description":"A"},{"path":"/drafts","description":"Drafts"}]},
	"tools":[{"name":"t","description":"T","policy":"allow"}],
	"root":{"id":"app","role":"app","name":"","ops":[],"children":[{"id":"w1","key":"ok","role":"button","name":"OK","ops":[{"name":"press","policy":"allow"}]}]}}`

func answerWith(t *testing.T, ctx *AffordContext, results string) func(context.Context, UiRequest) (UiAnswer, error) {
	return func(context.Context, UiRequest) (UiAnswer, error) {
		a := UiAnswer{Context: ctx}
		if results != "" {
			if err := json.Unmarshal([]byte(results), &a.Results); err != nil {
				t.Fatal(err)
			}
		}
		return a, nil
	}
}

func TestRemoteTimeout(t *testing.T) {
	var cancelled atomic.Bool
	ui := NewRemote(RemoteOptions{
		Timeout: 30 * time.Millisecond,
		Send: func(ctx context.Context, req UiRequest) (UiAnswer, error) {
			<-ctx.Done()
			cancelled.Store(true)
			return UiAnswer{}, ctx.Err()
		},
	})
	start := time.Now()
	a := ui.Handle(context.Background(), "ui_look", nil)
	if took := time.Since(start); took > 2*time.Second || took < 30*time.Millisecond {
		t.Errorf("took %v", took)
	}
	want := "Failed (timeout): The app did not answer in time (it may be in the background): look again later, or do it another way"
	if !a.IsError || a.Code != CodeTimeout || a.Text != want {
		t.Errorf("timeout answer %+v", a)
	}
	// (Send's context is done once its answer is no longer wanted)
	deadline := time.Now().Add(time.Second)
	for !cancelled.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !cancelled.Load() {
		t.Error("Send's context was not cancelled")
	}
	if ui.Screen() != nil {
		t.Error("a timeout left a screen")
	}
}

func TestRemoteSendFailures(t *testing.T) {
	cases := []struct {
		send func(context.Context, UiRequest) (UiAnswer, error)
		text string
		code ErrorCode
	}{
		{func(context.Context, UiRequest) (UiAnswer, error) { return UiAnswer{}, errors.New("closed") }, "Failed (unavailable): closed", CodeUnavailable},
		{func(context.Context, UiRequest) (UiAnswer, error) {
			return UiAnswer{}, fmt.Errorf("sending: %w", &AffordError{Code: CodeUnreachable, Message: "covered"})
		}, "Failed (unreachable): sending: covered", CodeUnreachable},
		{func(context.Context, UiRequest) (UiAnswer, error) { panic("boom") }, "Failed (unavailable): boom", CodeUnavailable},
		{func(context.Context, UiRequest) (UiAnswer, error) {
			return UiAnswer{Error: "loading", Code: CodeUnavailable}, nil
		}, "Failed (unavailable): loading", CodeUnavailable},
		{func(context.Context, UiRequest) (UiAnswer, error) { return UiAnswer{Error: "broke"}, nil }, "Failed (unavailable): broke", CodeUnavailable},
		{func(context.Context, UiRequest) (UiAnswer, error) { return UiAnswer{}, nil }, "Failed (unavailable): The app gave no screen", CodeUnavailable},
		{nil, "Failed (unavailable): No way to reach the app (RemoteOptions.Send)", CodeUnavailable},
	}
	for i, c := range cases {
		a := NewRemote(RemoteOptions{Send: c.send}).Handle(context.Background(), "ui_act", map[string]any{"node": "w1", "op": "press"})
		if a.Text != c.text || a.Code != c.code || !a.IsError {
			t.Errorf("case %d: %+v", i, a)
		}
	}
	// A cancelled context of the caller's: unavailable, not timeout
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a := NewRemote(RemoteOptions{Send: func(ctx context.Context, _ UiRequest) (UiAnswer, error) { <-ctx.Done(); return UiAnswer{}, ctx.Err() }}).Handle(ctx, "ui_look", nil)
	if a.Code != CodeUnavailable {
		t.Errorf("cancelled: %+v", a)
	}
}

func TestRemoteTools(t *testing.T) {
	screen := ctxOf(t, smallScreen)
	noTools := ctxOf(t, smallScreen)
	noTools.Tools = []ToolSpec{}
	ui := NewRemote(RemoteOptions{Send: answerWith(t, noTools, "")})
	if got := strings.Join(names(ui.Tools()), ","); got != "ui_look,ui_act,ui_tool,ui_navigate,ui_peek" {
		t.Errorf("nothing seen: %s", got)
	}
	ui.Seen(noTools)
	if got := strings.Join(names(ui.Tools()), ","); got != "ui_look,ui_act,ui_navigate,ui_peek" || ui.Has("ui_tool") || !ui.Has("ui_look") {
		t.Errorf("an app without tools: %s", got)
	}
	ui.Seen(screen)
	if !ui.Has("ui_tool") || ui.Has("ui_handoff") || ui.Has("ui_fly") {
		t.Error("an app with tools")
	}
	withHost := NewRemote(RemoteOptions{Send: answerWith(t, screen, ""), OnHandoff: func(context.Context, Handoff) (string, error) { return "", nil }})
	if !withHost.Has("ui_handoff") {
		t.Error("ui_handoff with a host")
	}
	only := NewRemote(RemoteOptions{Tools: []string{"ui_look", "ui_handoff", "ui_tool"}})
	only.Seen(noTools)
	if got := strings.Join(names(only.Tools()), ","); got != "ui_look,ui_tool" {
		t.Errorf("Tools option: %s", got)
	}
	if got := NewRemote(RemoteOptions{Tools: []string{}}).Tools(); len(got) != 0 {
		t.Errorf("no tools: %v", got)
	}
}

func TestRemoteAway(t *testing.T) {
	sent := false
	send := func(context.Context, UiRequest) (UiAnswer, error) { sent = true; return UiAnswer{}, nil }
	away := func() bool { return false }
	a := NewRemote(RemoteOptions{Send: send, Present: away}).Handle(context.Background(), "ui_tool", map[string]any{"name": "t"})
	if a.Code != CodeAway || a.Text != "Failed (away): The user is not in the app right now (it is in the background): the screen can't be looked at or worked. Use your other tools." {
		t.Errorf("away: %+v", a)
	}
	a = NewRemote(RemoteOptions{Send: send, Present: away, OnHandoff: func(context.Context, Handoff) (string, error) { return "", nil }}).Handle(context.Background(), "ui_look", nil)
	if !strings.HasSuffix(a.Text, "Use your other tools, and leave a handoff (ui_handoff) for when they come back.") {
		t.Errorf("away with a host: %q", a.Text)
	}
	// Not one of the tools: not away, bad_args
	a = NewRemote(RemoteOptions{Send: send, Present: away}).Handle(context.Background(), "ui_fly", nil)
	if a.Code != CodeBadArgs || a.Text != "Failed (bad_args): Not an AffordKit tool: ui_fly" {
		t.Errorf("ui_fly: %+v", a)
	}
	if sent {
		t.Error("asked the app while away")
	}
}

func TestRemoteHandleRequestsAndScreen(t *testing.T) {
	screen := ctxOf(t, smallScreen)
	var reqs []string
	ui := NewRemote(RemoteOptions{Send: func(ctx context.Context, req UiRequest) (UiAnswer, error) {
		reqs = append(reqs, jsonString(t, req))
		a := UiAnswer{Context: screen}
		if len(req.Calls) > 0 {
			a.Results = []CallResult{{Call: req.Calls[0], OK: true, Value: json.RawMessage(`{"type":"image","mime":"image/png","data":"QQ=="}`)}}
		}
		return a, nil
	}})
	a := ui.Handle(context.Background(), "ui_look", map[string]any{"picture": true})
	if !strings.HasSuffix(a.Text, "\n\n(No picture: this app can't take one.)") || a.Images != nil || ui.Screen() != screen || a.Context != screen {
		t.Errorf("look: %+v", a)
	}
	a = ui.Handle(context.Background(), "ui_act", map[string]any{"node": "ok", "op": "view"})
	if a.Text != "(A picture, image/png: attached.)\n\nThe screen did not change." || !reflect.DeepEqual(a.Images, []Image{{"image/png", "QQ=="}}) {
		t.Errorf("view: %+v", a)
	}
	ui.Handle(context.Background(), "ui_peek", map[string]any{"route": "/drafts"})
	want := []string{`{"look":true,"picture":true}`, `{"calls":[{"node":"ok","op":"view","args":{}}]}`, `{"calls":[{"peek":"/drafts"}]}`}
	if !reflect.DeepEqual(reqs, want) {
		t.Errorf("requests %v", reqs)
	}
	// Go values in the input are taken as their JSON
	ui.Handle(context.Background(), "ui_tool", map[string]any{"name": "t", "args": map[string]int{"n": 2}})
	if got := reqs[len(reqs)-1]; got != `{"calls":[{"tool":"t","args":{"n":2}}]}` {
		t.Errorf("Go values: %s", got)
	}
}

func TestRemoteHandoff(t *testing.T) {
	var got []Handoff
	host := func(ctx context.Context, h Handoff) (string, error) {
		got = append(got, h)
		if h.Message == "fail" {
			return "", &AffordError{Code: CodeUnavailable, Message: "No push token"}
		}
		if h.Message == "plain" {
			return "", errors.New("oops")
		}
		if h.Message == "panic" {
			panic("host down")
		}
		return "sent", nil
	}
	ui := NewRemote(RemoteOptions{OnHandoff: host, HandoffTTL: time.Hour})
	ui.Seen(ctxOf(t, smallScreen))
	before := time.Now().UnixMilli()
	a := ui.Handle(context.Background(), "ui_handoff", map[string]any{"message": " Done ", "route": "/drafts", "id": "mine", "expiresAt": 1, "calls": []any{map[string]any{"node": "drafts.list[1]", "op": "press"}}})
	if a.Text != "Handoff left: sent" || a.IsError {
		t.Errorf("left: %+v", a)
	}
	h := got[0]
	if h.ID != "" || h.Message != "Done" || h.Route != "/drafts" || len(h.Calls) != 1 || h.Calls[0].Key != "drafts.list[1]" {
		t.Errorf("handoff %+v", h)
	}
	if h.ExpiresAt < before+3600_000 || h.ExpiresAt > time.Now().UnixMilli()+3600_000 {
		t.Errorf("expiresAt %d", h.ExpiresAt)
	}
	for input, want := range map[string]string{
		`{"message":"x","route":"/nowhere"}`: "Failed (bad_args): No route /nowhere (the routes: /a, /drafts)",
		`{"message":"x","route":"back"}`:     "Failed (bad_args): route is a route of the app (e.g. /drafts), or left out",
		`{"message":"fail"}`:                 "Failed (unavailable): No push token",
		`{"message":"plain"}`:                "Failed (failed): oops",
		`{"message":"panic"}`:                "Failed (failed): host down",
		`{"message":"x","v":2}`:              "Handoff left: sent",
	} {
		if a := ui.Handle(context.Background(), "ui_handoff", decode(t, input).(map[string]any)); a.Text != want {
			t.Errorf("%s: %q, want %q", input, a.Text, want)
		}
	}
	// Without routes seen, any route goes
	free := NewRemote(RemoteOptions{OnHandoff: host})
	if a := free.Handle(context.Background(), "ui_handoff", map[string]any{"message": "x", "route": "/anything"}); a.IsError {
		t.Errorf("no routes seen: %+v", a)
	}
	if a := NewRemote(RemoteOptions{}).Handle(context.Background(), "ui_handoff", map[string]any{"message": "x"}); a.Text != "Failed (not_found): This app takes no handoffs" {
		t.Errorf("no host: %+v", a)
	}
	// An empty answer from the host
	quiet := NewRemote(RemoteOptions{OnHandoff: func(context.Context, Handoff) (string, error) { return "", nil }})
	if a := quiet.Handle(context.Background(), "ui_handoff", map[string]any{"message": "x"}); a.Text != "Handoff left: the user gets it when they come back." {
		t.Errorf("quiet: %q", a.Text)
	}
}

func TestAdapters(t *testing.T) {
	screen := ctxOf(t, `{"protocol":1,"tools":[],"root":{"id":"app","role":"app","name":"A & <b>","ops":[]}}`)
	pic := NewRemote(RemoteOptions{Send: func(context.Context, UiRequest) (UiAnswer, error) {
		return UiAnswer{Context: screen, Picture: &ImageValue{Type: "image", Mime: "image/png", Data: "AAAA"}}, nil
	}})
	bad := NewRemote(RemoteOptions{Send: func(context.Context, UiRequest) (UiAnswer, error) {
		return UiAnswer{Error: "gone", Code: CodeUnavailable}, nil
	}})
	ctx := context.Background()
	text := "[app] app \"A & <b>\"\n\n(A picture of the screen is attached.)"
	check := func(name string, v any, want string) {
		t.Helper()
		if got := jsonString(t, v); got != want {
			t.Errorf("%s:\n got  %s\n want %s", name, got, want)
		}
	}
	q := jsQuote(text)
	check("anthropic", AnthropicResult(ctx, pic, AnthropicToolUse{ID: "t1", Name: "ui_look", Input: json.RawMessage(`{"picture":true}`)}),
		`{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":`+q+`},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}`)
	check("anthropic error", AnthropicResult(ctx, bad, AnthropicToolUse{ID: "t2", Name: "ui_look"}),
		`{"type":"tool_result","tool_use_id":"t2","content":"Failed (unavailable): gone","is_error":true}`)
	// (input that is not an object is taken as {}: no picture asked, the one the app sent still goes along)
	check("anthropic not an object", AnthropicResult(ctx, pic, AnthropicToolUse{ID: "t3", Name: "ui_look", Input: []byte(`[1]`)}),
		`{"type":"tool_result","tool_use_id":"t3","content":[{"type":"text","text":"[app] app \"A & <b>\""},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}`)
	check("openai", OpenAIResult(ctx, pic, OpenAIToolCall{ID: "c1", Function: OpenAICalledFunction{Name: "ui_look", Arguments: `{"picture":true}`}}),
		`{"role":"tool","tool_call_id":"c1","content":`+q+`}`)
	check("openai bad json", OpenAIResult(ctx, bad, OpenAIToolCall{ID: "c2", Function: OpenAICalledFunction{Name: "ui_look", Arguments: `{oops`}}),
		`{"role":"tool","tool_call_id":"c2","content":"Failed (unavailable): gone"}`)
	check("responses", OpenAIResponsesResult(ctx, bad, OpenAIFunctionCall{CallID: "f1", Name: "ui_look", Arguments: "null"}),
		`{"type":"function_call_output","call_id":"f1","output":"Failed (unavailable): gone"}`)
	mcp := MCPHandlers(pic)
	check("mcp call", mcp.Call(ctx, MCPCallRequest{Params: MCPCallParams{Name: "ui_look", Arguments: map[string]any{"picture": true}}}),
		`{"content":[{"type":"text","text":`+q+`},{"type":"image","data":"AAAA","mimeType":"image/png"}]}`)
	check("mcp error", MCPHandlers(bad).Call(ctx, MCPCallRequest{Params: MCPCallParams{Name: "ui_look"}}),
		`{"content":[{"type":"text","text":"Failed (unavailable): gone"}],"isError":true}`)

	tools := []AgentTool{AgentTools[2]}
	schema := `{"type":"object","properties":{"name":{"type":"string"},"args":{"type":"object"}},"required":["name"]}`
	desc := jsQuote(AgentTools[2].Description)
	check("anthropic tools", AnthropicTools(tools), `[{"name":"ui_tool","description":`+desc+`,"input_schema":`+schema+`}]`)
	check("openai tools", OpenAITools(tools), `[{"type":"function","function":{"name":"ui_tool","description":`+desc+`,"parameters":`+schema+`}}]`)
	check("responses tools", OpenAIResponsesTools(tools), `[{"type":"function","name":"ui_tool","description":`+desc+`,"parameters":`+schema+`}]`)
	only := NewRemote(RemoteOptions{Tools: []string{"ui_tool"}})
	check("mcp list", MCPHandlers(only).List(ctx), `{"tools":[{"name":"ui_tool","description":`+desc+`,"inputSchema":`+schema+`}]}`)

	runners := Runners(pic)
	// (the app was seen to have no tools of its own: no ui_tool)
	if len(runners) != 4 || runners[0].Name != "ui_look" {
		t.Fatalf("runners %v", runners)
	}
	if a := runners[0].Run(ctx, map[string]any{"picture": true}); a.Text != text || len(a.Images) != 1 {
		t.Errorf("runner: %+v", a)
	}
	check("runner json", runners[0], jsonString(t, AgentTools[0]))
}
