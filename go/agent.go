package affordkit

// The agent's side of AffordKit, for whatever runs the model: the context as compact text for a prompt, and the tools an agent
// uses to act on the app — each turned into a Call for the app to run.

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"
)

func routeLines(route *RouteState) []string {
	params := ""
	if len(route.Params) > 0 {
		parts := make([]string, len(route.Params))
		for i, p := range route.Params {
			parts[i] = p.Key + "=" + p.Value
		}
		params = " (" + strings.Join(parts, ", ") + ")"
	}
	line := "Route: " + route.Current
	if route.Pattern != "" && route.Pattern != route.Current {
		line += " = " + route.Pattern + params
	}
	if route.CanGoBack {
		line += " — can go back"
	}
	lines := []string{line}
	if len(route.Routes) > 0 {
		lines = append(lines, "Routes:")
		for _, r := range route.Routes {
			var ps []string
			for _, p := range r.Params {
				s := ":" + p.Key
				if p.Value.Values != nil {
					s += " ∈ {" + strings.Join(p.Value.Values, ", ") + "}"
				}
				if p.Value.Description != "" {
					s += " (" + p.Value.Description + ")"
				}
				ps = append(ps, s)
			}
			l := "  " + r.Path + " — " + r.Description
			if len(ps) > 0 {
				l += "; " + strings.Join(ps, "; ")
			}
			lines = append(lines, l)
		}
	}
	return lines
}

// nodeLine is one node as a line (no children): [id key=…] role "name" (state) — description — ops.
func nodeLine(n *AffordNode) string {
	// A container: what of, how many, which show, and how its entries' keys go — then only the other state
	list := ""
	entries := n.State
	if n.Role == "container" {
		count, _ := n.State.Get("count")
		first, _ := n.State.Get("first")
		last, _ := n.State.Get("last")
		kind, _ := n.State.Get("kind")
		if jsTruthy(kind) {
			list += " (" + jsToString(kind) + ")"
		}
		if c, ok := rawNumber(count); ok {
			if c == 1 {
				list += " " + jsNumber(c) + " entry"
			} else {
				list += " " + jsNumber(c) + " entries"
			}
		}
		if _, ok := rawNumber(first); ok {
			list += ", showing " + jsToString(first) + "–" + jsToString(last)
		}
		if n.Key != "" {
			list += " (entry keys: " + n.Key + "[<id>])"
		}
		entries = nil
		for _, e := range n.State {
			if e.Key != "count" && e.Key != "first" && e.Key != "last" && e.Key != "kind" {
				entries = append(entries, e)
			}
		}
	}
	state := ""
	if len(entries) > 0 {
		parts := make([]string, len(entries))
		for i, e := range entries {
			if rawKind(e.Value) == 't' {
				parts[i] = e.Key
			} else {
				parts[i] = e.Key + ": " + jsToString(e.Value)
			}
		}
		state = " (" + strings.Join(parts, ", ") + ")"
	}
	ops := make([]string, len(n.Ops))
	for i, o := range n.Ops {
		if o.Policy == PolicyAllow {
			ops[i] = o.Name
		} else {
			ops[i] = o.Name + "(" + string(o.Policy) + ")"
		}
	}
	id := n.ID
	if n.Key != "" {
		id = n.ID + " key=" + n.Key
	}
	// (what it shows, when it isn't its name already)
	value := ""
	if rawKind(n.Value) != 0 {
		if s, ok := rawString(n.Value); !ok || s != n.Name {
			value = " = " + jsStringify(n.Value)
		}
	}
	var b strings.Builder
	b.WriteString("[" + id + "] " + n.Role)
	if n.Name != "" {
		b.WriteString(` "` + n.Name + `"`)
	}
	b.WriteString(value + list + state)
	if n.Description != "" {
		b.WriteString(" — " + n.Description)
	}
	if len(ops) > 0 {
		b.WriteString(" — " + strings.Join(ops, ", "))
	}
	return b.String()
}

// summaryLine is an entry of a container in short: [key] #index "name" — description.
func summaryLine(i ItemSummary) string {
	ref := i.ID
	if i.Key != "" {
		ref = i.Key
	}
	s := "[" + ref + "]"
	if i.Index != nil {
		s += " #" + jsNumber(*i.Index)
	}
	s += " " + jsStringify(i.Name)
	if i.Description != "" {
		s += " — " + i.Description
	}
	return s
}

// previewLines is a container's entries on screen, in short (fetch one, op item, for its controls).
func previewLines(n *AffordNode, pad string) []string {
	if len(n.Preview) == 0 {
		return nil
	}
	lines := make([]string, 0, len(n.Preview)+1)
	for _, i := range n.Preview {
		lines = append(lines, pad+"· "+summaryLine(i))
	}
	more := 0.0
	if c, ok := n.State.Get("count"); ok {
		if f, ok := rawNumber(c); ok {
			more = f - float64(len(n.Preview))
		}
	}
	m := ""
	if more > 0 {
		m = " " + jsNumber(more) + " more;"
	}
	return append(lines, pad+"· …"+m+" op item fetches an entry's controls, items pages through them")
}

func treeLines(root *AffordNode, maxNodes int) []string {
	var lines []string
	count := 0
	var walk func(n *AffordNode, depth int)
	walk = func(n *AffordNode, depth int) {
		count++
		if count-1 >= maxNodes {
			return
		}
		lines = append(lines, strings.Repeat("  ", depth)+nodeLine(n))
		for i := range n.Children {
			walk(&n.Children[i], depth+1)
		}
		lines = append(lines, previewLines(n, strings.Repeat("  ", depth+1))...)
	}
	walk(root, 0)
	if count > maxNodes {
		lines = append(lines, "… "+jsNumber(float64(count-maxNodes))+" more nodes")
	}
	return lines
}

// DescribeOptions bounds a tree as text.
type DescribeOptions struct {
	// MaxNodes is the most nodes in a tree as text (default 400; 300 for a peeked page, 200 for an entry).
	MaxNodes int
}

func (o DescribeOptions) max(fallback int) int {
	if o.MaxNodes > 0 {
		return o.MaxNodes
	}
	return fallback
}

// Describe is the context as indented lines: the route, the routes, the tools, then the tree — `[n12 key=compose.send] button
// "Send" — press(deny)`, a container as `[n3 key=mail.list] container "Inbox" (list) 312 entries, showing 0–14 (entry keys:
// mail.list[<id>]) — read, item, items, scroll_to, scroll` with its preview under it (`· [mail.list[42]] #3 "Lunch?"`).
func Describe(ctx *AffordContext, opts DescribeOptions) string {
	var lines []string
	if ctx.Route != nil {
		lines = append(lines, routeLines(ctx.Route)...)
	}
	if len(ctx.Tools) > 0 {
		parts := make([]string, len(ctx.Tools))
		for i, t := range ctx.Tools {
			p := t.Name
			if t.Policy != PolicyAllow {
				p += "(" + string(t.Policy) + ")"
			}
			parts[i] = p + " — " + t.Description
		}
		lines = append(lines, "Tools: "+strings.Join(parts, "; "))
	}
	lines = append(lines, treeLines(&ctx.Root, opts.max(400))...)
	return strings.Join(lines, "\n")
}

// ChangeOptions bounds what DescribeChange says.
type ChangeOptions struct {
	// MaxNodes is the most nodes listed of each kind, and in the whole screen (default 400).
	MaxNodes int
	// WholeOver is the share of the screen that, coming and going, makes it another page: the whole new screen instead (default 0.5).
	WholeOver float64
}

type seenNode struct {
	node   *AffordNode
	line   string
	parent *AffordNode
}

// flatNodes is a tree's nodes by key (else id), in the order they came; a repeated one keeps its first place and its last node,
// as a JavaScript Map does.
type flatNodes struct {
	keys []string
	by   map[string]seenNode
}

func flatten(root *AffordNode) flatNodes {
	out := flatNodes{by: map[string]seenNode{}}
	var walk func(n, parent *AffordNode)
	walk = func(n, parent *AffordNode) {
		k := n.ID
		if n.Key != "" {
			k = n.Key
		}
		if _, ok := out.by[k]; !ok {
			out.keys = append(out.keys, k)
		}
		out.by[k] = seenNode{n, nodeLine(n) + strings.Join(previewLines(n, " "), ""), parent}
		for i := range n.Children {
			walk(&n.Children[i], n)
		}
	}
	walk(root, nil)
	return out
}

// DescribeChange is what changed on screen between two contexts, as text — what the agent gets after an act instead of the whole
// tree again: the route if it changed, then the nodes that came (+, under the node they are in), went (-) or changed (~). When
// most of the screen changed (another page), the whole new screen instead. Nodes are matched by key, else id (ids stay with
// their widget).
func DescribeChange(before, after *AffordContext, opts ChangeOptions) string {
	maxNodes := opts.MaxNodes
	if maxNodes <= 0 {
		maxNodes = 400
	}
	wholeOver := opts.WholeOver
	if wholeOver == 0 {
		wholeOver = 0.5
	}
	was := flatten(&before.Root)
	now := flatten(&after.Root)
	var came, went, changed []seenNode
	for _, k := range now.keys {
		if w, ok := was.by[k]; !ok {
			came = append(came, now.by[k])
		} else if w.line != now.by[k].line {
			changed = append(changed, now.by[k])
		}
	}
	for _, k := range was.keys {
		if _, ok := now.by[k]; !ok {
			went = append(went, was.by[k])
		}
	}
	var lines []string
	from, to := "", ""
	if before.Route != nil {
		from = before.Route.Current
	}
	if after.Route != nil {
		to = after.Route.Current
	}
	if to != "" && to != from {
		l := "Now at " + to
		if from != "" {
			l += " (was " + from + ")"
		}
		if after.Route.CanGoBack {
			l += " — can go back"
		}
		lines = append(lines, l+".")
	}
	if float64(len(came)+len(went)) > math.Max(4, float64(len(now.keys))*wholeOver) {
		lines = append(lines, "The screen now:", Describe(after, DescribeOptions{MaxNodes: maxNodes}))
		return strings.Join(lines, "\n")
	}
	if len(came) == 0 && len(went) == 0 && len(changed) == 0 {
		lines = append(lines, "The screen did not change.")
		return strings.Join(lines, "\n")
	}
	// A page that went under what is on top (a dialog opened, a page pushed) or came back from under it: its controls didn't
	// change, say so
	under := func(s seenNode) int {
		n := 0
		var count func(x *AffordNode)
		count = func(x *AffordNode) {
			for i := range x.Children {
				n++
				count(&x.Children[i])
			}
		}
		count(s.node)
		return n
	}
	named := func(n *AffordNode) string {
		if n.Name != "" {
			return ` "` + n.Name + `"`
		}
		return ""
	}
	where := func(s seenNode) string {
		if s.parent == nil || s.parent.Role == "app" {
			return ""
		}
		ref := s.parent.ID
		if s.parent.Key != "" {
			ref = s.parent.Key
		}
		return " (in " + ref + named(s.parent) + ")"
	}
	behind := func(n *AffordNode) bool {
		v, _ := n.State.Get("behind")
		return jsTruthy(v)
	}
	for _, s := range head(came, maxNodes) {
		if behind(s.node) {
			lines = append(lines, "+ ["+s.node.ID+"] "+s.node.Role+named(s.node)+" (behind) — now under what shows: its "+jsNumber(float64(under(s)))+" controls still work, unseen")
		} else {
			lines = append(lines, "+ "+nodeLine(s.node)+where(s))
			lines = append(lines, previewLines(s.node, "    ")...)
		}
	}
	for _, s := range head(went, maxNodes) {
		back := false
		if behind(s.node) {
			for i := range s.node.Children {
				c := &s.node.Children[i]
				k := c.ID
				if c.Key != "" {
					k = c.Key
				}
				if _, ok := now.by[k]; ok {
					back = true
					break
				}
			}
		}
		ref := s.node.ID
		if s.node.Key != "" {
			ref = s.node.Key
		}
		l := "- [" + ref + "] " + s.node.Role + named(s.node)
		if back {
			l += " — on top again: its controls show"
		}
		lines = append(lines, l)
	}
	for _, s := range head(changed, maxNodes) {
		lines = append(lines, "~ "+nodeLine(s.node))
		lines = append(lines, previewLines(s.node, "    ")...)
	}
	return strings.Join(append([]string{"The screen changed:"}, lines...), "\n")
}

func head[T any](s []T, n int) []T {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// DescribePage is a peeked page as text.
func DescribePage(view *PagePeek, opts DescribeOptions) string {
	var how string
	switch view.Source {
	case "live":
		how = "showing now"
	case "preview":
		how = "built off screen just now, as it would open"
	case "seen":
		how = "as it was when it last showed"
		if view.SeenAt != nil && *view.SeenAt != 0 && !math.IsNaN(*view.SeenAt) {
			how += " (" + isoTime(*view.SeenAt) + ")"
		}
	case "declared":
		how = "never seen: only what the route says"
	default:
		how = "undefined"
	}
	line := "Page " + view.Route
	if view.Pattern != "" && view.Pattern != view.Route {
		line += " = " + view.Pattern
	}
	line += " — " + how
	if view.Description != "" {
		line += ". " + view.Description
	}
	lines := []string{line}
	if view.Root != nil {
		if view.Source != "live" {
			lines = append(lines, "(Peek ids cannot be acted on: navigate there, then act by key, or look again for live ids.)")
		}
		lines = append(lines, treeLines(view.Root, opts.max(300))...)
	}
	return strings.Join(lines, "\n")
}

// isoTime is Date.prototype.toISOString of a time in ms: UTC, with milliseconds.
func isoTime(ms float64) string {
	return time.UnixMilli(int64(ms)).UTC().Format("2006-01-02T15:04:05.000Z")
}

// AgentTool is a tool an agent gets for acting on the app's UI: its name, what it does, and its input's JSON Schema.
type AgentTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

func schema(s string) json.RawMessage {
	var b bytes.Buffer
	if err := json.Compact(&b, []byte(s)); err != nil {
		panic(err)
	}
	return b.Bytes()
}

// AgentTools are the tools an agent gets for acting on the app's UI (the same names, descriptions and schemas as the TypeScript).
var AgentTools = []AgentTool{
	{
		Name:        "ui_look",
		Description: `See what is on the user's screen now: the route, and the tree of controls (each with an id — and a key when the app gives one — what it is, what it shows, its state and the ops it allows). picture: true also gives a picture of the screen, for what the tree can't say (images, layout, colors) — when the app can take one.`,
		InputSchema: schema(`{"type":"object","properties":{"picture":{"type":"boolean","description":"Also a picture of the screen"}}}`),
	},
	{
		Name: "ui_act",
		Description: `Do an op on a control by its id or key: e.g. read a field or a page's text, write into a field, press a button, toggle a switch, pick an option. Ops marked deny are for the user only; confirm ones wait for their yes. ` +
			`A page or dialog node marked behind is under what shows (another page, a dialog): its controls still work, but the user does not see them act — when they are watching, go to that page first unless it is a small aside. ` +
			`A container (many of the same thing: a mail list, a thread's messages) shows only a preview of its entries, not their controls: fetch one with its op "item" (args: id, or index, or query) and the answer is that entry as a tree of its own, with ids and keys to act on next (e.g. item {id: "42"} on mail.list → mail.list[42].reply). "items" pages through all its entries' keys and names. An entry's key — container key + [id], controls in it under that, mail.list[42].reply — can also be acted on straight away, even off screen: it is fetched (scrolled to) first. scroll_to / scroll move the container.`,
		InputSchema: schema(`{"type":"object","properties":{"node":{"type":"string","description":"The control's id or key from the tree"},"op":{"type":"string","description":"One of its ops"},"args":{"type":"object","description":"The op's arguments, e.g. { \"text\": \"…\" }"}},"required":["node","op"]}`),
	},
	{
		Name:        "ui_tool",
		Description: `Run one of the app's own tools (listed with the tree).`,
		InputSchema: schema(`{"type":"object","properties":{"name":{"type":"string"},"args":{"type":"object"}},"required":["name"]}`),
	},
	{
		Name:        "ui_navigate",
		Description: `Take the user to a route of the app (listed with the tree, filling in its :params), or "back". The answer is the new page's tree.`,
		InputSchema: schema(`{"type":"object","properties":{"route":{"type":"string","description":"e.g. /settings/ai, or back"}},"required":["route"]}`),
	},
	{
		Name:        "ui_peek",
		Description: `See another page's controls without taking the user there, to plan: what is on it and the keys to act on after navigating (e.g. peek /settings/ai, then navigate there and act by key). Says whether it is current or as last seen.`,
		InputSchema: schema(`{"type":"object","properties":{"route":{"type":"string","description":"e.g. /settings/ai"}},"required":["route"]}`),
	},
	{
		Name: "ui_handoff",
		Description: `Only when the user is away (the other ui_ tools answer code away): do what you can with your other tools, then leave the user a handoff for when they come back — a short message, and where to take them: route, the page to open first (one of the routes), then calls, ops to run there in order. The app usually shows it as a notification, and runs it when they tap. ` +
			`A call names a control by its key, never its id (ids don't last until then): e.g. {key: "drafts.list[42]", op: "press"} to open the draft you wrote. Keep it to bringing them to the result — open the page, the item; nothing that sends, pays, deletes or can't be undone: they see it happen, and ops that need their yes still ask. At most 20 calls; message at most 500 characters, in the user's language.`,
		InputSchema: schema(`{"type":"object","properties":{"message":{"type":"string","description":"What you did and what is waiting for them, in a sentence or two"},"route":{"type":"string","description":"The page to open first, e.g. /drafts"},"calls":{"type":"array","description":"Then these, in order: { key, op, args? }","items":{"type":"object","properties":{"key":{"type":"string"},"op":{"type":"string"},"args":{"type":"object"}},"required":["key","op"]}}},"required":["message"]}`),
	},
}

func isAgentTool(name string) bool {
	for _, t := range AgentTools {
		if t.Name == name {
			return true
		}
	}
	return false
}

// ToCall is one of AgentTools called by the agent → what the app should run (nil for ui_look: just send the context; ui_handoff
// is not one, and an unknown tool is an error).
func ToCall(tool string, args map[string]any) (*Call, error) {
	obj := func(v any) map[string]any {
		if m, ok := v.(map[string]any); ok {
			return m
		}
		return map[string]any{}
	}
	str := func(v any) string {
		if v == nil {
			return ""
		}
		return jsStringAny(v)
	}
	switch tool {
	case "ui_look":
		return nil, nil
	case "ui_act":
		return &Call{Kind: CallNode, Node: str(args["node"]), Op: str(args["op"]), Args: obj(args["args"])}, nil
	case "ui_tool":
		return &Call{Kind: CallTool, Tool: str(args["name"]), Args: obj(args["args"])}, nil
	case "ui_navigate":
		return &Call{Kind: CallNavigate, Navigate: str(args["route"])}, nil
	case "ui_peek":
		return &Call{Kind: CallPeek, Peek: str(args["route"])}, nil
	case "ui_handoff":
		return nil, errors.New("ui_handoff is not a call to the app: it goes to the host (Remote with OnHandoff)")
	}
	return nil, errors.New("Not an AffordKit tool: " + tool)
}

// DescribeUserActions is what the user did themselves since the agent last looked, as text for it: one line each, then what that
// means for its work. Empty when they did nothing.
func DescribeUserActions(actions []UserAction) string {
	if len(actions) == 0 {
		return ""
	}
	what := func(a UserAction) string {
		node := ""
		if a.Node != nil {
			ref := a.Node.ID
			if a.Node.Key != "" {
				ref = a.Node.Key
			}
			node = "[" + ref + "] " + a.Node.Role
			if a.Node.Name != "" {
				node += ` "` + a.Node.Name + `"`
			}
		}
		value := ""
		if a.Value != nil {
			value = ` "` + *a.Value + `"`
		}
		switch a.Op {
		case "navigate":
			if a.Route != nil {
				return "went to " + *a.Route
			}
			return "went to another page"
		case "back":
			if a.Route != nil && *a.Route != "" {
				return "went back (to " + *a.Route + ")"
			}
			return "went back"
		case "press":
			return "pressed " + node
		case "write", "append":
			return "typed" + value + " into " + node
		case "toggle":
			return "switched " + node + value
		case "select":
			return "picked" + value + " in " + node
		}
		return jsTrim(a.Op + " " + node + value)
	}
	lines := []string{"Meanwhile the user did this themselves:"}
	for _, a := range actions {
		lines = append(lines, "- "+what(a))
	}
	lines = append(lines, "The screen below is as it is after that. Work with it: don't undo what they did; if it changes what they want, or gets in the way of the goal, stop and ask them.")
	return strings.Join(lines, "\n")
}

// DescribeResult is a result as text for the agent.
func DescribeResult(r *CallResult) string {
	if !r.OK {
		if r.NeedsConfirm {
			return "Waiting: " + r.Error
		}
		if r.Code != "" {
			return "Failed (" + string(r.Code) + "): " + r.Error
		}
		return "Failed: " + r.Error
	}
	kind := rawKind(r.Value)
	if r.Call.Kind == CallPeek && kind == '{' {
		var page PagePeek
		if json.Unmarshal(r.Value, &page) == nil {
			return DescribePage(&page, DescribeOptions{})
		}
	}
	if r.Call.Kind == CallNavigate {
		if k := rawKind(r.Value); k == 0 || k == 'n' {
			return "Now at " + r.Call.Navigate + "."
		}
		return "Now at " + jsToString(r.Value) + "."
	}
	if r.Call.Kind == CallNode && r.Call.Op == "items" && kind == '{' {
		var m map[string]json.RawMessage
		if json.Unmarshal(r.Value, &m) == nil && rawKind(m["items"]) == '[' {
			var page ItemsPage
			if json.Unmarshal(r.Value, &page) == nil {
				return DescribeItems(&page)
			}
		}
	}
	if r.Call.Kind == CallNode && r.Call.Op == "item" && kind == '{' {
		var m map[string]json.RawMessage
		if json.Unmarshal(r.Value, &m) == nil && jsTruthy(m["root"]) {
			var item ItemTree
			if json.Unmarshal(r.Value, &item) == nil {
				return DescribeItem(&item, DescribeOptions{})
			}
		}
	}
	if img, ok := isImage(r.Value); ok {
		return DescribeImage(img)
	}
	if kind == 0 {
		return "Done."
	}
	if s, ok := rawString(r.Value); ok {
		return s
	}
	return jsStringify(r.Value)
}

// DescribeImage is a picture as text (the picture itself goes beside it, where the agent's stack can take one).
func DescribeImage(v *ImageValue) string {
	size := ""
	if v.Width != 0 && v.Height != 0 {
		size = jsNumber(v.Width) + "×" + jsNumber(v.Height) + " "
	}
	if v.Data != "" {
		return "(A picture, " + size + v.Mime + ": attached.)"
	}
	where := v.URL
	if where == "" {
		where = "an unknown place"
	}
	s := ""
	if size != "" {
		s = ", " + strings.TrimSpace(size)
	}
	return "(A picture at " + where + s + ": it could not be read here.)"
}

// DescribeItem is a fetched entry as text: what it is, then its tree.
func DescribeItem(item *ItemTree, opts DescribeOptions) string {
	ref := item.ID
	if item.Key != "" {
		ref = item.Key
	}
	head := "Entry " + ref
	if item.Index != nil {
		head += " #" + jsNumber(*item.Index)
	}
	if item.Source == "preview" {
		head += " — built off screen: its ids cannot be acted on, act by key (that brings it in)"
	}
	return strings.Join(append([]string{head + ":"}, treeLines(&item.Root, opts.max(200))...), "\n")
}

// DescribeItems is a page of a container's entries as text: one per line, by key (or id).
func DescribeItems(page *ItemsPage) string {
	end := page.Offset + float64(len(page.Items))
	var head string
	if len(page.Items) > 0 {
		head = "Items " + jsNumber(page.Offset) + "–" + jsNumber(end-1)
		if page.Count != nil {
			head += " of " + jsNumber(*page.Count)
		}
		head += ":"
	} else {
		head = "No items"
		if page.Offset != 0 {
			head += " from " + jsNumber(page.Offset)
		}
		if page.Count != nil {
			head += " (" + jsNumber(*page.Count) + " in all)"
		}
		head += "."
	}
	lines := []string{head}
	for _, i := range page.Items {
		lines = append(lines, "  "+summaryLine(i))
	}
	return strings.Join(lines, "\n")
}
