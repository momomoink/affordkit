"""
The AffordKit protocol, as far as the agent's side uses it: what an app's UI looks like to an AI agent, and how the agent acts on it.
The same format on every platform (DOM, Flutter): an app builds a tree of the controls on screen (context), the agent reads it and
answers with calls, the app runs them and the results go back to the agent as the next round's context.

- Only controls that mean something are in the tree; a node says what it is, what it's called, a short state — never its content:
  that is read on demand (the "read" op), so the first round stays small.
- Each operation has a policy: allow (just do it), confirm (only after the user says yes), deny (the agent can see it but never do
  it — e.g. the button that sends an email).
- The app's pages are routes: the agent knows where the user is, can take them elsewhere (navigate, or back), and can look at another
  page's tree before going there (peek).
- Many of the same thing (a mail list, a thread's messages) is a container: ONE node in the tree with a short preview of its entries;
  the agent fetches an entry with the container's ``item`` op, or pages through all entries' summaries (``items``).
- When the user has left the app, its screen can't be worked: the agent may leave a handoff — a message, and calls by key that take
  the user to what it did when they come back.
- What the user does themselves meanwhile comes with the next answer (userActions), with the tree after it.

Everything here is plain JSON data — dicts with the protocol's own (camelCase) keys, exactly as they go over the wire. The TypedDicts
below only describe them.
"""

from __future__ import annotations

import math
import re
import time
from typing import Any, Dict, List, Literal, Optional, Tuple, TypedDict, TypeGuard, Union
from urllib.parse import unquote

from ._js import js_len, js_str, js_trim, nullish

PROTOCOL_VERSION = 1

Role = Literal[
    "app", "page", "region", "dialog", "button", "link", "textbox", "checkbox", "switch", "radio", "select", "tab", "container",
    "list", "listitem", "heading", "text", "image", "other",
]  # fmt: skip

Policy = Literal["allow", "confirm", "deny"]

#: Why a call failed, for the agent's loop to act on (the error says it in words): not_found (no such node, route, tool or entry),
#: no_op (the node has no such op), bad_args, denied (policy deny: the user does this themselves), needs_confirm (policy confirm and
#: no way to ask: nothing was done), declined (the user said no), disabled, unreachable (something is over it), timeout (the app did
#: not answer in time), unavailable (no app to work, or it could not answer), away (the user is not in the app now), expired (a
#: handoff past its expiresAt), failed (anything else).
ErrorCode = Literal[
    "not_found", "no_op", "bad_args", "denied", "needs_confirm", "declined", "disabled", "unreachable", "timeout", "unavailable",
    "away", "expired", "failed",
]  # fmt: skip

StateValue = Union[str, int, float, bool]


class ParamsSchema(TypedDict, total=False):
    """A JSON Schema (an object's properties) for an operation's or a tool's arguments."""

    type: Literal["object"]
    properties: Dict[str, Dict[str, Any]]
    required: List[str]


class _OpSpecBase(TypedDict):
    name: str
    policy: Policy


class OpSpec(_OpSpecBase, total=False):
    """What can be done to a node."""

    description: str
    params: ParamsSchema


class _ItemSummaryBase(TypedDict):
    id: str
    name: str


class ItemSummary(_ItemSummaryBase, total=False):
    """One entry of a container, as its preview and its ``items`` op give it. key: ``<container key>[<id>]``, when the container has a key."""

    key: str
    index: int
    description: str


class _ItemsPageBase(TypedDict):
    offset: int
    items: List[ItemSummary]


class ItemsPage(_ItemsPageBase, total=False):
    """A page of a container's entries: the ``items`` op's answer. count: all the items (not only this page), when known."""

    count: int


class _AffordNodeBase(TypedDict):
    id: str
    role: Role
    name: str
    ops: List[OpSpec]


class AffordNode(_AffordNodeBase, total=False):
    """
    A control on screen. id: stable while it stays on screen, what calls refer to. key: a name the app gives it that stays the same
    across pages and visits (calls may use it instead of the id). name: what the user sees it called. state: a short state, never the
    content. value: what a text or heading shows (cut short). preview: a container's entries on screen, in short.
    """

    key: str
    description: str
    state: Dict[str, StateValue]
    value: str
    children: List["AffordNode"]
    preview: List[ItemSummary]


#: The AffordTree: the screen's controls as a tree (a context's root).
AffordTree = AffordNode


class _ItemTreeBase(TypedDict):
    id: str
    source: Literal["live", "preview"]
    root: AffordNode


class ItemTree(_ItemTreeBase, total=False):
    """
    One entry of a container, fetched (the ``item`` op's answer): a tree of its own. live: on screen now, its ids can be acted on;
    preview: built off screen, ids not live (act by key: that brings it in).
    """

    key: str
    index: int


class UserActionNode(TypedDict, total=False):
    id: str
    key: str
    role: Role
    name: str


class _UserActionBase(TypedDict):
    at: float
    op: str


class UserAction(_UserActionBase, total=False):
    """
    Something the user did themselves while the agent was working their screen, named the way the agent would have called it: press,
    write, toggle, select, scroll on a node; navigate (to route) or back. at: ms since the epoch. value: what they typed or picked, cut
    short. route: the route after it.
    """

    node: UserActionNode
    value: str
    route: str


class _ToolSpecBase(TypedDict):
    name: str
    description: str
    policy: Policy


class ToolSpec(_ToolSpecBase, total=False):
    """An app-wide operation, not tied to a control (same shape as a WebMCP tool)."""

    inputSchema: ParamsSchema


class RouteParam(TypedDict, total=False):
    description: str
    values: List[str]


class _RouteSpecBase(TypedDict):
    path: str
    description: str


class RouteSpec(_RouteSpecBase, total=False):
    """A place in the app the agent can go to. path: a pattern such as /settings/:tab. params: what each :param can be."""

    params: Dict[str, RouteParam]


class _RouteStateBase(TypedDict):
    current: str
    routes: List[RouteSpec]


class RouteState(_RouteStateBase, total=False):
    """Where the user is (current, the pattern it is and its params), whether back goes somewhere, and where the agent can take them."""

    pattern: str
    params: Dict[str, str]
    canGoBack: bool


class _AffordContextBase(TypedDict):
    protocol: int
    root: AffordNode
    tools: List[ToolSpec]


class AffordContext(_AffordContextBase, total=False):
    """The screen as the app gives it: the route, the AffordTree, the app's own tools."""

    route: RouteState


class _PagePeekBase(TypedDict):
    route: str
    source: Literal["live", "preview", "seen", "declared"]


class PagePeek(_PagePeekBase, total=False):
    """
    Another page's tree, peeked at without going there (its ids are not live). live: the page showing now; preview: built off screen
    just now; seen: as it was the last time it showed (seenAt, ms); declared: never seen, only what the route says (no tree).
    """

    pattern: str
    seenAt: float
    description: str
    root: AffordNode


#: One thing the agent asks for: an op on a node (by id, or key), an app-wide tool, going to a route (or "back"), or a peek at one:
#: ``{"node", "op", "args"}``, ``{"tool", "args"}``, ``{"navigate"}``, ``{"peek"}``.
Call = Dict[str, Any]


class _CallResultBase(TypedDict):
    call: Call
    ok: bool


class CallResult(_CallResultBase, total=False):
    """A call's result: value (what a read returned, what a tool answered), or error and code; needsConfirm: waiting for the user's yes."""

    value: Any
    error: str
    code: ErrorCode
    needsConfirm: bool


#: What goes from the agent's side to the app: ``{"look": True, "picture"?: True}`` or ``{"calls": [...]}``.
UiRequest = Dict[str, Any]

#: The app's answer: ``{"context", "results"?, "picture"?, "userActions"?}``, or ``{"error", "code"?}`` when it couldn't.
UiAnswer = Dict[str, Any]


class _ImageValueBase(TypedDict):
    type: Literal["image"]
    mime: str


class ImageValue(_ImageValueBase, total=False):
    """A picture (what op view answers, and a look with picture): PNG / JPEG as base64, or where it is when it couldn't be read."""

    data: str
    url: str
    width: int
    height: int


class AffordError(Exception):
    """An error with its code (raised by the kit, and by a transport or a handoff host when it wants to say which)."""

    def __init__(self, code: ErrorCode, message: str) -> None:
        super().__init__(message)
        self.code: ErrorCode = code
        self.message = message


def is_image(v: Any) -> TypeGuard[ImageValue]:
    """Whether a value is a picture."""
    return isinstance(v, dict) and v.get("type") == "image" and isinstance(v.get("mime"), str)


class _HandoffCallBase(TypedDict):
    key: str
    op: str


class HandoffCall(_HandoffCallBase, total=False):
    """One step of a handoff: an op on a control by its key (a handoff runs later, when ids from a look have long gone)."""

    args: Dict[str, Any]


class _HandoffBase(TypedDict):
    v: Literal[1]
    message: str
    calls: List[HandoffCall]


class Handoff(_HandoffBase, total=False):
    """
    What an agent leaves for a user who is away: a short message, and the calls that take them to what it did when they come back —
    the page first (route), then ops there by key. The host keeps it and tells the user (a notification, usually); when they tap it,
    the app runs it. One-shot, and it expires (expiresAt, ms since the epoch). id: the host's, set when it stores it.
    """

    route: str
    expiresAt: float
    id: str


#: Most calls in a handoff.
HANDOFF_MAX_CALLS = 20

#: Longest message of a handoff (in UTF-16 code units, as JavaScript counts).
HANDOFF_MAX_MESSAGE = 500

_LOOK_ID = re.compile(r"(?:[nwp][0-9]+|app|behind-[0-9]+)")


def _is_look_id(ref: str) -> bool:
    """Whether a node ref is an id from a look (the kit's: n12, w4, p3, app, behind-2, peek:…) rather than a key the app gave."""
    return ref.startswith("peek:") or _LOOK_ID.fullmatch(ref) is not None


def _finite_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def handoff_problem(input: Any) -> Optional[str]:
    """What is wrong with something given as a handoff (its shape, not whether it expired), or None when it is one."""

    def obj(v: Any) -> bool:
        return isinstance(v, dict)

    if not obj(input):
        return "A handoff is an object: { message, route?, calls? }"
    if "v" in input and not (input["v"] == 1 and not isinstance(input["v"], bool)):
        return f"Unknown handoff version {js_str(input['v'])}"
    message = js_trim(input["message"]) if isinstance(input.get("message"), str) else ""
    if not message:
        return "Say what you did in message: the user reads it"
    if js_len(message) > HANDOFF_MAX_MESSAGE:
        return f"message is too long ({js_len(message)} characters, at most {HANDOFF_MAX_MESSAGE})"
    if "route" in input:
        route = input["route"]
        if not isinstance(route, str) or not js_trim(route) or js_trim(route) == "back":
            return "route is a route of the app (e.g. /drafts), or left out"
    if "expiresAt" in input and not _finite_number(input["expiresAt"]):
        return "expiresAt is a time in ms"
    if "id" in input and not isinstance(input["id"], str):
        return "id is a string"
    calls = input.get("calls")
    if nullish(calls):
        calls = []
    if not isinstance(calls, list):
        return "calls is a list of { key, op, args? }"
    if len(calls) > HANDOFF_MAX_CALLS:
        return f"Too many calls ({len(calls)}, at most {HANDOFF_MAX_CALLS}): take the user to the result, no more"
    for i, c in enumerate(calls):
        # (a key, as ui_act's node or as key)
        key = (c.get("key") if c.get("key") is not None else c.get("node")) if obj(c) else None
        if not obj(c) or not isinstance(key, str) or not key or not isinstance(c.get("op"), str) or not c["op"]:
            return f"calls[{i}] is not {{ key, op, args? }}"
        if _is_look_id(key):
            return f"calls[{i}]: {key} is an id from a look, gone by the time the user comes back: use the control's key"
        if "args" in c and not obj(c["args"]):
            return f"calls[{i}].args is an object"
    return None


def _now_ms() -> int:
    return int(time.time() * 1000)


def handoff_expired(handoff: Dict[str, Any], now: Optional[float] = None) -> bool:
    """Whether a handoff's time is up (now: ms since the epoch, default the time now)."""
    exp = handoff.get("expiresAt")
    return exp is not None and exp <= (_now_ms() if now is None else now)


def parse_handoff(input: Any, now: Optional[float] = None) -> Optional[Handoff]:
    """Something given as a handoff (the agent's input, what the host stored), checked and in its plain shape; None when it isn't one or it expired."""
    if handoff_problem(input):
        return None
    h: Dict[str, Any] = input
    out: Dict[str, Any] = {"v": 1, "message": js_trim(h["message"])}
    if isinstance(h.get("route"), str):
        out["route"] = js_trim(h["route"])
    calls = h.get("calls") or []
    out["calls"] = []
    for c in calls:
        call: Dict[str, Any] = {"key": c.get("key") if c.get("key") is not None else c.get("node"), "op": c["op"]}
        if c.get("args") is not None:  # (an object: truthy in JavaScript even when empty)
            call["args"] = c["args"]
        out["calls"].append(call)
    if _finite_number(h.get("expiresAt")):
        out["expiresAt"] = h["expiresAt"]
    if isinstance(h.get("id"), str):
        out["id"] = h["id"]
    return None if handoff_expired(out, now) else out  # type: ignore[return-value]


def _split(p: str) -> List[str]:
    return [s for s in re.split(r"[?#]", p)[0].split("/") if s]


_BAD_ESCAPE = re.compile(r"%(?![0-9A-Fa-f]{2})")


def _decode_uri_component(s: str) -> str:
    """``decodeURIComponent``: %XX escapes as UTF-8; a malformed one raises ValueError (JavaScript's URIError)."""
    if "%" not in s:
        return s
    if _BAD_ESCAPE.search(s):
        raise ValueError(f"URI malformed: {s}")
    return unquote(s, errors="strict")  # (bad UTF-8: UnicodeDecodeError, a ValueError)


def match_route(pattern: str, route: str) -> Optional[Dict[str, str]]:
    """
    A route's params if it is this pattern (/settings/:tab against /settings/ai → {"tab": "ai"}), else None. A trailing * matches the
    rest. A param with a malformed %-escape (/b/%zz) is not this route: None.
    """
    want = _split(pattern)
    got = _split(route)
    tail = bool(want) and want[-1] == "*"
    if (len(got) < len(want) - 1) if tail else (len(got) != len(want)):
        return None
    params: Dict[str, str] = {}
    for i, w in enumerate(want):
        if w == "*":
            break
        if w.startswith(":"):
            try:
                params[w[1:]] = _decode_uri_component(got[i])
            except ValueError:
                return None
        elif w != got[i]:
            return None
    return params


class RouteMatch(TypedDict):
    spec: RouteSpec
    params: Dict[str, str]


def find_route(routes: List[RouteSpec], route: str) -> Optional[RouteMatch]:
    """
    The pattern a route is, and its params: the most specific of those that match — one without a catch-all (*) before one with,
    then the fewest params, then the most fixed segments; on a tie, the first listed.
    """

    def rank(path: str, params: Dict[str, str]) -> Tuple[int, int, int]:
        parts = _split(path)
        return (1 if parts and parts[-1] == "*" else 0, len(params), -sum(1 for p in parts if p != "*" and not p.startswith(":")))

    best: Optional[RouteMatch] = None
    best_rank: Optional[Tuple[int, int, int]] = None
    for spec in routes:
        params = match_route(spec["path"], route)
        if params is None:
            continue
        r = rank(spec["path"], params)
        if best_rank is None or r < best_rank:
            best, best_rank = {"spec": spec, "params": params}, r
    return best
