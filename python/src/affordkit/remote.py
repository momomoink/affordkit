"""
The agent's side of AffordKit over any transport. Give it a way to send a request to the app (which answers with its kit's
``answer()``), and it gives the agent its tools and runs them: each answer as text for the model — after an act, what it did to the
screen rather than the whole tree again — with a code when it failed::

    ui = AffordRemote(send=lambda request: socket.ask(request))   # the app: socket.on_ask(lambda r: kit.answer(r))
    tools = anthropic_tools(ui.tools())
    answer = await ui.handle(tool_use.name, tool_use.input)        # → the tool_result: answer.text, answer.is_error

When the user has left the app (``present`` says so), the screen tools answer code away at once; with ``on_handoff`` the agent also
gets ui_handoff, to leave the user a message and the calls that take them to what it did (see Handoff).

Times are in seconds, as is usual in Python (``timeout``, ``handoff_ttl``); a handoff's ``expiresAt`` is in ms since the epoch, as
the protocol says. Requests, answers, contexts and handoffs are plain dicts with the protocol's camelCase keys, exactly as on the wire.
"""

from __future__ import annotations

import asyncio
import inspect
import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, List, Literal, Optional, Union, cast

from ._js import get, js_str, js_truthy
from .agent import AGENT_TOOLS, AgentTool, describe, describe_change, describe_result, describe_user_actions, to_call
from .protocol import AffordContext, AffordError, Call, ErrorCode, Handoff, UiAnswer, UiRequest, find_route, handoff_problem, is_image, parse_handoff

#: Sends a request to the app and returns its answer (kit.answer on the app's side): an async function, or a plain one.
Send = Callable[[UiRequest], Union[Awaitable[UiAnswer], UiAnswer]]

#: Where a handoff goes: returns (or resolves with) what to tell the agent, e.g. "notification sent", or None.
OnHandoff = Callable[[Handoff], Union[Awaitable[Optional[str]], Optional[str]]]


@dataclass
class ToolAnswer:
    """
    A tool's answer: the text for the agent (its tool result), whether it failed and why (code), and the screen it left (context).
    images: pictures that go with the text (a look with picture, an op view), ``{"mime", "data"}`` with data in base64: to pass to
    the model where its stack takes images.
    """

    text: str
    is_error: bool
    code: Optional[ErrorCode] = None
    context: Optional[AffordContext] = None
    images: Optional[List[Dict[str, str]]] = field(default=None)

    def to_dict(self) -> Dict[str, Any]:
        """As JSON in the protocol's spelling: ``{"text", "isError", "code"?, "context"?, "images"?}``."""
        out: Dict[str, Any] = {"text": self.text, "isError": self.is_error}
        if self.code is not None:
            out["code"] = self.code
        if self.context is not None:
            out["context"] = self.context
        if self.images:
            out["images"] = self.images
        return out


class AffordRemote:
    """
    The agent's side of an app's screen: its tools, and running them against the app over ``send``.

    - ``send``: send a request to the app and return its answer (async, or not).
    - ``timeout``: how long to wait for the app's answer, in seconds (default 45): then the tool fails with code timeout.
    - ``screen``: the screen after an act: what changed (``"changes"``, default: fewer tokens), or the whole tree each time (``"whole"``).
    - ``tools``: which of AGENT_TOOLS to offer, by name (default: all — ui_tool once the app is seen to have tools of its own,
      ui_handoff with on_handoff).
    - ``max_nodes``: most nodes in a tree as text (default 400).
    - ``present``: whether the user is in the app now (e.g. the app's lifecycle as its channel last reported it). While it returns
      False, every tool but ui_handoff answers code away at once, without asking the app. Default: always.
    - ``on_handoff``: where a handoff the agent leaves goes (ui_handoff, checked first): keep it and tell the user — a notification
      with its id, usually. What it returns ("notification sent") is told the agent. Without it, ui_handoff isn't offered.
    - ``handoff_ttl``: how long a handoff stays good, in seconds (default 24 h): its expiresAt.
    """

    def __init__(
        self,
        send: Send,
        *,
        timeout: float = 45.0,
        screen: Literal["changes", "whole"] = "changes",
        tools: Optional[List[str]] = None,
        max_nodes: Optional[int] = None,
        present: Optional[Callable[[], bool]] = None,
        on_handoff: Optional[OnHandoff] = None,
        handoff_ttl: float = 24 * 3600.0,
    ) -> None:
        self._send = send
        self._timeout = timeout
        self._screen = screen
        self._tools = tools
        self._max_nodes = max_nodes
        self._present = present
        self._on_handoff = on_handoff
        self._handoff_ttl = handoff_ttl
        self._last: Optional[AffordContext] = None

    def seen(self, context: Optional[AffordContext]) -> None:
        """The screen as the agent was last shown it (e.g. sent along with the user's message): the next act answers with what changed since."""
        self._last = context

    @property
    def screen(self) -> Optional[AffordContext]:
        """The screen as the agent last saw it."""
        return self._last

    def tools(self) -> List[AgentTool]:
        """The tools to give the agent."""
        names = self._tools
        last = self._last

        def offered(t: AgentTool) -> bool:
            if t["name"] == "ui_handoff" and self._on_handoff is None:
                return False
            if names is not None:
                return t["name"] in names
            return t["name"] != "ui_tool" or not last or len(last.get("tools") or []) > 0

        return [t for t in AGENT_TOOLS if offered(t)]

    def has(self, name: str) -> bool:
        """Whether a tool the agent called is one of these."""
        return any(t["name"] == name for t in self.tools())

    async def handle(self, name: str, input: Optional[Dict[str, Any]] = None) -> ToolAnswer:
        """Run a tool the agent called: its answer as text. Never raises: a failure is an answer with is_error and a code."""
        args: Dict[str, Any] = input if isinstance(input, dict) else {}
        if name == "ui_handoff":
            return await self._handoff(args)
        # The user has left: nothing on the screen can be done now (and the app may not even answer)
        if self._away() and any(t["name"] == name for t in AGENT_TOOLS):
            more = ", and leave a handoff (ui_handoff) for when they come back" if self._on_handoff is not None else ""
            return _failed("away", f"The user is not in the app right now (it is in the background): the screen can't be looked at or worked. Use your other tools{more}.")
        try:
            call = to_call(name, args)
        except ValueError as error:
            return _failed("bad_args", str(error))
        request: UiRequest = {"calls": [call]} if call is not None else {"look": True, **({"picture": True} if args.get("picture") is True else {})}
        answer = await self._ask(request)
        if "error" in answer:
            code = answer.get("code")
            return _failed(code if code is not None else "unavailable", answer["error"])
        if not isinstance(answer.get("context"), dict):
            return _failed("unavailable", "The app gave no screen")
        context = cast(AffordContext, answer["context"])
        before = self._last
        self._last = context
        max_nodes = 400 if self._max_nodes is None else self._max_nodes
        if call is None:
            pic = get(answer, "picture")
            picture = [{"mime": pic.get("mime"), "data": pic["data"]}] if js_truthy(get(pic, "data")) else []
            note = ""
            if args.get("picture") is True:
                note = "\n\n(A picture of the screen is attached.)" if picture else "\n\n(No picture: this app can't take one.)"
            meanwhile = describe_user_actions(answer.get("userActions"))
            text = (f"{meanwhile}\n\n" if meanwhile else "") + describe(context, max_nodes=max_nodes) + note
            return ToolAnswer(text=text, is_error=False, context=context, images=picture or None)
        results = answer.get("results")
        r = results[0] if isinstance(results, list) and results else None
        if not js_truthy(r):
            return _failed("unavailable", "The app gave no result")
        if not isinstance(r, dict):
            r = {}
        # A peek leaves the screen as it was; anything else: what it did to it (going to a page says where it is now itself)
        said = "" if js_truthy(r.get("ok")) and "navigate" in call and before and self._screen != "whole" else describe_result(r)  # type: ignore[arg-type]
        if "peek" in call:
            screen = ""
        elif self._screen == "whole" or not before:
            screen = f"The screen now:\n{describe(context, max_nodes=max_nodes)}"
        else:
            screen = describe_change(before, context, max_nodes=max_nodes)
        value = r.get("value")
        image = [{"mime": value["mime"], "data": value.get("data", "")}] if is_image(value) and js_truthy(value.get("data")) else []
        # (what the user did themselves first: the screen it left is part of what the change below shows)
        text = "\n\n".join(s for s in [describe_user_actions(answer.get("userActions")), said, screen] if s)
        code = r.get("code")
        return ToolAnswer(text=text, is_error=not js_truthy(r.get("ok")), code=code if js_truthy(code) else None, context=context, images=image or None)

    def _away(self) -> bool:
        if self._present is None:
            return False
        try:
            return self._present() is False
        except Exception:
            return False

    async def _handoff(self, input: Dict[str, Any]) -> ToolAnswer:
        """ui_handoff: the agent's handoff checked (its route against the routes seen), with its expiry, and given to the host."""
        give = self._on_handoff
        if give is None:
            return _failed("not_found", "This app takes no handoffs")
        # (its id and expiry are the host's to say, not the agent's)
        draft: Dict[str, Any] = {**input, "v": 1, "expiresAt": int(time.time() * 1000) + round(self._handoff_ttl * 1000)}
        draft.pop("id", None)
        problem = handoff_problem(draft)
        handoff = None if problem else parse_handoff(draft)
        if handoff is None:
            return _failed("bad_args", problem or "Not a handoff")
        routes = get(get(self._last, "route"), "routes")
        route = handoff.get("route")
        if route and isinstance(routes, list) and routes:
            if find_route(routes, route) is None:
                return _failed("bad_args", f"No route {route} (the routes: {', '.join(js_str(get(r, 'path')) for r in routes)})")
        try:
            said = give(handoff)
            if inspect.isawaitable(said):
                said = await said
            return ToolAnswer(text=f"Handoff left: {js_str(said) if js_truthy(said) else 'the user gets it when they come back.'}", is_error=False)
        except AffordError as error:
            return _failed(error.code, error.message)
        except Exception as error:
            return _failed("failed", str(error))

    async def _ask(self, request: UiRequest) -> UiAnswer:
        """The app's answer to a request, or an error answer (timeout, unavailable, the transport's AffordError code): never raises."""
        timeout_answer = {"error": "The app did not answer in time (it may be in the background): look again later, or do it another way", "code": "timeout"}
        try:
            pending = self._send(request)
            if inspect.isawaitable(pending):
                task = asyncio.ensure_future(pending)
                try:
                    done, _ = await asyncio.wait({task}, timeout=self._timeout)
                finally:
                    if not task.done():
                        task.cancel()
                if not done:
                    return timeout_answer
                answer = task.result()
            else:
                answer = pending
        except AffordError as error:
            return {"error": error.message, "code": error.code}
        except Exception as error:
            return {"error": str(error), "code": "unavailable"}
        if not isinstance(answer, dict):
            return {"error": "The app gave no screen", "code": "unavailable"}
        return answer


def _failed(code: Any, error: Any) -> ToolAnswer:
    return ToolAnswer(text=f"Failed ({js_str(code)}): {js_str(error)}", is_error=True, code=code)
