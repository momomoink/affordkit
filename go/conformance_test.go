package affordkit

// The agent side's conformance cases (conformance/remote.json, at the repository root), shared by every port: each case runs a
// Remote against an app that answers as scripted, and what it sent the app and what the agent got back must be exactly what the
// file says (the TypeScript reference wrote it: js/test/conformance.test.ts).

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
)

type confStep struct {
	Tool        string          `json:"tool"`
	Input       map[string]any  `json:"input"`
	Reply       json.RawMessage `json:"reply"`
	HandoffSays json.RawMessage `json:"handoffSays"`
}

type confCase struct {
	Name    string `json:"name"`
	Options struct {
		TimeoutMs float64  `json:"timeoutMs"`
		Screen    Screen   `json:"screen"`
		Tools     []string `json:"tools"`
		MaxNodes  int      `json:"maxNodes"`
		Present   *bool    `json:"present"`
		Handoff   bool     `json:"handoff"`
	} `json:"options"`
	Seen   json.RawMessage `json:"seen"`
	Steps  []confStep      `json:"steps"`
	Expect struct {
		ToolsBefore []string `json:"toolsBefore"`
		ToolsAfter  []string `json:"toolsAfter"`
		Steps       []any    `json:"steps"`
	} `json:"expect"`
}

type confFile struct {
	Version int                        `json:"version"`
	Cases   []confCase                 `json:"cases"`
	Shapes  map[string]json.RawMessage `json:"shapes"`
}

func loadConformance(t *testing.T) confFile {
	t.Helper()
	b, err := os.ReadFile("../conformance/remote.json")
	if err != nil {
		t.Fatalf("reading conformance/remote.json: %v", err)
	}
	var f confFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("parsing conformance/remote.json: %v", err)
	}
	return f
}

// asJSON is a value as JSON.parse(JSON.stringify(v)) would give it: for comparing.
func asJSON(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return out
}

// thrown is { throws, code? }: an *AffordError with that code, or a plain error without one.
func thrown(raw json.RawMessage) (error, bool) {
	var m struct {
		Throws *string   `json:"throws"`
		Code   ErrorCode `json:"code"`
	}
	if rawKind(raw) != '{' || json.Unmarshal(raw, &m) != nil || m.Throws == nil {
		return nil, false
	}
	if m.Code != "" {
		return &AffordError{Code: m.Code, Message: *m.Throws}, true
	}
	return errors.New(*m.Throws), true
}

func names(tools []AgentTool) []string {
	out := []string{}
	for _, t := range tools {
		out = append(out, t.Name)
	}
	return out
}

func runCase(t *testing.T, c confCase) {
	var step *confStep
	var rec map[string]any
	opts := RemoteOptions{
		Send: func(ctx context.Context, req UiRequest) (UiAnswer, error) {
			rec["request"] = asJSON(t, req)
			if step == nil || rawKind(step.Reply) == 0 {
				t.Errorf("step sent a request it has no reply for: %v", rec["request"])
				return UiAnswer{}, errors.New("no reply")
			}
			// (a reply that is not an object — the case of an answer that is none — is, in Go's typed Send, an empty answer)
			if r := bytes.TrimSpace(step.Reply); len(r) == 0 || r[0] != '{' {
				return UiAnswer{}, nil
			}
			var probe map[string]any
			_ = json.Unmarshal(step.Reply, &probe)
			if probe["never"] == true {
				<-ctx.Done()
				return UiAnswer{}, ctx.Err()
			}
			if err, ok := thrown(step.Reply); ok {
				return UiAnswer{}, err
			}
			var a UiAnswer
			if err := json.Unmarshal(step.Reply, &a); err != nil {
				t.Fatalf("reply: %v", err)
			}
			return a, nil
		},
		Screen:   c.Options.Screen,
		Tools:    c.Options.Tools,
		MaxNodes: c.Options.MaxNodes,
	}
	if c.Options.TimeoutMs > 0 {
		opts.Timeout = time.Duration(c.Options.TimeoutMs * float64(time.Millisecond))
	}
	if c.Options.Present != nil && !*c.Options.Present {
		opts.Present = func() bool { return false }
	}
	if c.Options.Handoff {
		opts.OnHandoff = func(ctx context.Context, h Handoff) (string, error) {
			m := asJSON(t, h).(map[string]any)
			if _, ok := m["expiresAt"].(float64); !ok {
				t.Errorf("handoff expiresAt is not a number: %v", m["expiresAt"])
			}
			delete(m, "expiresAt")
			rec["handoff"] = m
			if err, ok := thrown(step.HandoffSays); ok {
				return "", err
			}
			s, _ := rawString(step.HandoffSays)
			return s, nil
		}
	}
	ui := NewRemote(opts)
	if rawKind(c.Seen) == '{' {
		var seen AffordContext
		if err := json.Unmarshal(c.Seen, &seen); err != nil {
			t.Fatalf("seen: %v", err)
		}
		ui.Seen(&seen)
	} else {
		ui.Seen(nil)
	}
	if got := names(ui.Tools()); !reflect.DeepEqual(got, c.Expect.ToolsBefore) {
		t.Errorf("toolsBefore:\n got  %v\n want %v", got, c.Expect.ToolsBefore)
	}
	if len(c.Steps) != len(c.Expect.Steps) {
		t.Fatalf("%d steps, %d expected", len(c.Steps), len(c.Expect.Steps))
	}
	for i := range c.Steps {
		step = &c.Steps[i]
		rec = map[string]any{}
		input := step.Input
		if input == nil {
			input = map[string]any{}
		}
		a := ui.Handle(context.Background(), step.Tool, input)
		rec["text"] = a.Text
		rec["isError"] = a.IsError
		if a.Code != "" {
			rec["code"] = string(a.Code)
		}
		if len(a.Images) > 0 {
			rec["images"] = a.Images
		}
		got := asJSON(t, rec)
		want := c.Expect.Steps[i]
		if !reflect.DeepEqual(got, want) {
			gm, _ := got.(map[string]any)
			wm, _ := want.(map[string]any)
			if gm != nil && wm != nil && gm["text"] != wm["text"] {
				t.Errorf("step %d (%s) text:\n--- got\n%v\n--- want\n%v", i, step.Tool, gm["text"], wm["text"])
			}
			gj, _ := json.MarshalIndent(got, "", "  ")
			wj, _ := json.MarshalIndent(want, "", "  ")
			t.Errorf("step %d (%s):\n--- got\n%s\n--- want\n%s", i, step.Tool, gj, wj)
		}
	}
	if got := names(ui.Tools()); !reflect.DeepEqual(got, c.Expect.ToolsAfter) {
		t.Errorf("toolsAfter:\n got  %v\n want %v", got, c.Expect.ToolsAfter)
	}
}

func TestConformanceCases(t *testing.T) {
	f := loadConformance(t)
	if f.Version != 1 {
		t.Fatalf("conformance version %d, this port knows 1", f.Version)
	}
	if len(f.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range f.Cases {
		c := c
		t.Run(c.Name, func(t *testing.T) { runCase(t, c) })
	}
	t.Logf("%d conformance cases", len(f.Cases))
}

// The inbox screen the shapes' remote answers with: the first case's reply.
func inboxContext(t *testing.T, f confFile) *AffordContext {
	var reply struct {
		Context *AffordContext `json:"context"`
	}
	if err := json.Unmarshal(f.Cases[0].Steps[0].Reply, &reply); err != nil || reply.Context == nil {
		t.Fatalf("inbox: %v", err)
	}
	return reply.Context
}

func TestConformanceShapes(t *testing.T) {
	f := loadConformance(t)
	inbox := inboxContext(t, f)
	ctx := context.Background()
	answering := NewRemote(RemoteOptions{Send: func(context.Context, UiRequest) (UiAnswer, error) {
		return UiAnswer{Context: inbox, Picture: &ImageValue{Type: "image", Mime: "image/png", Data: "AAAA"}}, nil
	}})
	failing := NewRemote(RemoteOptions{Send: func(context.Context, UiRequest) (UiAnswer, error) {
		return UiAnswer{Error: "gone", Code: CodeUnavailable}, nil
	}})
	tools := answering.Tools()
	mcp := MCPHandlers(answering)
	got := map[string]any{
		"anthropicTools":        AnthropicTools(tools),
		"openaiTools":           OpenAITools(tools),
		"openaiResponsesTools":  OpenAIResponsesTools(tools),
		"mcpList":               mcp.List(ctx),
		"anthropicResult":       AnthropicResult(ctx, answering, AnthropicToolUse{ID: "toolu_1", Name: "ui_look", Input: map[string]any{"picture": true}}),
		"anthropicResultError":  AnthropicResult(ctx, failing, AnthropicToolUse{ID: "toolu_2", Name: "ui_look", Input: map[string]any{}}),
		"openaiResult":          OpenAIResult(ctx, answering, OpenAIToolCall{ID: "call_1", Function: OpenAICalledFunction{Name: "ui_look", Arguments: `{"picture":true}`}}),
		"openaiResultBadJson":   OpenAIResult(ctx, failing, OpenAIToolCall{ID: "call_2", Function: OpenAICalledFunction{Name: "ui_look", Arguments: `{oops`}}),
		"openaiResponsesResult": OpenAIResponsesResult(ctx, answering, OpenAIFunctionCall{CallID: "fc_1", Name: "ui_look", Arguments: ""}),
		"mcpCall":               mcp.Call(ctx, MCPCallRequest{Params: MCPCallParams{Name: "ui_look", Arguments: map[string]any{"picture": true}}}),
		"mcpCallError":          MCPHandlers(failing).Call(ctx, MCPCallRequest{Params: MCPCallParams{Name: "ui_look"}}),
	}
	if len(got) != len(f.Shapes) {
		t.Errorf("%d shapes here, %d in the file", len(got), len(f.Shapes))
	}
	for name, raw := range f.Shapes {
		g, ok := got[name]
		if !ok {
			t.Errorf("shape %s: not made here", name)
			continue
		}
		var want any
		if err := json.Unmarshal(raw, &want); err != nil {
			t.Fatal(err)
		}
		if gj := asJSON(t, g); !reflect.DeepEqual(gj, want) {
			a, _ := json.MarshalIndent(gj, "", "  ")
			b, _ := json.MarshalIndent(want, "", "  ")
			t.Errorf("shape %s:\n--- got\n%s\n--- want\n%s", name, a, b)
		}
	}
}
