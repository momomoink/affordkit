// Package affordkit is the agent's side of AffordKit for a Go backend: the app's screen (sent by its AffordKit, Flutter or web) as
// tools for a model, and the model's calls run on it.
//
// The AffordKit protocol: what an app's UI looks like to an AI agent, and how the agent acts on it. The same format on every
// platform (DOM, Flutter): an app builds a tree of the controls on screen (context), the agent reads it and answers with calls,
// the app runs them and the results go back to the agent as the next round's context.
//
//   - Only controls that mean something are in the tree; a node says what it is, what it's called, a short state — never its
//     content: that is read on demand (the "read" op), so the first round stays small.
//   - Each operation has a policy: allow (just do it), confirm (only after the user says yes), deny (the agent can see it but never
//     do it — e.g. the button that sends an email).
//   - The app's pages are routes: the agent knows where the user is, can take them elsewhere (navigate, or back), and can look at
//     another page's tree before going there (peek), addressing the controls there by the stable keys the app gives them.
//   - Many of the same thing (a mail list, a thread's messages) is a container: ONE node — how many entries, which show, a short
//     preview — never their controls. The agent fetches an entry with the container's `item` op, or pages through all entries'
//     summaries (`items`). An entry's key is the container's and its id (`mail.list[42]`), controls inside it keys under that.
//   - When the user has left the app (it is in the background), its screen can't be worked: the agent does what it can another
//     way, and may leave a handoff — a message, and calls by key that take the user to what it did when they come back.
//   - What the user does themselves meanwhile, the next answer carries (userActions) with the screen after it.
//
// This is a port of the TypeScript reference (js/src/remote.ts, agent.ts, adapters.ts and the parts of protocol.ts they use), kept
// close to it so a change there is easy to carry over; conformance/remote.json checks both give the same answers.
package affordkit

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"
)

// ProtocolVersion is the protocol's version (AffordContext.Protocol).
const ProtocolVersion = 1

// Policy is what an operation needs: allow (just do it), confirm (the user's yes first), deny (the user's own to do).
type Policy string

const (
	PolicyAllow   Policy = "allow"
	PolicyConfirm Policy = "confirm"
	PolicyDeny    Policy = "deny"
)

// Entry is one key of an Entries, with its value.
type Entry[V any] struct {
	Key   string
	Value V
}

// Entries is a JSON object whose key order matters (a node's state, a route's params): its keys in the order JavaScript keeps
// them (integer keys first, ascending, then the others as they came), which is the order the text lists them in. A plain Go map
// would lose it.
type Entries[V any] []Entry[V]

// Get is the value of a key.
func (e Entries[V]) Get(key string) (V, bool) {
	for _, x := range e {
		if x.Key == key {
			return x.Value, true
		}
	}
	var zero V
	return zero, false
}

// UnmarshalJSON reads an object keeping its keys in JavaScript's order.
func (e *Entries[V]) UnmarshalJSON(b []byte) error {
	if rawKind(b) == 'n' {
		*e = nil
		return nil
	}
	fields, err := rawFields(b)
	if err != nil {
		return err
	}
	out := make(Entries[V], 0, len(fields))
	for _, f := range fields {
		var v V
		if err := json.Unmarshal(f.Value, &v); err != nil {
			return err
		}
		out = append(out, Entry[V]{f.Key, v})
	}
	*e = out
	return nil
}

// MarshalJSON writes the object with its keys in order.
func (e Entries[V]) MarshalJSON() ([]byte, error) {
	if e == nil {
		return []byte("null"), nil
	}
	var b bytes.Buffer
	b.WriteByte('{')
	for i, x := range e {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsQuote(x.Key))
		b.WriteByte(':')
		v, err := marshalCompact(x.Value)
		if err != nil {
			return nil, err
		}
		b.Write(v)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// OpSpec is what can be done to a node.
type OpSpec struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	// Params is a JSON Schema (an object's properties) for its arguments.
	Params json.RawMessage `json:"params,omitempty"`
	Policy Policy          `json:"policy"`
}

// ItemSummary is one entry of a container, as its preview and its `items` op give it (whether or not it is on screen).
type ItemSummary struct {
	// Key is the entry's key (`<container key>[<id>]`), to fetch it or act on it — when the container has a key.
	Key   string   `json:"key,omitempty"`
	ID    string   `json:"id"`
	Index *float64 `json:"index,omitempty"`
	// Name is what the entry is called (a JSON string; kept raw, as the text shows it as JSON).
	Name        json.RawMessage `json:"name"`
	Description string          `json:"description,omitempty"`
}

// ItemsPage is a page of a container's entries: the `items` op's answer.
type ItemsPage struct {
	// Count is all the items (not only this page), when known.
	Count  *float64      `json:"count,omitempty"`
	Offset float64       `json:"offset"`
	Items  []ItemSummary `json:"items"`
}

// ItemTree is one entry of a container, fetched (the `item` op's answer): a tree of its own, rooted at the entry. Source live: on
// screen now, its ids can be acted on; preview: built off screen, ids not live (act by key: that brings it in).
type ItemTree struct {
	Key    string     `json:"key,omitempty"`
	ID     string     `json:"id"`
	Index  *float64   `json:"index,omitempty"`
	Source string     `json:"source"`
	Root   AffordNode `json:"root"`
}

// UserActionNode is the node a user action was on, as the tree had it then.
type UserActionNode struct {
	ID   string `json:"id"`
	Key  string `json:"key,omitempty"`
	Role string `json:"role"`
	Name string `json:"name"`
}

// UserAction is something the user did themselves while the agent was working their screen, named the way the agent would have
// called it: press, write, toggle, select, scroll on a node; navigate (to route) or back.
type UserAction struct {
	// At is when, in ms since the epoch.
	At float64 `json:"at"`
	Op string  `json:"op"`
	// Node is the node (its key when it has one: ids may have gone since). None for navigate and back.
	Node *UserActionNode `json:"node,omitempty"`
	// Value is what they typed or picked, cut short (never what goes into a password field).
	Value *string `json:"value,omitempty"`
	// Route is the route after it.
	Route *string `json:"route,omitempty"`
}

// AffordNode is one control of the AffordTree (the screen's controls as a tree: a context's root).
type AffordNode struct {
	// ID is stable while the control stays on screen; what calls refer to.
	ID string `json:"id"`
	// Key is a name the app gives it that stays the same across pages and visits (e.g. "settings.ai.model"): calls may use it
	// instead of the id.
	Key  string `json:"key,omitempty"`
	Role string `json:"role"`
	// Name is what the user sees it called (label, text, placeholder).
	Name string `json:"name"`
	// Description is what it is for, when the app says.
	Description string `json:"description,omitempty"`
	// State is a short state, never the content: { checked: true }, { length: 320, focused: true }... in the app's order.
	State Entries[json.RawMessage] `json:"state,omitempty"`
	// Value is what a text or a heading shows (a JSON string, kept raw: the text shows it as JSON), when it isn't its name.
	Value    json.RawMessage `json:"value,omitempty"`
	Ops      []OpSpec        `json:"ops"`
	Children []AffordNode    `json:"children,omitempty"`
	// Preview is a container's entries on screen, in short.
	Preview []ItemSummary `json:"preview,omitempty"`
}

// ToolSpec is an app-wide operation, not tied to a control (same shape as a WebMCP tool).
type ToolSpec struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema,omitempty"`
	Policy      Policy          `json:"policy"`
}

// RouteParam is what a route's :param can be.
type RouteParam struct {
	Description string   `json:"description,omitempty"`
	Values      []string `json:"values,omitempty"`
}

// RouteSpec is a place in the app the agent can go to.
type RouteSpec struct {
	// Path is a pattern such as /settings/:tab or /mail/folder/:id.
	Path        string `json:"path"`
	Description string `json:"description"`
	// Params is what each :param can be (its values when there are only a few).
	Params Entries[RouteParam] `json:"params,omitempty"`
}

// RouteState is where the user is, and where the agent can take them.
type RouteState struct {
	// Current is the route now, e.g. /settings/ai.
	Current string `json:"current"`
	// Pattern is the pattern it is (one of routes), and Params its params: { tab: "ai" }.
	Pattern string          `json:"pattern,omitempty"`
	Params  Entries[string] `json:"params,omitempty"`
	// CanGoBack is whether navigate "back" goes somewhere.
	CanGoBack bool        `json:"canGoBack,omitempty"`
	Routes    []RouteSpec `json:"routes"`
}

// AffordContext is the screen as the app sends it: where it is, the tree of controls, and its own tools.
type AffordContext struct {
	Protocol int         `json:"protocol"`
	Route    *RouteState `json:"route,omitempty"`
	Root     AffordNode  `json:"root"`
	Tools    []ToolSpec  `json:"tools"`
}

// PagePeek is another page's tree, peeked at without going there. Its ids are not live: navigate there, then act by the nodes'
// keys. Source live: the page showing now; preview: built off screen just now; seen: as it was the last time it showed (SeenAt);
// declared: never seen, only what the route says it is (no tree).
type PagePeek struct {
	Route       string      `json:"route"`
	Pattern     string      `json:"pattern,omitempty"`
	Source      string      `json:"source"`
	SeenAt      *float64    `json:"seenAt,omitempty"`
	Description string      `json:"description,omitempty"`
	Root        *AffordNode `json:"root,omitempty"`
}

// CallKind is which of the four calls a Call is.
type CallKind int

const (
	// CallNone is a call the app sent back in a shape that isn't one of the others.
	CallNone CallKind = iota
	// CallNode is an op on a node (by id, or key): {node, op, args}.
	CallNode
	// CallTool is one of the app's own tools: {tool, args}.
	CallTool
	// CallNavigate is going to a route, or "back": {navigate}.
	CallNavigate
	// CallPeek is a look at another route's page: {peek}.
	CallPeek
)

// Call is one thing the agent asks for: an op on a node, an app-wide tool, going to a route (or "back"), or a peek at one. Only
// the fields of its Kind count.
type Call struct {
	Kind     CallKind
	Node     string
	Op       string
	Tool     string
	Args     map[string]any
	Navigate string
	Peek     string
}

// MarshalJSON writes the call in its protocol shape.
func (c Call) MarshalJSON() ([]byte, error) {
	type kv = Entry[any]
	var e Entries[any]
	switch c.Kind {
	case CallNode:
		e = Entries[any]{kv{"node", c.Node}, kv{"op", c.Op}}
		if c.Args != nil {
			e = append(e, kv{"args", c.Args})
		}
	case CallTool:
		e = Entries[any]{kv{"tool", c.Tool}}
		if c.Args != nil {
			e = append(e, kv{"args", c.Args})
		}
	case CallNavigate:
		e = Entries[any]{kv{"navigate", c.Navigate}}
	case CallPeek:
		e = Entries[any]{kv{"peek", c.Peek}}
	default:
		e = Entries[any]{}
	}
	return e.MarshalJSON()
}

// UnmarshalJSON reads a call in any of its shapes.
func (c *Call) UnmarshalJSON(b []byte) error {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	*c = Call{}
	str := func(k string) string { s, _ := rawString(m[k]); return s }
	if a, ok := m["args"]; ok && rawKind(a) == '{' {
		_ = json.Unmarshal(a, &c.Args)
	}
	_, peek := m["peek"]
	_, navigate := m["navigate"]
	_, op := m["op"]
	_, tool := m["tool"]
	switch {
	case peek:
		c.Kind, c.Peek = CallPeek, str("peek")
	case navigate:
		c.Kind, c.Navigate = CallNavigate, str("navigate")
	case op:
		c.Kind, c.Node, c.Op = CallNode, str("node"), str("op")
	case tool:
		c.Kind, c.Tool = CallTool, str("tool")
	}
	return nil
}

// ErrorCode is why a call failed, for the agent's loop to act on (the error says it in words).
type ErrorCode string

const (
	// CodeNotFound: no such node (it went), route, tool or entry.
	CodeNotFound ErrorCode = "not_found"
	// CodeNoOp: the node has no such op.
	CodeNoOp ErrorCode = "no_op"
	// CodeBadArgs: the op's arguments are missing or wrong.
	CodeBadArgs ErrorCode = "bad_args"
	// CodeDenied: policy deny, the user does this themselves.
	CodeDenied ErrorCode = "denied"
	// CodeNeedsConfirm: policy confirm, and the app gave no way to ask: nothing was done.
	CodeNeedsConfirm ErrorCode = "needs_confirm"
	// CodeDeclined: the user was asked and said no.
	CodeDeclined ErrorCode = "declined"
	// CodeDisabled: the control is disabled.
	CodeDisabled ErrorCode = "disabled"
	// CodeUnreachable: something is over it (a dialog, another page) and it can't be worked from there.
	CodeUnreachable ErrorCode = "unreachable"
	// CodeTimeout: the app did not answer in time.
	CodeTimeout ErrorCode = "timeout"
	// CodeUnavailable: there is no app to work, or it could not answer.
	CodeUnavailable ErrorCode = "unavailable"
	// CodeAway: the user is not in the app now (it is in the background): its screen can't be looked at or worked.
	CodeAway ErrorCode = "away"
	// CodeExpired: a handoff past its expiresAt, not run.
	CodeExpired ErrorCode = "expired"
	// CodeFailed: anything else that went wrong doing it.
	CodeFailed ErrorCode = "failed"
)

// AffordError is an error with its code: return one from RemoteOptions.Send or OnHandoff to say which (find it with errors.As).
type AffordError struct {
	Code    ErrorCode
	Message string
}

func (e *AffordError) Error() string { return e.Message }

// CallResult is what one call did.
type CallResult struct {
	Call Call `json:"call"`
	OK   bool `json:"ok"`
	// Value is what a read returned, or what a tool answered (raw JSON: the text shows it as the app sent it).
	Value json.RawMessage `json:"value,omitempty"`
	Error string          `json:"error,omitempty"`
	// Code is why it failed.
	Code ErrorCode `json:"code,omitempty"`
	// NeedsConfirm: needs the user's yes first (policy confirm, and the app gave no way to ask): nothing was done.
	NeedsConfirm bool `json:"needsConfirm,omitempty"`
}

// UiRequest is what goes from the agent's side to the app (over whatever the app uses: a socket, HTTP, a message port): look at
// the screen ({look: true, picture?}), or run calls ({calls}). The app answers with its kit's answer().
type UiRequest struct {
	Look    bool   `json:"look,omitempty"`
	Picture bool   `json:"picture,omitempty"`
	Calls   []Call `json:"calls,omitempty"`
}

// UiAnswer is the app's answer: the screen (and the calls' results; a picture of the screen when asked and it can), or why it
// couldn't (Error, Code). UserActions: what the user did themselves since the last answer (oldest first) — the context is the
// screen after it all.
type UiAnswer struct {
	Context     *AffordContext `json:"context,omitempty"`
	Results     []CallResult   `json:"results,omitempty"`
	Picture     *ImageValue    `json:"picture,omitempty"`
	UserActions []UserAction   `json:"userActions,omitempty"`
	Error       string         `json:"error,omitempty"`
	Code        ErrorCode      `json:"code,omitempty"`
}

// ImageValue is a picture (what op view answers, and a look with picture): PNG / JPEG as base64, or where it is when it couldn't
// be read.
type ImageValue struct {
	Type   string  `json:"type"`
	Mime   string  `json:"mime"`
	Data   string  `json:"data,omitempty"`
	URL    string  `json:"url,omitempty"`
	Width  float64 `json:"width,omitempty"`
	Height float64 `json:"height,omitempty"`
}

// isImage is whether a raw value is a picture ({type: "image", mime: "…"}), and the picture.
func isImage(raw json.RawMessage) (*ImageValue, bool) {
	if rawKind(raw) != '{' {
		return nil, false
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return nil, false
	}
	if t, _ := rawString(m["type"]); t != "image" {
		return nil, false
	}
	if _, ok := rawString(m["mime"]); !ok {
		return nil, false
	}
	var v ImageValue
	_ = json.Unmarshal(raw, &v)
	return &v, true
}

// IsImage is whether a value (raw JSON, or decoded) is a picture.
func IsImage(v any) bool {
	raw, ok := v.(json.RawMessage)
	if !ok {
		b, err := json.Marshal(v)
		if err != nil {
			return false
		}
		raw = b
	}
	_, ok = isImage(raw)
	return ok
}

// HandoffCall is one step of a handoff: an op on a control by its key (a handoff runs later, when ids from a look have long gone).
type HandoffCall struct {
	Key  string
	Op   string
	Args map[string]any
}

// MarshalJSON writes {key, op, args?} (args when given, even empty).
func (c HandoffCall) MarshalJSON() ([]byte, error) {
	e := Entries[any]{{"key", c.Key}, {"op", c.Op}}
	if c.Args != nil {
		e = append(e, Entry[any]{"args", c.Args})
	}
	return e.MarshalJSON()
}

// UnmarshalJSON reads {key, op, args?}.
func (c *HandoffCall) UnmarshalJSON(b []byte) error {
	var v struct {
		Key  string         `json:"key"`
		Op   string         `json:"op"`
		Args map[string]any `json:"args"`
	}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	*c = HandoffCall{v.Key, v.Op, v.Args}
	return nil
}

// Handoff is what an agent leaves for a user who is away (the app in the background): a short message, and the calls that take
// them to what it did when they come back — the page first (Route), then ops there by key. The host keeps it and tells the user
// (a notification, usually); when they tap it, the app runs it (kit.runHandoff). One-shot, and it expires.
type Handoff struct {
	V int `json:"v"`
	// Message is what the agent did and what is waiting, for the user (at most HandoffMaxMessage characters).
	Message string `json:"message"`
	// Route is where to go first: a route of the app (one of the context's routes, filled in).
	Route string `json:"route,omitempty"`
	// Calls are run then, in order (at most HandoffMaxCalls).
	Calls []HandoffCall `json:"calls"`
	// ExpiresAt is when it stops being good (ms since the epoch).
	ExpiresAt int64 `json:"expiresAt,omitempty"`
	// ID is the host's id for it, set when it stores it.
	ID string `json:"id,omitempty"`
}

// HandoffMaxCalls is the most calls in a handoff.
const HandoffMaxCalls = 20

// HandoffMaxMessage is the longest message of a handoff (in UTF-16 code units, as JavaScript counts).
const HandoffMaxMessage = 500

var lookID = regexp.MustCompile(`^(?:[nwp]\d+|app|behind-\d+)$`)

// isLookID is whether a node ref is an id from a look (the kit's: n12, w4, p3, app, behind-2, peek:…) rather than a key the app gave.
func isLookID(ref string) bool {
	return strings.HasPrefix(ref, "peek:") || lookID.MatchString(ref)
}

// HandoffProblem is what is wrong with something given as a handoff (its shape, not whether it expired), or "" when it is one.
// The input is as decoded from JSON (map[string]any); Go values are taken as their JSON.
func HandoffProblem(input any) string {
	return handoffProblem(normalizeAny(input))
}

func normalizeAny(v any) any {
	b, err := json.Marshal(v)
	if err != nil {
		return v
	}
	var out any
	if json.Unmarshal(b, &out) != nil {
		return v
	}
	return out
}

func handoffProblem(input any) string {
	in, ok := input.(map[string]any)
	if !ok {
		return "A handoff is an object: { message, route?, calls? }"
	}
	// (a key that is there, even as null, counts: as in JavaScript, only an absent one is left out)
	if v, ok := in["v"]; ok && v != float64(1) {
		return "Unknown handoff version " + jsStringAny(v)
	}
	message := ""
	if s, ok := in["message"].(string); ok {
		message = jsTrim(s)
	}
	if message == "" {
		return "Say what you did in message: the user reads it"
	}
	if n := jsLength(message); n > HandoffMaxMessage {
		return fmt.Sprintf("message is too long (%d characters, at most %d)", n, HandoffMaxMessage)
	}
	if r, ok := in["route"]; ok {
		s, isStr := r.(string)
		if !isStr || jsTrim(s) == "" || jsTrim(s) == "back" {
			return "route is a route of the app (e.g. /drafts), or left out"
		}
	}
	if e, ok := in["expiresAt"]; ok {
		if _, isNum := e.(float64); !isNum {
			return "expiresAt is a time in ms"
		}
	}
	if id, ok := in["id"]; ok {
		if _, isStr := id.(string); !isStr {
			return "id is a string"
		}
	}
	var calls []any
	if c, ok := in["calls"]; ok && c != nil {
		list, isList := c.([]any)
		if !isList {
			return "calls is a list of { key, op, args? }"
		}
		calls = list
	}
	if len(calls) > HandoffMaxCalls {
		return fmt.Sprintf("Too many calls (%d, at most %d): take the user to the result, no more", len(calls), HandoffMaxCalls)
	}
	for i, c := range calls {
		obj, isObj := c.(map[string]any)
		// (a key, as ui_act's node or as key)
		var key any
		if isObj {
			key = obj["key"]
			if key == nil {
				key = obj["node"]
			}
		}
		k, keyOK := key.(string)
		op, opOK := obj["op"].(string)
		if !isObj || !keyOK || k == "" || !opOK || op == "" {
			return fmt.Sprintf("calls[%d] is not { key, op, args? }", i)
		}
		if isLookID(k) {
			return fmt.Sprintf("calls[%d]: %s is an id from a look, gone by the time the user comes back: use the control's key", i, k)
		}
		if a, ok := obj["args"]; ok {
			if _, isMap := a.(map[string]any); !isMap {
				return fmt.Sprintf("calls[%d].args is an object", i)
			}
		}
	}
	return ""
}

// HandoffExpired is whether a handoff's time is up (now in ms since the epoch).
func HandoffExpired(h *Handoff, now int64) bool {
	return h.ExpiresAt != 0 && h.ExpiresAt <= now
}

// ParseHandoff is something given as a handoff (the agent's input, what the host stored), checked and in its plain shape; nil
// when it isn't one or it expired (now in ms since the epoch).
func ParseHandoff(input any, now int64) *Handoff {
	in := normalizeAny(input)
	if handoffProblem(in) != "" {
		return nil
	}
	h := in.(map[string]any)
	out := &Handoff{V: 1, Message: jsTrim(h["message"].(string)), Calls: []HandoffCall{}}
	if r, ok := h["route"].(string); ok {
		out.Route = jsTrim(r)
	}
	if calls, ok := h["calls"].([]any); ok {
		for _, c := range calls {
			obj := c.(map[string]any)
			key, _ := obj["key"].(string)
			if obj["key"] == nil {
				key, _ = obj["node"].(string)
			}
			call := HandoffCall{Key: key, Op: obj["op"].(string)}
			if a, ok := obj["args"].(map[string]any); ok {
				call.Args = a
			}
			out.Calls = append(out.Calls, call)
		}
	}
	if id, ok := h["id"].(string); ok {
		out.ID = id
	}
	if e, ok := h["expiresAt"].(float64); ok {
		if e <= float64(now) {
			return nil
		}
		out.ExpiresAt = int64(e)
	}
	return out
}

// MatchRoute is a route's params if it is this pattern (/settings/:tab against /settings/ai → { tab: "ai" }), else nil.
func MatchRoute(pattern, route string) Entries[string] {
	split := func(p string) []string {
		if i := strings.IndexAny(p, "?#"); i >= 0 {
			p = p[:i]
		}
		var out []string
		for _, s := range strings.Split(p, "/") {
			if s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	want := split(pattern)
	got := split(route)
	tail := len(want) > 0 && want[len(want)-1] == "*"
	if tail && len(got) < len(want)-1 || !tail && len(got) != len(want) {
		return nil
	}
	params := Entries[string]{}
	for i, w := range want {
		if w == "*" {
			break
		}
		if strings.HasPrefix(w, ":") {
			// (a malformed escape, /b/%zz or a broken UTF-8 /b/%C3: not this route)
			v, err := url.PathUnescape(got[i])
			if err != nil || !utf8.ValidString(v) {
				return nil
			}
			name := w[1:]
			replaced := false
			for j := range params {
				if params[j].Key == name {
					params[j].Value, replaced = v, true
				}
			}
			if !replaced {
				params = append(params, Entry[string]{name, v})
			}
		} else if w != got[i] {
			return nil
		}
	}
	return params
}

// RouteMatch is the pattern a route is, and its params.
type RouteMatch struct {
	Spec   RouteSpec
	Params Entries[string]
}

// FindRoute is the pattern a route is, and its params; nil when it is none of them. Of those that match, the most specific: one
// without a catch-all (*) before one with, then the fewest params, then the most fixed segments; on a tie, the first listed.
func FindRoute(routes []RouteSpec, route string) *RouteMatch {
	rank := func(path string, params Entries[string]) [3]int {
		if i := strings.IndexAny(path, "?#"); i >= 0 {
			path = path[:i]
		}
		var parts []string
		for _, s := range strings.Split(path, "/") {
			if s != "" {
				parts = append(parts, s)
			}
		}
		catchAll, fixed := 0, 0
		if len(parts) > 0 && parts[len(parts)-1] == "*" {
			catchAll = 1
		}
		for _, p := range parts {
			if p != "*" && !strings.HasPrefix(p, ":") {
				fixed++
			}
		}
		return [3]int{catchAll, len(params), -fixed}
	}
	before := func(a, b [3]int) bool {
		for i := range a {
			if a[i] != b[i] {
				return a[i] < b[i]
			}
		}
		return false
	}
	var best *RouteMatch
	var bestRank [3]int
	for _, spec := range routes {
		params := MatchRoute(spec.Path, route)
		if params == nil {
			continue
		}
		if r := rank(spec.Path, params); best == nil || before(r, bestRank) {
			best, bestRank = &RouteMatch{spec, params}, r
		}
	}
	return best
}
