package affordkit

// The agent's side of AffordKit over any transport. Give it a way to send a request to the app (which answers with its kit's
// answer()), and it gives the agent its tools and runs them: each answer as text for the model — after an act, what it did to the
// screen rather than the whole tree again — with a code when it failed.
//
//	ui := affordkit.NewRemote(affordkit.RemoteOptions{Send: askTheApp})   // the app: socket.onAsk((r) => kit.answer(r))
//	tools = append(tools, affordkit.AnthropicTools(ui.Tools())...)
//	a := ui.Handle(ctx, toolUse.Name, input)                            // → the tool_result: a.Text, a.IsError
//
// When the user has left the app (Present says so), the screen tools answer code away at once; with OnHandoff the agent also gets
// ui_handoff, to leave the user a message and the calls that take them to what it did (see Handoff).

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

// Screen is what the agent gets after an act: what changed, or the whole tree.
type Screen string

const (
	// ScreenChanges: what changed on screen (the default: fewer tokens).
	ScreenChanges Screen = "changes"
	// ScreenWhole: the whole tree after each act.
	ScreenWhole Screen = "whole"
)

// RemoteOptions configures a Remote.
type RemoteOptions struct {
	// Send sends a request to the app and returns its answer (kit.answer on the app's side). Return an *AffordError to say why
	// it failed with a code; any other error is code unavailable. ctx is done when the answer is no longer wanted (the timeout).
	Send func(ctx context.Context, req UiRequest) (UiAnswer, error)
	// Timeout is how long to wait for the app's answer (default 45 s): then the tool fails with code timeout.
	Timeout time.Duration
	// Screen is the screen after an act: what changed (default), or the whole tree each time.
	Screen Screen
	// Tools is which of AgentTools to offer (nil: all — ui_tool once the app is seen to have tools of its own, ui_handoff with
	// OnHandoff).
	Tools []string
	// MaxNodes is the most nodes in a tree as text (default 400).
	MaxNodes int
	// Present says whether the user is in the app now (e.g. the app's lifecycle as its channel last reported it). While it says
	// no, every tool but ui_handoff answers code away at once, without asking the app. Nil: always.
	Present func() bool
	// OnHandoff is where a handoff the agent leaves goes (ui_handoff, checked first): keep it and tell the user — a notification
	// with its id, usually. What it returns ("notification sent") is told the agent; an *AffordError says why it failed. Nil:
	// ui_handoff isn't offered.
	OnHandoff func(ctx context.Context, h Handoff) (string, error)
	// HandoffTTL is how long a handoff stays good (default 24 h): its ExpiresAt.
	HandoffTTL time.Duration
}

// Image is a picture that goes with a tool's text.
type Image struct {
	Mime string `json:"mime"`
	Data string `json:"data"`
}

// ToolAnswer is a tool's answer: the text for the agent (its tool result), whether it failed and why, and the screen it left.
type ToolAnswer struct {
	Text    string         `json:"text"`
	IsError bool           `json:"isError"`
	Code    ErrorCode      `json:"code,omitempty"`
	Context *AffordContext `json:"context,omitempty"`
	// Images are pictures that go with the text (a look with picture, an op view): to pass to the model where its stack takes
	// images.
	Images []Image `json:"images,omitempty"`
}

// Remote is the agent's side of one app: its tools, run over RemoteOptions.Send. Safe for use from several goroutines, though a
// model's calls are best run one after another (each answer says what changed since the last).
type Remote struct {
	options RemoteOptions
	mu      sync.Mutex
	last    *AffordContext
}

// NewRemote is a Remote over a way to reach the app.
func NewRemote(options RemoteOptions) *Remote {
	return &Remote{options: options}
}

// Seen sets the screen as the agent was last shown it (e.g. sent along with the user's message): the next act answers with what
// changed since. Nil: nothing seen.
func (r *Remote) Seen(ctx *AffordContext) {
	r.mu.Lock()
	r.last = ctx
	r.mu.Unlock()
}

// Screen is the screen as the agent last saw it (nil before it saw one).
func (r *Remote) Screen() *AffordContext {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.last
}

// Tools are the tools to give the agent.
func (r *Remote) Tools() []AgentTool {
	last := r.Screen()
	names := r.options.Tools
	var out []AgentTool
	for _, t := range AgentTools {
		if t.Name == "ui_handoff" && r.options.OnHandoff == nil {
			continue
		}
		if names != nil {
			if contains(names, t.Name) {
				out = append(out, t)
			}
		} else if t.Name != "ui_tool" || last == nil || len(last.Tools) > 0 {
			out = append(out, t)
		}
	}
	return out
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// Has is whether a tool the agent called is one of these.
func (r *Remote) Has(name string) bool {
	for _, t := range r.Tools() {
		if t.Name == name {
			return true
		}
	}
	return false
}

// Handle runs a tool the agent called: its answer as text. It never fails: a failure is an answer with IsError and a Code.
func (r *Remote) Handle(ctx context.Context, name string, input map[string]any) ToolAnswer {
	if ctx == nil {
		ctx = context.Background()
	}
	input = normalize(input)
	if name == "ui_handoff" {
		return r.handoff(ctx, input)
	}
	// The user has left: nothing on the screen can be done now (and the app may not even answer)
	if r.options.Present != nil && !r.options.Present() && isAgentTool(name) {
		also := ""
		if r.options.OnHandoff != nil {
			also = ", and leave a handoff (ui_handoff) for when they come back"
		}
		return failed(CodeAway, "The user is not in the app right now (it is in the background): the screen can't be looked at or worked. Use your other tools"+also+".")
	}
	call, err := ToCall(name, input)
	if err != nil {
		return failed(CodeBadArgs, err.Error())
	}
	picture, _ := input["picture"].(bool)
	req := UiRequest{Look: true, Picture: picture}
	if call != nil {
		req = UiRequest{Calls: []Call{*call}}
	}
	answer := r.ask(ctx, req)
	if answer.Error != "" || answer.Context == nil {
		code := answer.Code
		if code == "" {
			code = CodeUnavailable
		}
		msg := answer.Error
		if msg == "" {
			msg = "The app gave no screen"
		}
		return failed(code, msg)
	}
	r.mu.Lock()
	before := r.last
	r.last = answer.Context
	r.mu.Unlock()
	maxNodes := r.options.MaxNodes
	if maxNodes <= 0 {
		maxNodes = 400
	}
	if call == nil {
		var images []Image
		if answer.Picture != nil && answer.Picture.Data != "" {
			images = []Image{{answer.Picture.Mime, answer.Picture.Data}}
		}
		note := ""
		if picture {
			if len(images) > 0 {
				note = "\n\n(A picture of the screen is attached.)"
			} else {
				note = "\n\n(No picture: this app can't take one.)"
			}
		}
		text := Describe(answer.Context, DescribeOptions{MaxNodes: maxNodes}) + note
		if meanwhile := DescribeUserActions(answer.UserActions); meanwhile != "" {
			text = meanwhile + "\n\n" + text
		}
		return ToolAnswer{Text: text, Context: answer.Context, Images: images}
	}
	if len(answer.Results) == 0 {
		return failed(CodeUnavailable, "The app gave no result")
	}
	res := &answer.Results[0]
	whole := r.options.Screen == ScreenWhole
	// A peek leaves the screen as it was; anything else: what it did to it (going to a page says where it is now itself)
	said := ""
	if !(res.OK && call.Kind == CallNavigate && before != nil && !whole) {
		said = DescribeResult(res)
	}
	screen := ""
	switch {
	case call.Kind == CallPeek:
	case whole || before == nil:
		screen = "The screen now:\n" + Describe(answer.Context, DescribeOptions{MaxNodes: maxNodes})
	default:
		screen = DescribeChange(before, answer.Context, ChangeOptions{MaxNodes: maxNodes})
	}
	var images []Image
	if img, ok := isImage(res.Value); ok && img.Data != "" {
		images = []Image{{img.Mime, img.Data}}
	}
	// (what the user did themselves first: the screen it left is part of what the change below shows)
	var parts []string
	for _, p := range []string{DescribeUserActions(answer.UserActions), said, screen} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	return ToolAnswer{Text: strings.Join(parts, "\n\n"), IsError: !res.OK, Code: res.Code, Context: answer.Context, Images: images}
}

// handoff is ui_handoff: the agent's handoff checked (its route against the routes seen), with its expiry, and given to the host.
func (r *Remote) handoff(ctx context.Context, input map[string]any) (out ToolAnswer) {
	give := r.options.OnHandoff
	if give == nil {
		return failed(CodeNotFound, "This app takes no handoffs")
	}
	// (its id and expiry are the host's to say, not the agent's)
	ttl := r.options.HandoffTTL
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	now := time.Now().UnixMilli()
	draft := map[string]any{}
	for k, v := range input {
		draft[k] = v
	}
	draft["v"] = float64(1)
	draft["expiresAt"] = float64(now + ttl.Milliseconds())
	delete(draft, "id")
	problem := handoffProblem(draft)
	var h *Handoff
	if problem == "" {
		h = ParseHandoff(draft, now)
	}
	if h == nil {
		if problem == "" {
			problem = "Not a handoff"
		}
		return failed(CodeBadArgs, problem)
	}
	if last := r.Screen(); h.Route != "" && last != nil && last.Route != nil && len(last.Route.Routes) > 0 && FindRoute(last.Route.Routes, h.Route) == nil {
		paths := make([]string, len(last.Route.Routes))
		for i, rt := range last.Route.Routes {
			paths[i] = rt.Path
		}
		return failed(CodeBadArgs, fmt.Sprintf("No route %s (the routes: %s)", h.Route, strings.Join(paths, ", ")))
	}
	defer func() {
		if p := recover(); p != nil {
			out = failed(CodeFailed, fmt.Sprint(p))
		}
	}()
	said, err := give(ctx, *h)
	if err != nil {
		return failed(codeOf(err, CodeFailed), err.Error())
	}
	if said == "" {
		said = "the user gets it when they come back."
	}
	return ToolAnswer{Text: "Handoff left: " + said}
}

// ask sends a request and waits for the answer, at most the timeout: a failure to send, a panic or no answer in time are answers
// with an error and its code.
func (r *Remote) ask(ctx context.Context, req UiRequest) UiAnswer {
	timeout := r.options.Timeout
	if timeout <= 0 {
		timeout = 45 * time.Second
	}
	if r.options.Send == nil {
		return UiAnswer{Error: "No way to reach the app (RemoteOptions.Send)", Code: CodeUnavailable}
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	done := make(chan UiAnswer, 1)
	go func() {
		defer func() {
			if p := recover(); p != nil {
				done <- UiAnswer{Error: fmt.Sprint(p), Code: CodeUnavailable}
			}
		}()
		answer, err := r.options.Send(ctx, req)
		if err != nil {
			done <- UiAnswer{Error: err.Error(), Code: codeOf(err, CodeUnavailable)}
			return
		}
		done <- answer
	}()
	select {
	case answer := <-done:
		return answer
	case <-ctx.Done():
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return UiAnswer{Error: "The app did not answer in time (it may be in the background): look again later, or do it another way", Code: CodeTimeout}
		}
		return UiAnswer{Error: ctx.Err().Error(), Code: CodeUnavailable}
	}
}

// codeOf is an error's code when it is (or wraps) an *AffordError, else the fallback.
func codeOf(err error, fallback ErrorCode) ErrorCode {
	var ae *AffordError
	if errors.As(err, &ae) && ae.Code != "" {
		return ae.Code
	}
	return fallback
}

func failed(code ErrorCode, message string) ToolAnswer {
	return ToolAnswer{Text: "Failed (" + string(code) + "): " + message, IsError: true, Code: code}
}
