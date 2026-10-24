"""Unit tests beyond the conformance cases: each piece on its own, the edges, and the JavaScript-exact text helpers."""

from __future__ import annotations

import asyncio
import json
import time
from types import SimpleNamespace
from typing import Any, Dict, List

import pytest

from affordkit import (
    AGENT_TOOLS,
    HANDOFF_MAX_CALLS,
    AffordError,
    AffordRemote,
    ToolAnswer,
    anthropic_result,
    anthropic_tools,
    describe,
    describe_change,
    describe_image,
    describe_item,
    describe_items,
    describe_page,
    describe_result,
    describe_user_actions,
    find_route,
    handoff_expired,
    handoff_problem,
    match_route,
    mcp_handlers,
    openai_responses_result,
    openai_responses_tools,
    openai_result,
    openai_tools,
    parse_handoff,
    runners,
    to_call,
)
from affordkit._js import iso_ms, js_json, js_len, js_number, js_str, js_trim, js_truthy

# ---------------- screens ----------------


def node(id: str, role: str, name: str, ops: List[str] = (), **more: Any) -> Dict[str, Any]:  # type: ignore[assignment]
    return {"id": id, "role": role, "name": name, "ops": [{"name": o, "policy": "allow"} for o in ops], **more}


def ctx(children: List[Dict[str, Any]], route: str = "/a", tools: Any = None) -> Dict[str, Any]:
    return {
        "protocol": 1,
        "route": {"current": route, "routes": [{"path": "/a", "description": "A"}, {"path": "/b/:id", "description": "B"}]},
        "tools": tools or [],
        "root": node("app", "app", "App", ["read"], children=children),
    }


def buttons(n: int, prefix: str = "b") -> List[Dict[str, Any]]:
    return [node(f"w{i}", "button", f"{prefix}{i}", ["press"], key=f"{prefix}.{i}") for i in range(n)]


class App:
    """A scripted app: answers each request with the next answer, and keeps what it was sent."""

    def __init__(self, *answers: Any) -> None:
        self.answers = list(answers)
        self.sent: List[Dict[str, Any]] = []

    async def __call__(self, request: Dict[str, Any]) -> Dict[str, Any]:
        self.sent.append(request)
        a = self.answers.pop(0)
        if isinstance(a, BaseException):
            raise a
        return a


# ---------------- JavaScript-exact text ----------------


@pytest.mark.parametrize(
    "value, text",
    [
        (1.0, "1"),
        (312, "312"),
        (-0.0, "0"),
        (0.1, "0.1"),
        (1.5, "1.5"),
        (-2.25, "-2.25"),
        (1e21, "1e+21"),
        (1e20, "100000000000000000000"),
        (123456789012345680000.0, "123456789012345680000"),
        (1e-7, "1e-7"),
        (0.000001, "0.000001"),
        (0.00001, "0.00001"),
        (1.5e300, "1.5e+300"),
        (2.5e-10, "2.5e-10"),
        (1e16, "10000000000000000"),
        (10**22, "1e+22"),
        (float("nan"), "NaN"),
        (float("inf"), "Infinity"),
    ],
)
def test_numbers_print_as_javascript_does(value: float, text: str) -> None:
    assert js_number(value) == text


def test_json_as_javascript_writes_it() -> None:
    assert js_json({"a": 1.0, "b": [True, None, "é—"], "c": {"d": 0.5}}) == '{"a":1,"b":[true,null,"é—"],"c":{"d":0.5}}'
    assert js_json("tab\there \"q\" \\ \x01  ") == '"tab\\there \\"q\\" \\\\ \\u0001  "'
    assert js_json(float("nan")) == "null"
    # (integer-like keys come first, ascending, as a JavaScript object has them)
    assert js_json({"b": 1, "10": 2, "2": 3, "a": 4, "01": 5}) == '{"2":3,"10":2,"b":1,"a":4,"01":5}'
    assert js_json({}) == "{}" and js_json([]) == "[]"


def test_string_and_truthiness_as_javascript() -> None:
    assert js_str(None) == "null" and js_str(True) == "true" and js_str([1, None, "x"]) == "1,,x" and js_str({}) == "[object Object]"
    assert js_truthy({}) and js_truthy([]) and not js_truthy("") and not js_truthy(0) and not js_truthy(float("nan"))
    assert js_trim("﻿  hi 　\n") == "hi"
    assert js_len("😀") == 2 and js_len("é") == 1


def test_iso_dates_with_milliseconds() -> None:
    assert iso_ms(1792711772948) == "2026-10-22T23:29:32.948Z"  # (as remote.json has it)
    assert iso_ms(0) == "1970-01-01T00:00:00.000Z"
    assert iso_ms(-1) == "1969-12-31T23:59:59.999Z"
    assert iso_ms(951782400000) == "2000-02-29T00:00:00.000Z"
    assert iso_ms(1792711772948.9) == "2026-10-22T23:29:32.948Z"


# ---------------- tools and calls ----------------


def test_agent_tools() -> None:
    assert [t["name"] for t in AGENT_TOOLS] == ["ui_look", "ui_act", "ui_tool", "ui_navigate", "ui_peek", "ui_handoff"]
    handoff = AGENT_TOOLS[-1]
    assert handoff["description"].startswith("Only when the user is away (the other ui_ tools answer code away)")
    assert handoff["description"].endswith("At most 20 calls; message at most 500 characters, in the user's language.")
    assert handoff["inputSchema"]["required"] == ["message"]
    assert handoff["inputSchema"]["properties"]["calls"]["items"]["required"] == ["key", "op"]


def test_to_call_each_tool() -> None:
    assert to_call("ui_look", {"picture": True}) is None
    assert to_call("ui_act", {"node": "w4", "op": "press"}) == {"node": "w4", "op": "press", "args": {}}
    assert to_call("ui_act", {"node": "w2", "op": "write", "args": {"text": "hi"}}) == {"node": "w2", "op": "write", "args": {"text": "hi"}}
    assert to_call("ui_tool", {"name": "set_theme", "args": {"theme": "dark"}}) == {"tool": "set_theme", "args": {"theme": "dark"}}
    assert to_call("ui_tool", {}) == {"tool": "", "args": {}}
    assert to_call("ui_navigate", {"route": "back"}) == {"navigate": "back"}
    assert to_call("ui_peek", {"route": "/b/1"}) == {"peek": "/b/1"}


def test_to_call_takes_what_the_model_gives_as_javascript_would() -> None:
    # Missing or null: empty; a number: as JavaScript prints it; args that aren't an object: none (an array stays, as typeof 'object')
    assert to_call("ui_act", {"node": None, "op": 5, "args": "oops"}) == {"node": "", "op": "5", "args": {}}
    assert to_call("ui_act", {"node": 1.0, "op": True, "args": [1]}) == {"node": "1", "op": "true", "args": [1]}
    assert to_call("ui_navigate", {"route": None}) == {"navigate": ""}


def test_to_call_refuses_handoff_and_strangers() -> None:
    with pytest.raises(ValueError, match="ui_handoff is not a call to the app"):
        to_call("ui_handoff", {})
    with pytest.raises(ValueError, match="Not an AffordKit tool: ui_fly"):
        to_call("ui_fly", {})


# ---------------- handoffs ----------------


@pytest.mark.parametrize(
    "given, problem",
    [
        ("hi", "A handoff is an object: { message, route?, calls? }"),
        ([], "A handoff is an object: { message, route?, calls? }"),
        ({"v": 2, "message": "m"}, "Unknown handoff version 2"),
        ({"v": None, "message": "m"}, "Unknown handoff version null"),
        ({"v": True, "message": "m"}, "Unknown handoff version true"),
        ({}, "Say what you did in message: the user reads it"),
        ({"message": " \n\t "}, "Say what you did in message: the user reads it"),
        ({"message": 5}, "Say what you did in message: the user reads it"),
        ({"message": "x" * 501}, "message is too long (501 characters, at most 500)"),
        ({"message": "😀" * 251}, "message is too long (502 characters, at most 500)"),
        ({"message": "m", "route": "back"}, "route is a route of the app (e.g. /drafts), or left out"),
        ({"message": "m", "route": " "}, "route is a route of the app (e.g. /drafts), or left out"),
        ({"message": "m", "route": None}, "route is a route of the app (e.g. /drafts), or left out"),
        ({"message": "m", "expiresAt": "soon"}, "expiresAt is a time in ms"),
        ({"message": "m", "expiresAt": True}, "expiresAt is a time in ms"),
        ({"message": "m", "expiresAt": float("inf")}, "expiresAt is a time in ms"),
        ({"message": "m", "id": 7}, "id is a string"),
        ({"message": "m", "calls": {"key": "a"}}, "calls is a list of { key, op, args? }"),
        ({"message": "m", "calls": [{"key": "a", "op": "press"}] * 21}, "Too many calls (21, at most 20): take the user to the result, no more"),
        ({"message": "m", "calls": ["a"]}, "calls[0] is not { key, op, args? }"),
        ({"message": "m", "calls": [{"key": "a"}]}, "calls[0] is not { key, op, args? }"),
        ({"message": "m", "calls": [{"key": "", "op": "press"}]}, "calls[0] is not { key, op, args? }"),
        ({"message": "m", "calls": [{"key": "a", "op": "press"}, {"key": "w4", "op": "press"}]}, "calls[1]: w4 is an id from a look, gone by the time the user comes back: use the control's key"),
        ({"message": "m", "calls": [{"key": "behind-2", "op": "read"}]}, "calls[0]: behind-2 is an id from a look, gone by the time the user comes back: use the control's key"),
        ({"message": "m", "calls": [{"node": "peek:3", "op": "read"}]}, "calls[0]: peek:3 is an id from a look, gone by the time the user comes back: use the control's key"),
        ({"message": "m", "calls": [{"key": "app", "op": "read"}]}, "calls[0]: app is an id from a look, gone by the time the user comes back: use the control's key"),
        ({"message": "m", "calls": [{"key": "a", "op": "write", "args": [1]}]}, "calls[0].args is an object"),
        ({"message": "m", "calls": [{"key": "a", "op": "write", "args": None}]}, "calls[0].args is an object"),
    ],
)
def test_handoff_problems(given: Any, problem: str) -> None:
    assert handoff_problem(given) == problem
    assert parse_handoff(given) is None


@pytest.mark.parametrize(
    "given",
    [
        {"message": "x" * 500},
        {"message": "😀" * 250},
        {"v": 1, "message": "m", "route": "/a", "calls": None},
        {"message": "m", "calls": [{"key": "w4x", "op": "press"}, {"key": "app.settings", "op": "press"}, {"key": "n12.reply", "op": "press"}]},
        {"message": "m", "calls": [{"key": "a", "op": "write", "args": {}}], "expiresAt": 1e15, "id": "h1"},
        {"message": "m", "calls": [{"key": "w٣", "op": "press"}]},  # (not an ASCII digit: not an id from a look)
    ],
)
def test_handoffs_that_are_fine(given: Dict[str, Any]) -> None:
    assert handoff_problem(given) is None


def test_parse_handoff_gives_the_plain_shape() -> None:
    h = parse_handoff({"message": "  Done.  ", "route": " /drafts ", "calls": [{"node": "drafts.list[7]", "op": "press", "args": {}}, {"key": "x", "op": "read"}], "id": "h1", "extra": 1})
    assert h == {"v": 1, "message": "Done.", "route": "/drafts", "calls": [{"key": "drafts.list[7]", "op": "press", "args": {}}, {"key": "x", "op": "read"}], "id": "h1"}
    assert list(h) == ["v", "message", "route", "calls", "id"]  # type: ignore[arg-type]
    assert parse_handoff({"message": "m", "expiresAt": 100}, now=100) is None
    assert parse_handoff({"message": "m", "expiresAt": 101}, now=100) == {"v": 1, "message": "m", "calls": [], "expiresAt": 101}
    assert parse_handoff({"message": "m", "expiresAt": 1}) is None  # (long gone)
    assert handoff_expired({}) is False and handoff_expired({"expiresAt": 5}, now=5) is True


# ---------------- routes ----------------


def test_match_route() -> None:
    assert match_route("/settings/:tab", "/settings/ai") == {"tab": "ai"}
    assert match_route("/settings/:tab", "/settings/ai?x=1#top") == {"tab": "ai"}
    assert match_route("/settings/:tab", "settings/ai/") == {"tab": "ai"}
    assert match_route("/settings/:tab", "/settings") is None
    assert match_route("/settings/:tab", "/settings/ai/more") is None
    assert match_route("/settings", "/other") is None
    assert match_route("/", "/") == {}
    assert match_route("/mail/:box", "/mail/caf%C3%A9%20au%2Flait") == {"box": "café au/lait"}
    assert match_route("/files/*", "/files/a/b/c") == {}
    assert match_route("/files/*", "/files") == {}
    assert match_route("/files/:id/*", "/files") is None
    assert match_route("/files/:id/*", "/files/7/x") == {"id": "7"}
    # (a malformed escape: not this route)
    assert match_route("/mail/:box", "/mail/%zz") is None
    assert match_route("/mail/:box", "/mail/%C3") is None


def test_find_route_takes_the_most_specific() -> None:
    routes = [{"path": "/mail/:box", "description": "A box"}, {"path": "/mail/inbox", "description": "The inbox"}, {"path": "/b/:id", "description": "B"}]
    best = find_route(routes, "/mail/inbox")
    assert best is not None and best["spec"]["path"] == "/mail/inbox" and best["params"] == {}
    best = find_route(routes, "/mail/archive")
    assert best is not None and best["spec"]["path"] == "/mail/:box" and best["params"] == {"box": "archive"}
    assert find_route(routes, "/nowhere") is None
    assert find_route([], "/a") is None


def test_find_route_ranks_catch_all_last_then_params_then_fixed_segments() -> None:
    routes = [
        {"path": "/*", "description": "anything"},
        {"path": "/mail/:box", "description": "a mailbox"},
        {"path": "/:section/:page", "description": "a page"},
        {"path": "/mail/inbox", "description": "the inbox"},
        {"path": "/mail/*", "description": "under mail"},
    ]
    assert (find_route(routes, "/mail/inbox") or {})["spec"]["path"] == "/mail/inbox"
    best = find_route(routes, "/mail/archive")
    assert best is not None and best["spec"]["path"] == "/mail/:box" and best["params"] == {"box": "archive"}
    assert (find_route(routes, "/settings/ai") or {})["spec"]["path"] == "/:section/:page"
    assert (find_route(routes, "/mail/a/b") or {})["spec"]["path"] == "/mail/*"
    assert (find_route(routes, "/x") or {})["spec"]["path"] == "/*"
    assert find_route(routes[1:3], "/mail/%zz") is None


# ---------------- describing ----------------


def test_describe_change_whole_screen_threshold_on_a_small_screen() -> None:
    # 10 buttons + the app: 11 nodes after. Up to max(4, 11 * 0.5 = 5.5) nodes come and go: what changed; more: the whole screen
    before = ctx(buttons(10))
    five = ctx(buttons(5) + buttons(5, "c"))  # 5 went, 5 came: 10 > 5.5
    assert describe_change(before, five).startswith("The screen now:\nRoute: /a")
    three = ctx(buttons(7) + buttons(3, "c")[:2] + [buttons(10)[9]])  # 2 went (b.7, b.8), 2 came: 4, not over max(4, 5.5)
    text = describe_change(before, three)
    assert text.startswith("The screen changed:\n")
    assert '+ [w0 key=c.0] button "c0" — press' in text and '- [b.7] button "b7"' in text
    four_of_four = ctx(buttons(2))  # 8 went: over
    assert describe_change(before, four_of_four).startswith("The screen now:")


def test_describe_change_threshold_is_at_least_four() -> None:
    before = ctx([])
    assert describe_change(before, ctx(buttons(3))).startswith("The screen changed:")  # 3 came, 4 nodes: 3 > max(4, 2) no
    assert describe_change(before, ctx(buttons(4))).startswith("The screen changed:")  # 4 > 4 no
    assert describe_change(before, ctx(buttons(5))).startswith("The screen now:")  # 5 > max(4, 3) yes
    # wholeOver changes the share
    assert describe_change(before, ctx(buttons(5)), whole_over=1.0).startswith("The screen changed:")


def test_describe_change_route_and_no_change() -> None:
    a = ctx(buttons(3))
    assert describe_change(a, a) == "The screen did not change."
    b = ctx(buttons(3), route="/b/1")
    b["route"]["canGoBack"] = True
    assert describe_change(a, b) == "Now at /b/1 (was /a) — can go back.\nThe screen did not change."
    c = ctx(buttons(3))
    c["root"]["children"][1]["state"] = {"disabled": True, "count": 2.0}
    assert describe_change(a, c) == 'The screen changed:\n~ [w1 key=b.1] button "b1" (disabled, count: 2) — press'


def test_describe_values_states_and_containers() -> None:
    c = ctx(
        [
            node("w1", "text", "Total", ["read"], value=12.0, state={"on": False, "n": 1.5}),
            node("w2", "container", "Rows", ["items"], key="rows", state={"count": 1, "first": 0, "last": 0, "x": True}, preview=[{"id": "1", "name": 'He said "hi"\n'}]),
            node("w3", "heading", "Same", [], value="Same"),
            node("w4", "button", "", ["press"], description="Unnamed"),
        ]
    )
    assert describe(c) == "\n".join(
        [
            "Route: /a",
            "Routes:",
            "  /a — A",
            "  /b/:id — B",
            "[app] app \"App\" — read",
            '  [w1] text "Total" = 12 (on: false, n: 1.5) — read',
            '  [w2 key=rows] container "Rows" 1 entry, showing 0–0 (entry keys: rows[<id>]) (x) — items',
            '    · [1] "He said \\"hi\\"\\n"',
            "    · … op item fetches an entry's controls, items pages through them",
            '  [w3] heading "Same"',
            "  [w4] button — Unnamed — press",
        ]
    )
    assert describe(c, max_nodes=2).endswith('[w1] text "Total" = 12 (on: false, n: 1.5) — read\n… 3 more nodes')


def test_describe_results() -> None:
    call = {"node": "w1", "op": "read", "args": {}}
    assert describe_result({"call": call, "ok": True}) == "Done."
    assert describe_result({"call": call, "ok": True, "value": None}) == "null"
    assert describe_result({"call": call, "ok": True, "value": {}}) == "{}"
    assert describe_result({"call": call, "ok": True, "value": []}) == "[]"
    assert describe_result({"call": call, "ok": True, "value": False}) == "false"
    assert describe_result({"call": call, "ok": True, "value": 3.0}) == "3"
    assert describe_result({"call": call, "ok": True, "value": "plain"}) == "plain"
    assert describe_result({"call": call, "ok": False, "error": "No"}) == "Failed: No"
    assert describe_result({"call": call, "ok": False, "code": "denied", "error": "No"}) == "Failed (denied): No"
    assert describe_result({"call": call, "ok": False, "needsConfirm": True, "error": "Ask"}) == "Waiting: Ask"
    assert describe_result({"call": {"navigate": "back"}, "ok": True}) == "Now at back."
    assert describe_result({"call": {"navigate": "/a"}, "ok": True, "value": "/a"}) == "Now at /a."


def test_describe_items_item_image_page() -> None:
    assert describe_items({"offset": 0, "items": []}) == "No items."
    assert describe_items({"offset": 5, "count": 3, "items": []}) == "No items from 5 (3 in all)."
    assert describe_items({"offset": 2, "items": [{"id": "a", "name": "A", "index": 2}]}) == 'Items 2–2:\n  [a] #2 "A"'
    assert describe_item({"id": "9", "source": "preview", "root": node("p9", "listitem", "Old", ["press"])}) == (
        'Entry 9 — built off screen: its ids cannot be acted on, act by key (that brings it in):\n[p9] listitem "Old" — press'
    )
    assert describe_image({"mime": "image/png", "data": "x", "width": 2, "height": 1}) == "(A picture, 2×1 image/png: attached.)"
    assert describe_image({"mime": "image/png"}) == "(A picture at an unknown place: it could not be read here.)"
    assert describe_image({"mime": "image/png", "url": "u", "width": 3, "height": 4}) == "(A picture at u, 3×4: it could not be read here.)"
    assert describe_page({"route": "/x", "source": "declared"}) == "Page /x — never seen: only what the route says"
    assert describe_page({"route": "/x", "source": "seen", "seenAt": 0, "root": node("a", "button", "OK")}) == (
        "Page /x — as it was when it last showed\n(Peek ids cannot be acted on: navigate there, then act by key, or look again for live ids.)\n[a] button \"OK\""
    )


def test_describe_user_actions() -> None:
    assert describe_user_actions(None) == "" and describe_user_actions([]) == ""
    text = describe_user_actions([{"at": 1, "op": "zoom", "value": "2"}, {"at": 2, "op": "navigate"}])
    assert text.splitlines()[1:3] == ['- zoom  "2"', "- went to another page"]


# ---------------- the remote ----------------


async def test_a_timeout() -> None:
    async def never(_r: Dict[str, Any]) -> Dict[str, Any]:
        await asyncio.Event().wait()
        return {}

    ui = AffordRemote(never, timeout=0.05)
    started = time.monotonic()
    a = await ui.handle("ui_look")
    assert time.monotonic() - started < 2
    assert (a.is_error, a.code) == (True, "timeout")
    assert a.text == "Failed (timeout): The app did not answer in time (it may be in the background): look again later, or do it another way"
    assert ui.screen is None


async def test_transport_failures_and_odd_answers() -> None:
    def sync_send(_r: Dict[str, Any]) -> Dict[str, Any]:
        return {"context": ctx(buttons(1))}

    a = await AffordRemote(sync_send).handle("ui_look")  # (a plain function works too)
    assert not a.is_error and a.text.endswith('[w0 key=b.0] button "b0" — press')
    app = App(AffordError("unreachable", "Covered"), RuntimeError("boom"), "nonsense", {"nothing": 1}, {"error": "x", "code": None})
    ui = AffordRemote(app)
    assert (await ui.handle("ui_look")).to_dict() == {"text": "Failed (unreachable): Covered", "isError": True, "code": "unreachable"}
    assert (await ui.handle("ui_look")).text == "Failed (unavailable): boom"
    assert (await ui.handle("ui_look")).text == "Failed (unavailable): The app gave no screen"
    assert (await ui.handle("ui_look")).text == "Failed (unavailable): The app gave no screen"
    assert (await ui.handle("ui_look")).code == "unavailable"


async def test_look_and_act_requests() -> None:
    app = App({"context": ctx(buttons(2))}, {"context": ctx(buttons(2)), "results": [{"call": {}, "ok": True}]})
    ui = AffordRemote(app)
    await ui.handle("ui_look", None)
    a = await ui.handle("ui_act", {"node": "b.0", "op": "press"})
    assert app.sent == [{"look": True}, {"calls": [{"node": "b.0", "op": "press", "args": {}}]}]
    assert a == ToolAnswer(text="Done.\n\nThe screen did not change.", is_error=False, context=ctx(buttons(2)))


async def test_away_and_tools_offered() -> None:
    ui = AffordRemote(App(), present=lambda: False)
    a = await ui.handle("ui_look")
    assert a.code == "away" and a.text.endswith("Use your other tools.")
    assert (await ui.handle("ui_fly")).code == "bad_args"  # (not one of the screen tools: not away)
    with_host = AffordRemote(App(), present=lambda: False, on_handoff=lambda h: None)
    assert (await with_host.handle("ui_tool", {"name": "x"})).text.endswith("Use your other tools, and leave a handoff (ui_handoff) for when they come back.")
    ui = AffordRemote(App())
    assert [t["name"] for t in ui.tools()] == ["ui_look", "ui_act", "ui_tool", "ui_navigate", "ui_peek"]
    ui.seen(ctx([]))
    assert not ui.has("ui_tool") and not ui.has("ui_handoff")
    ui.seen(ctx([], tools=[{"name": "t", "description": "T", "policy": "allow"}]))
    assert ui.has("ui_tool")
    assert [t["name"] for t in AffordRemote(App(), tools=["ui_look", "ui_handoff"]).tools()] == ["ui_look"]
    assert [t["name"] for t in AffordRemote(App(), tools=["ui_look", "ui_handoff"], on_handoff=print).tools()] == ["ui_look", "ui_handoff"]


async def test_handoff_host_async_and_ttl() -> None:
    given: List[Dict[str, Any]] = []

    async def host(h: Dict[str, Any]) -> str:
        given.append(h)
        return "sent"

    ui = AffordRemote(App(), on_handoff=host, handoff_ttl=60)
    ui.seen(ctx([]))
    before = int(time.time() * 1000)
    a = await ui.handle("ui_handoff", {"message": "Hi", "route": "/b/7", "id": "mine"})
    assert a == ToolAnswer(text="Handoff left: sent", is_error=False)
    assert given[0]["route"] == "/b/7" and "id" not in given[0]
    assert before + 60_000 <= given[0]["expiresAt"] <= int(time.time() * 1000) + 60_000
    bad = await ui.handle("ui_handoff", {"message": "Hi", "route": "/b/%zz"})
    assert bad.text == "Failed (bad_args): No route /b/%zz (the routes: /a, /b/:id)"
    assert (await AffordRemote(App()).handle("ui_handoff", {"message": "Hi"})).text == "Failed (not_found): This app takes no handoffs"


# ---------------- adapters ----------------


def picture_app() -> AffordRemote:
    async def send(_r: Dict[str, Any]) -> Dict[str, Any]:
        return {"context": ctx(buttons(1)), "picture": {"type": "image", "mime": "image/png", "data": "AAAA"}}

    return AffordRemote(send)


async def test_anthropic_adapter_with_sdk_objects() -> None:
    ui = picture_app()
    tools = anthropic_tools(ui.tools())
    assert tools[0] == {"name": "ui_look", "description": AGENT_TOOLS[0]["description"], "input_schema": AGENT_TOOLS[0]["inputSchema"]}
    block = SimpleNamespace(type="tool_use", id="toolu_9", name="ui_look", input={"picture": True})
    r = await anthropic_result(ui, block)
    assert r["tool_use_id"] == "toolu_9" and "is_error" not in r
    assert r["content"][1] == {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}}
    assert r["content"][0]["text"].endswith("(A picture of the screen is attached.)")
    plain = await anthropic_result(ui, {"id": "t", "name": "ui_look", "input": None})
    assert plain["content"][0]["type"] == "text"  # (the look's picture comes when the app sends it)


async def test_openai_adapters() -> None:
    ui = picture_app()
    assert openai_tools(ui.tools())[1]["function"]["name"] == "ui_act"
    assert openai_tools(ui.tools())[1]["type"] == "function"
    call = SimpleNamespace(id="call_7", type="function", function=SimpleNamespace(name="ui_look", arguments='{"picture": true}'))
    r = await openai_result(ui, call)
    assert r["role"] == "tool" and r["tool_call_id"] == "call_7" and r["content"].endswith("(A picture of the screen is attached.)")
    nan = await openai_result(ui, {"id": "c", "function": {"name": "ui_look", "arguments": '{"picture": NaN}'}})
    assert not nan["content"].endswith("attached.)")  # (not JSON as JavaScript reads it: no arguments)
    assert openai_responses_tools(ui.tools())[0] == {"type": "function", "name": "ui_look", "description": AGENT_TOOLS[0]["description"], "parameters": AGENT_TOOLS[0]["inputSchema"]}
    out = await openai_responses_result(ui, SimpleNamespace(type="function_call", call_id="fc_9", name="ui_look", arguments="[1]"))
    assert out["type"] == "function_call_output" and out["call_id"] == "fc_9" and out["output"].startswith("Route: /a")


async def test_mcp_and_runners() -> None:
    ui = picture_app()
    h = mcp_handlers(ui)
    listed = await h.list()
    assert [t["name"] for t in listed["tools"]] == [t["name"] for t in ui.tools()]
    assert set(listed["tools"][0]) == {"name", "description", "inputSchema"}
    r = await h.call_tool("ui_look", {"picture": True})
    assert r["content"][1] == {"type": "image", "data": "AAAA", "mimeType": "image/png"} and "isError" not in r
    err = await h.call_tool("ui_nope")
    assert err == {"content": [{"type": "text", "text": "Failed (bad_args): Not an AffordKit tool: ui_nope"}], "isError": True}
    run = runners(ui)
    assert [t["name"] for t in run] == [t["name"] for t in ui.tools()] and "inputSchema" in run[0]
    a = await run[0]["run"]({"picture": True})
    assert isinstance(a, ToolAnswer) and a.images == [{"mime": "image/png", "data": "AAAA"}]
    assert json.loads(json.dumps(a.to_dict()))["isError"] is False
    assert HANDOFF_MAX_CALLS == 20
