"""
The agent's side of AffordKit, for whatever runs the model: the context as compact text for a prompt, and the tools an agent uses to
act on the app — each turned into a Call for the app.
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Optional, Tuple, TypedDict

from ._js import UNDEFINED, coalesce, get, iso_ms, is_num, js_entries, js_join, js_json, js_str, js_trim, js_truthy, strict_eq
from .protocol import AffordContext, AffordNode, Call, CallResult, ItemsPage, ItemTree, PagePeek, ParamsSchema, RouteState, UserAction, is_image


def _quoted(name: Any) -> str:
    """' "name"' when there is a name (a template's ${n.name ? ` "${n.name}"` : ''})."""
    return f' "{js_str(name)}"' if js_truthy(name) else ""


def _route_lines(route: RouteState) -> List[str]:
    rp = get(route, "params")
    params = f" ({', '.join(f'{k}={js_str(v)}' for k, v in js_entries(rp))})" if isinstance(rp, dict) and rp else ""
    current, pattern = get(route, "current"), get(route, "pattern")
    head = f"Route: {js_str(current)}"
    if js_truthy(pattern) and not strict_eq(pattern, current):
        head += f" = {js_str(pattern)}{params}"
    if js_truthy(get(route, "canGoBack")):
        head += " — can go back"
    lines = [head]
    routes = route.get("routes") or []
    if routes:
        lines.append("Routes:")
        for r in routes:
            ps = []
            for k, p in js_entries(coalesce(get(r, "params"), {})):
                values = get(p, "values")
                desc = get(p, "description")
                among = " ∈ {" + js_join(values if isinstance(values, list) else [values], ", ") + "}" if js_truthy(values) else ""
                ps.append(f":{k}{among}{f' ({js_str(desc)})' if js_truthy(desc) else ''}")
            lines.append(f"  {js_str(get(r, 'path'))} — {js_str(get(r, 'description'))}{'; ' + '; '.join(ps) if ps else ''}")
    return lines


def _node_line(n: AffordNode) -> str:
    """One node as a line (no children): [id key=…] role "name" (state) — description — ops."""
    # A container: what of, how many, which show, and how its entries' keys go — then only the other state
    lst = ""
    state = coalesce(get(n, "state"), {})
    entries: List[Tuple[str, Any]] = js_entries(state) if isinstance(state, dict) else []
    key = get(n, "key")
    if get(n, "role") == "container":
        count, first, last, kind = get(state, "count"), get(state, "first"), get(state, "last"), get(state, "kind")
        if js_truthy(kind):
            lst += f" ({js_str(kind)})"
        if is_num(count):
            lst += f" {js_str(count)} entr{'y' if count == 1 else 'ies'}"
        if is_num(first):
            lst += f", showing {js_str(first)}–{js_str(last)}"
        if js_truthy(key):
            lst += f" (entry keys: {js_str(key)}[<id>])"
        entries = [(k, v) for k, v in entries if k not in ("count", "first", "last", "kind")]
    st = f" ({', '.join(k if v is True else f'{k}: {js_str(v)}' for k, v in entries)})" if entries else ""
    ops = ", ".join(js_str(get(o, "name")) if get(o, "policy") == "allow" else f"{js_str(get(o, 'name'))}({js_str(get(o, 'policy'))})" for o in (get(n, "ops") or []))
    nid = f"{js_str(get(n, 'id'))} key={js_str(key)}" if js_truthy(key) else js_str(get(n, "id"))
    # (what it shows, when it isn't its name already)
    value = get(n, "value")
    name = get(n, "name")
    shown = f" = {js_json(value)}" if value is not UNDEFINED and not strict_eq(value, name) else ""
    desc = get(n, "description")
    return (
        f"[{nid}] {js_str(get(n, 'role'))}{_quoted(name)}{shown}{lst}{st}"
        f"{f' — {js_str(desc)}' if js_truthy(desc) else ''}{f' — {ops}' if ops else ''}"
    )


def _preview_lines(n: AffordNode, pad: str) -> List[str]:
    """A container's entries on screen, in short (fetch one, op item, for its controls)."""
    preview = get(n, "preview")
    if not isinstance(preview, list) or not preview:
        return []
    lines = [_summary_line(i, f"{pad}· ") for i in preview]
    count = get(get(n, "state"), "count")
    more = count - len(preview) if is_num(count) else 0
    lines.append(f"{pad}· …{f' {js_str(more)} more;' if more > 0 else ''} op item fetches an entry's controls, items pages through them")
    return lines


def _summary_line(i: Any, lead: str) -> str:
    """An entry in short: [key] #index "name" — description."""
    index = get(i, "index")
    desc = get(i, "description")
    return f"{lead}[{js_str(coalesce(get(i, 'key'), get(i, 'id')))}]{f' #{js_str(index)}' if index is not UNDEFINED else ''} {js_json(get(i, 'name'))}{f' — {js_str(desc)}' if js_truthy(desc) else ''}"


def _tree_lines(root: AffordNode, max_nodes: int) -> List[str]:
    lines: List[str] = []
    count = 0

    def walk(n: AffordNode, depth: int) -> None:
        nonlocal count
        count += 1
        if count - 1 >= max_nodes:
            return
        lines.append("  " * depth + _node_line(n))
        for c in get(n, "children") or []:
            walk(c, depth + 1)
        lines.extend(_preview_lines(n, "  " * (depth + 1)))

    walk(root, 0)
    if count > max_nodes:
        lines.append(f"… {js_str(count - max_nodes)} more nodes")
    return lines


def describe(ctx: AffordContext, *, max_nodes: int = 400) -> str:
    """
    The context as indented lines: the route, the routes, the tools, then the tree — ``[n12 key=compose.send] button "Send" —
    press(deny)``, a container as ``[n3 key=mail.list] container "Inbox" (list) 312 entries, showing 0–14 (entry keys:
    mail.list[<id>]) — read, item, items, scroll_to, scroll`` with its preview under it (``· [mail.list[42]] #3 "Lunch?"``).
    """
    lines: List[str] = []
    route = get(ctx, "route")
    if js_truthy(route):
        lines.extend(_route_lines(route))
    tools = get(ctx, "tools") or []
    if tools:
        lines.append(
            "Tools: "
            + "; ".join(
                f"{js_str(get(t, 'name'))}{'(' + js_str(get(t, 'policy')) + ')' if get(t, 'policy') != 'allow' else ''} — {js_str(get(t, 'description'))}" for t in tools
            )
        )
    lines.extend(_tree_lines(ctx["root"], max_nodes))
    return "\n".join(lines)


class _Seen(TypedDict, total=False):
    node: AffordNode
    line: str
    parent: AffordNode


def _ref(n: Any) -> Any:
    """A node's identity across two screens: its key, else its id."""
    return coalesce(get(n, "key"), get(n, "id"))


def describe_change(before: AffordContext, after: AffordContext, *, max_nodes: int = 400, whole_over: float = 0.5) -> str:
    """
    What changed on screen between two contexts, as text — what the agent gets after an act instead of the whole tree again: the
    route if it changed, then the nodes that came (+, under the node they are in), went (-) or changed (~). When most of the screen
    changed (another page), the whole new screen instead. Nodes are matched by key, else id (ids stay with their widget).
    """

    def flat(root: AffordNode) -> Dict[Any, _Seen]:
        out: Dict[Any, _Seen] = {}

        def walk(n: AffordNode, parent: Optional[AffordNode] = None) -> None:
            seen: _Seen = {"node": n, "line": _node_line(n) + "".join(_preview_lines(n, " "))}
            if parent is not None:
                seen["parent"] = parent
            out[_ref(n)] = seen
            for c in get(n, "children") or []:
                walk(c, n)

        walk(root)
        return out

    was = flat(before["root"])
    now = flat(after["root"])
    came = [(k, v) for k, v in now.items() if k not in was]
    went = [(k, v) for k, v in was.items() if k not in now]
    changed = [(k, v) for k, v in now.items() if k in was and was[k]["line"] != v["line"]]
    lines: List[str] = []
    frm = get(get(before, "route"), "current")
    to = get(get(after, "route"), "current")
    if js_truthy(to) and not strict_eq(to, frm):
        lines.append(f"Now at {js_str(to)}{f' (was {js_str(frm)})' if js_truthy(frm) else ''}{' — can go back' if js_truthy(get(get(after, 'route'), 'canGoBack')) else ''}.")
    if len(came) + len(went) > max(4, len(now) * whole_over):
        lines.extend(["The screen now:", describe(after, max_nodes=max_nodes)])
        return "\n".join(lines)
    if not came and not went and not changed:
        lines.append("The screen did not change.")
        return "\n".join(lines)

    # A page that went under what is on top (a dialog opened, a page pushed) or came back from under it: its controls didn't change, say so
    def under(s: _Seen) -> int:
        total = 0

        def count(x: Any) -> None:
            nonlocal total
            for c in get(x, "children") or []:
                total += 1
                count(c)

        count(s["node"])
        return total

    def where(s: _Seen) -> str:
        p = s.get("parent")
        if p is None or get(p, "role") == "app":
            return ""
        pname = get(p, "name")
        return f" (in {js_str(_ref(p))}{_quoted(pname)})"

    def named(n: Any) -> str:
        name = get(n, "name")
        return f"{js_str(get(n, 'role'))}{_quoted(name)}"

    for _, s in came[:max_nodes]:
        node = s["node"]
        if js_truthy(get(get(node, "state"), "behind")):
            lines.append(f"+ [{js_str(get(node, 'id'))}] {named(node)} (behind) — now under what shows: its {under(s)} controls still work, unseen")
        else:
            lines.append(f"+ {_node_line(node)}{where(s)}")
            lines.extend(_preview_lines(node, "    "))
    for _, s in went[:max_nodes]:
        node = s["node"]
        back = js_truthy(get(get(node, "state"), "behind")) and any(_ref(c) in now for c in get(node, "children") or [])
        lines.append(f"- [{js_str(_ref(node))}] {named(node)}{' — on top again: its controls show' if back else ''}")
    for _, s in changed[:max_nodes]:
        lines.append(f"~ {_node_line(s['node'])}")
        lines.extend(_preview_lines(s["node"], "    "))
    return "\n".join(["The screen changed:", *lines])


def describe_page(view: PagePeek, *, max_nodes: int = 300) -> str:
    """A peeked page as text."""
    seen_at = get(view, "seenAt")
    how = {
        "live": "showing now",
        "preview": "built off screen just now, as it would open",
        "seen": f"as it was when it last showed{f' ({iso_ms(seen_at)})' if js_truthy(seen_at) else ''}",
        "declared": "never seen: only what the route says",
    }.get(view.get("source"), UNDEFINED)
    route, pattern, desc = get(view, "route"), get(view, "pattern"), get(view, "description")
    lines = [
        f"Page {js_str(route)}{f' = {js_str(pattern)}' if js_truthy(pattern) and not strict_eq(pattern, route) else ''} — {js_str(how)}{f'. {js_str(desc)}' if js_truthy(desc) else ''}"
    ]
    root = get(view, "root")
    if js_truthy(root):
        if get(view, "source") != "live":
            lines.append("(Peek ids cannot be acted on: navigate there, then act by key, or look again for live ids.)")
        lines.extend(_tree_lines(root, max_nodes))
    return "\n".join(lines)


class AgentTool(TypedDict):
    """A tool for the model: its name, what it does (for the model to read), and its input's JSON Schema."""

    name: str
    description: str
    inputSchema: ParamsSchema


#: The tools an agent gets for acting on the app's UI (names, descriptions and schemas as in every port).
AGENT_TOOLS: List[AgentTool] = [
    {
        "name": "ui_look",
        "description": (
            "See what is on the user's screen now: the route, and the tree of controls (each with an id — and a key when the app gives one — what it is, "
            "what it shows, its state and the ops it allows). picture: true also gives a picture of the screen, for what the tree can't say (images, layout, "
            "colors) — when the app can take one."
        ),
        "inputSchema": {"type": "object", "properties": {"picture": {"type": "boolean", "description": "Also a picture of the screen"}}},
    },
    {
        "name": "ui_act",
        "description": (
            "Do an op on a control by its id or key: e.g. read a field or a page's text, write into a field, press a button, toggle a switch, pick an option. "
            "Ops marked deny are for the user only; confirm ones wait for their yes. "
            "A page or dialog node marked behind is under what shows (another page, a dialog): its controls still work, but the user does not see them act — "
            "when they are watching, go to that page first unless it is a small aside. "
            "A container (many of the same thing: a mail list, a thread's messages) shows only a preview of its entries, not their controls: fetch one with "
            'its op "item" (args: id, or index, or query) and the answer is that entry as a tree of its own, with ids and keys to act on next (e.g. item '
            '{id: "42"} on mail.list → mail.list[42].reply). "items" pages through all its entries\' keys and names. An entry\'s key — container key + [id], '
            "controls in it under that, mail.list[42].reply — can also be acted on straight away, even off screen: it is fetched (scrolled to) first. "
            "scroll_to / scroll move the container."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "node": {"type": "string", "description": "The control's id or key from the tree"},
                "op": {"type": "string", "description": "One of its ops"},
                "args": {"type": "object", "description": 'The op\'s arguments, e.g. { "text": "…" }'},
            },
            "required": ["node", "op"],
        },
    },
    {
        "name": "ui_tool",
        "description": "Run one of the app's own tools (listed with the tree).",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}, "args": {"type": "object"}}, "required": ["name"]},
    },
    {
        "name": "ui_navigate",
        "description": 'Take the user to a route of the app (listed with the tree, filling in its :params), or "back". The answer is the new page\'s tree.',
        "inputSchema": {"type": "object", "properties": {"route": {"type": "string", "description": "e.g. /settings/ai, or back"}}, "required": ["route"]},
    },
    {
        "name": "ui_peek",
        "description": (
            "See another page's controls without taking the user there, to plan: what is on it and the keys to act on after navigating (e.g. peek "
            "/settings/ai, then navigate there and act by key). Says whether it is current or as last seen."
        ),
        "inputSchema": {"type": "object", "properties": {"route": {"type": "string", "description": "e.g. /settings/ai"}}, "required": ["route"]},
    },
    {
        "name": "ui_handoff",
        "description": (
            "Only when the user is away (the other ui_ tools answer code away): do what you can with your other tools, then leave the user a handoff for "
            "when they come back — a short message, and where to take them: route, the page to open first (one of the routes), then calls, ops to run there "
            "in order. The app usually shows it as a notification, and runs it when they tap. "
            'A call names a control by its key, never its id (ids don\'t last until then): e.g. {key: "drafts.list[42]", op: "press"} to open the draft you '
            "wrote. Keep it to bringing them to the result — open the page, the item; nothing that sends, pays, deletes or can't be undone: they see it "
            "happen, and ops that need their yes still ask. At most 20 calls; message at most 500 characters, in the user's language."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "What you did and what is waiting for them, in a sentence or two"},
                "route": {"type": "string", "description": "The page to open first, e.g. /drafts"},
                "calls": {
                    "type": "array",
                    "description": "Then these, in order: { key, op, args? }",
                    "items": {"type": "object", "properties": {"key": {"type": "string"}, "op": {"type": "string"}, "args": {"type": "object"}}, "required": ["key", "op"]},
                },
            },
            "required": ["message"],
        },
    },
]


def to_call(tool: str, args: Dict[str, Any]) -> Optional[Call]:
    """
    One of AGENT_TOOLS called by the agent → what the app should run (None for ui_look: just send the context). Raises ValueError for
    ui_handoff (not a call to the app: it goes to the host) and for a name that isn't one of the tools.
    """

    def obj(v: Any) -> Any:
        # (an object or an array, as JavaScript's typeof 'object' takes it)
        return v if isinstance(v, (dict, list)) else {}

    def s(v: Any) -> str:
        return js_str(coalesce(v, ""))

    if tool == "ui_look":
        return None
    if tool == "ui_act":
        return {"node": s(get(args, "node")), "op": s(get(args, "op")), "args": obj(get(args, "args"))}
    if tool == "ui_tool":
        return {"tool": s(get(args, "name")), "args": obj(get(args, "args"))}
    if tool == "ui_navigate":
        return {"navigate": s(get(args, "route"))}
    if tool == "ui_peek":
        return {"peek": s(get(args, "route"))}
    if tool == "ui_handoff":
        raise ValueError("ui_handoff is not a call to the app: it goes to the host (AffordRemote with on_handoff)")
    raise ValueError(f"Not an AffordKit tool: {tool}")


def describe_user_actions(actions: Optional[List[UserAction]]) -> str:
    """
    What the user did themselves since the agent last looked, as text for it: one line each, then what that means for its work. Empty
    when they did nothing.
    """
    if not isinstance(actions, list) or not actions:
        return ""

    def what(a: Any) -> str:
        n = get(a, "node")
        node = ""
        if js_truthy(n):
            name = get(n, "name")
            node = f"[{js_str(_ref(n))}] {js_str(get(n, 'role'))}{_quoted(name)}"
        v = get(a, "value")
        value = f' "{js_str(v)}"' if v is not UNDEFINED else ""
        op = get(a, "op")
        route = get(a, "route")
        if op == "navigate":
            return f"went to {js_str(coalesce(route, 'another page'))}"
        if op == "back":
            return f"went back{f' (to {js_str(route)})' if js_truthy(route) else ''}"
        if op == "press":
            return f"pressed {node}"
        if op in ("write", "append"):
            return f"typed{value} into {node}"
        if op == "toggle":
            return f"switched {node}{value}"
        if op == "select":
            return f"picked{value} in {node}"
        return js_trim(f"{js_str(op)} {node}{value}")

    return "\n".join(
        [
            "Meanwhile the user did this themselves:",
            *(f"- {what(a)}" for a in actions),
            "The screen below is as it is after that. Work with it: don't undo what they did; if it changes what they want, or gets in the way of the goal, stop and ask them.",
        ]
    )


def describe_result(r: CallResult) -> str:
    """A result as text for the agent."""
    call = get(r, "call")
    if not isinstance(call, dict):
        call = {}
    value = get(r, "value")
    if not js_truthy(get(r, "ok")):
        code = get(r, "code")
        error = js_str(get(r, "error"))
        return f"Waiting: {error}" if js_truthy(get(r, "needsConfirm")) else f"Failed{f' ({js_str(code)})' if js_truthy(code) else ''}: {error}"
    is_obj = js_truthy(value) and isinstance(value, (dict, list))
    if "peek" in call and is_obj:
        return describe_page(value)
    if "navigate" in call:
        return f"Now at {js_str(coalesce(value, call['navigate']))}."
    if "op" in call and call["op"] == "items" and is_obj and isinstance(get(value, "items"), list):
        return describe_items(value)
    if "op" in call and call["op"] == "item" and is_obj and js_truthy(get(value, "root")):
        return describe_item(value)
    if is_image(value):
        return describe_image(value)
    if value is UNDEFINED:
        return "Done."
    return value if isinstance(value, str) else js_json(value)


def describe_image(v: Mapping[str, Any]) -> str:
    """A picture as text (the picture itself goes beside it, where the agent's stack can take one)."""
    w, h = get(v, "width"), get(v, "height")
    size = f"{js_str(w)}×{js_str(h)} " if js_truthy(w) and js_truthy(h) else ""
    if js_truthy(get(v, "data")):
        return f"(A picture, {size}{js_str(get(v, 'mime'))}: attached.)"
    return f"(A picture at {js_str(coalesce(get(v, 'url'), 'an unknown place'))}{f', {size.strip()}' if size else ''}: it could not be read here.)"


def describe_item(item: ItemTree, *, max_nodes: int = 200) -> str:
    """A fetched entry as text: what it is, then its tree."""
    index = get(item, "index")
    head = (
        f"Entry {js_str(coalesce(get(item, 'key'), get(item, 'id')))}{f' #{js_str(index)}' if index is not UNDEFINED else ''}"
        f"{' — built off screen: its ids cannot be acted on, act by key (that brings it in)' if get(item, 'source') == 'preview' else ''}:"
    )
    return "\n".join([head, *_tree_lines(item["root"], max_nodes)])


def describe_items(page: ItemsPage) -> str:
    """A page of a container's entries as text: one per line, by key (or id)."""
    items = page["items"]
    offset = get(page, "offset")
    count = get(page, "count")
    of = f" of {js_str(count)}" if count is not UNDEFINED else ""
    if items:
        head = f"Items {js_str(offset)}–{js_str(_add(offset, len(items)) - 1)}{of}:"
    else:
        head = f"No items{f' from {js_str(offset)}' if js_truthy(offset) else ''}{f' ({js_str(count)} in all)' if count is not UNDEFINED else ''}."
    return "\n".join([head, *(_summary_line(i, "  ") for i in items)])


def _add(a: Any, b: int) -> Any:
    # (offset + length, for a numeric offset; anything else as JavaScript would make of it is not worth copying)
    return a + b if is_num(a) else b
