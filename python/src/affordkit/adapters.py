"""
The agent's tools in the shapes the common agent stacks take — the Anthropic and OpenAI APIs, an MCP server, and plain runners for
anything else (LangChain, a loop of your own) — and their answers back in the shape each expects. No SDK is imported: these are the
plain dicts those SDKs take. A tool call can be given as the SDK's object (``block.id``, ``call.function.name``) or as a dict::

    # Anthropic Messages API
    res = await client.messages.create(..., tools=anthropic_tools(ui.tools()))
    results = [await anthropic_result(ui, b) for b in res.content if b.type == "tool_use" and ui.has(b.name)]

    # OpenAI Chat Completions
    res = await client.chat.completions.create(..., tools=openai_tools(ui.tools()))
    messages += [await openai_result(ui, c) for c in res.choices[0].message.tool_calls or []]
"""

from __future__ import annotations

import json
from typing import Any, Awaitable, Callable, Dict, List, Optional

from .agent import AgentTool
from .remote import AffordRemote, ToolAnswer


def _field(obj: Any, name: str, default: Any = None) -> Any:
    """``obj.name`` of an SDK object, or ``obj[name]`` of a dict."""
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _as_args(value: Any) -> Dict[str, Any]:
    # (an object, as JavaScript's typeof 'object' takes it; anything else: no arguments)
    if isinstance(value, dict):
        return value
    if hasattr(value, "model_dump"):  # (a pydantic model, as SDKs give)
        dumped = value.model_dump()
        return dumped if isinstance(dumped, dict) else {}
    return value if isinstance(value, list) else {}  # type: ignore[return-value]


def _reject_constant(name: str) -> Any:
    raise ValueError(f"Not JSON: {name}")


def _parse_args(text: Any) -> Dict[str, Any]:
    """A tool call's arguments as JSON text (empty: none); not JSON: none."""
    try:
        return _as_args(json.loads(text or "{}", parse_constant=_reject_constant))
    except (ValueError, TypeError):
        return {}


def anthropic_tools(tools: List[AgentTool]) -> List[Dict[str, Any]]:
    """Anthropic Messages API tools: ``{"name", "description", "input_schema"}``."""
    return [{"name": t["name"], "description": t["description"], "input_schema": t["inputSchema"]} for t in tools]


async def anthropic_result(remote: AffordRemote, block: Any) -> Dict[str, Any]:
    """A tool_use block run: its tool_result block (a picture goes in it beside the text)."""
    a = await remote.handle(_field(block, "name"), _as_args(_field(block, "input")))
    content: Any = a.text
    if a.images:
        content = [{"type": "text", "text": a.text}] + [{"type": "image", "source": {"type": "base64", "media_type": i["mime"], "data": i["data"]}} for i in a.images]
    out: Dict[str, Any] = {"type": "tool_result", "tool_use_id": _field(block, "id"), "content": content}
    if a.is_error:
        out["is_error"] = True
    return out


def openai_tools(tools: List[AgentTool]) -> List[Dict[str, Any]]:
    """OpenAI Chat Completions tools: ``{"type": "function", "function": {"name", "description", "parameters"}}``."""
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["inputSchema"]}} for t in tools]


async def openai_result(remote: AffordRemote, call: Any) -> Dict[str, Any]:
    """A Chat Completions tool call run: its tool message (text only there: a picture is left out, and the text says it is)."""
    fn = _field(call, "function")
    a = await remote.handle(_field(fn, "name"), _parse_args(_field(fn, "arguments")))
    return {"role": "tool", "tool_call_id": _field(call, "id"), "content": a.text}


def openai_responses_tools(tools: List[AgentTool]) -> List[Dict[str, Any]]:
    """OpenAI Responses API tools: ``{"type": "function", "name", "description", "parameters"}``."""
    return [{"type": "function", "name": t["name"], "description": t["description"], "parameters": t["inputSchema"]} for t in tools]


async def openai_responses_result(remote: AffordRemote, call: Any) -> Dict[str, Any]:
    """A Responses API function_call run: its function_call_output item."""
    a = await remote.handle(_field(call, "name"), _parse_args(_field(call, "arguments")))
    return {"type": "function_call_output", "call_id": _field(call, "call_id"), "output": a.text}


class McpHandlers:
    """
    MCP server handlers for tools/list and tools/call, as plain dicts in MCP's JSON shape. With the ``mcp`` SDK's low-level server::

        h = mcp_handlers(ui)

        @server.list_tools()
        async def list_tools():
            return [types.Tool(**t) for t in (await h.list())["tools"]]

        @server.call_tool()
        async def call_tool(name, arguments):
            return types.CallToolResult.model_validate(await h.call_tool(name, arguments))
    """

    def __init__(self, remote: AffordRemote) -> None:
        self._remote = remote

    async def list(self) -> Dict[str, Any]:
        """tools/list: ``{"tools": [{"name", "description", "inputSchema"}]}``."""
        return {"tools": [{"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]} for t in self._remote.tools()]}

    async def call(self, request: Any) -> Dict[str, Any]:
        """tools/call, given the request (``{"params": {"name", "arguments"?}}``): ``{"content": [...], "isError"?: true}``."""
        params = _field(request, "params")
        return await self.call_tool(_field(params, "name"), _field(params, "arguments"))

    async def call_tool(self, name: str, arguments: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """tools/call, given the tool's name and arguments."""
        a = await self._remote.handle(name, arguments if arguments is not None else {})
        content: List[Dict[str, Any]] = [{"type": "text", "text": a.text}] + [{"type": "image", "data": i["data"], "mimeType": i["mime"]} for i in a.images or []]
        out: Dict[str, Any] = {"content": content}
        if a.is_error:
            out["isError"] = True
        return out


def mcp_handlers(remote: AffordRemote) -> McpHandlers:
    """MCP server handlers for tools/list (``list``) and tools/call (``call``, or ``call_tool(name, arguments)``)."""
    return McpHandlers(remote)


def runners(remote: AffordRemote) -> List[Dict[str, Any]]:
    """Each tool with a ``run`` coroutine function (for LangChain, or a loop of your own): ``await tool["run"](input)`` → its ToolAnswer."""

    def runner(name: str) -> Callable[[Optional[Dict[str, Any]]], Awaitable[ToolAnswer]]:
        async def run(input: Optional[Dict[str, Any]] = None) -> ToolAnswer:
            return await remote.handle(name, input)

        return run

    return [{**t, "run": runner(t["name"])} for t in remote.tools()]
