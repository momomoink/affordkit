"""
The agent side's conformance cases (conformance/remote.json, at the repository root), shared by every port: each case runs
AffordRemote against an app that answers as scripted, and what it sent the app and what the agent got back must be exactly what the
file recorded from the TypeScript reference.
"""

from __future__ import annotations

import asyncio
import copy
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

from affordkit import (
    AffordError,
    AffordRemote,
    anthropic_result,
    anthropic_tools,
    mcp_handlers,
    openai_responses_result,
    openai_responses_tools,
    openai_result,
    openai_tools,
)

FILE = Path(__file__).resolve().parents[2] / "conformance" / "remote.json"
SPEC: Dict[str, Any] = json.loads(FILE.read_text(encoding="utf-8"))
CASES: List[Dict[str, Any]] = SPEC["cases"]


def _raise(says: Dict[str, Any]) -> None:
    if says.get("code"):
        raise AffordError(says["code"], says["throws"])
    raise RuntimeError(says["throws"])


async def run(case: Dict[str, Any]) -> Dict[str, Any]:
    options = case.get("options") or {}
    state: Dict[str, Any] = {"step": None, "rec": {}}

    async def send(request: Dict[str, Any]) -> Dict[str, Any]:
        state["rec"]["request"] = json.loads(json.dumps(request))
        reply = (state["step"] or {}).get("reply")
        if reply is None:
            raise AssertionError(f"step sent a request it has no reply for: {request}")
        if "never" in reply:
            await asyncio.Future()  # (never answers)
        if "throws" in reply:
            _raise(reply)
        return copy.deepcopy(reply)

    def on_handoff(h: Dict[str, Any]) -> Optional[str]:
        rest = dict(h)
        expires = rest.pop("expiresAt", None)
        assert isinstance(expires, int) and not isinstance(expires, bool)
        state["rec"]["handoff"] = rest
        says = (state["step"] or {}).get("handoffSays")
        if isinstance(says, dict):
            _raise(says)
        return says

    kwargs: Dict[str, Any] = {}
    if options.get("timeoutMs"):
        kwargs["timeout"] = options["timeoutMs"] / 1000
    if options.get("screen"):
        kwargs["screen"] = options["screen"]
    if options.get("tools"):
        kwargs["tools"] = options["tools"]
    if options.get("maxNodes"):
        kwargs["max_nodes"] = options["maxNodes"]
    if options.get("present") is False:
        kwargs["present"] = lambda: False
    if options.get("handoff"):
        kwargs["on_handoff"] = on_handoff
    ui = AffordRemote(send, **kwargs)
    ui.seen(copy.deepcopy(case.get("seen")))
    tools_before = [t["name"] for t in ui.tools()]
    steps = []
    for step in case["steps"]:
        state["step"] = step
        rec: Dict[str, Any] = {}
        state["rec"] = rec
        a = await ui.handle(step["tool"], copy.deepcopy(step.get("input", {})))
        rec["text"] = a.text
        rec["isError"] = a.is_error
        if a.code:
            rec["code"] = a.code
        if a.images:
            rec["images"] = a.images
        steps.append(rec)
    return {"toolsBefore": tools_before, "toolsAfter": [t["name"] for t in ui.tools()], "steps": steps}


def test_the_file_has_cases() -> None:
    assert SPEC["version"] == 1
    assert len(CASES) >= 20


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
async def test_case(case: Dict[str, Any]) -> None:
    got = await run(case)
    want = case["expect"]
    assert got["toolsBefore"] == want["toolsBefore"]
    assert got["toolsAfter"] == want["toolsAfter"]
    assert len(got["steps"]) == len(want["steps"])
    for i, (g, w) in enumerate(zip(got["steps"], want["steps"])):
        # (text first, for a readable diff when it differs)
        assert g["text"] == w["text"], f"step {i}"
        assert g == w, f"step {i}"


def _inbox() -> Dict[str, Any]:
    return copy.deepcopy(CASES[0]["steps"][0]["reply"]["context"])


async def shapes() -> Dict[str, Any]:
    inbox = _inbox()

    async def answer(_request: Dict[str, Any]) -> Dict[str, Any]:
        return {"context": copy.deepcopy(inbox), "picture": {"type": "image", "mime": "image/png", "data": "AAAA"}}

    async def fail(_request: Dict[str, Any]) -> Dict[str, Any]:
        return {"error": "gone", "code": "unavailable"}

    answering = AffordRemote(answer)
    failing = AffordRemote(fail)
    tools = answering.tools()
    mcp = mcp_handlers(answering)
    return {
        "anthropicTools": anthropic_tools(tools),
        "openaiTools": openai_tools(tools),
        "openaiResponsesTools": openai_responses_tools(tools),
        "mcpList": await mcp.list(),
        "anthropicResult": await anthropic_result(answering, {"id": "toolu_1", "name": "ui_look", "input": {"picture": True}}),
        "anthropicResultError": await anthropic_result(failing, {"id": "toolu_2", "name": "ui_look", "input": {}}),
        "openaiResult": await openai_result(answering, {"id": "call_1", "function": {"name": "ui_look", "arguments": '{"picture":true}'}}),
        "openaiResultBadJson": await openai_result(failing, {"id": "call_2", "function": {"name": "ui_look", "arguments": "{oops"}}),
        "openaiResponsesResult": await openai_responses_result(answering, {"call_id": "fc_1", "name": "ui_look", "arguments": ""}),
        "mcpCall": await mcp.call({"params": {"name": "ui_look", "arguments": {"picture": True}}}),
        "mcpCallError": await mcp_handlers(failing).call({"params": {"name": "ui_look"}}),
    }


@pytest.mark.parametrize("name", list(SPEC["shapes"].keys()))
async def test_shape(name: str) -> None:
    got = await shapes()
    assert set(got) == set(SPEC["shapes"])
    assert got[name] == SPEC["shapes"][name]
