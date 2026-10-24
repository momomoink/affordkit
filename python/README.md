# AffordKit for Python (the agent's side)

AffordKit puts an app's UI in front of an AI agent as a tree of controls with the operations you'd expect of them, under the app's
policies. The app builds the tree with the [Flutter](https://github.com/momomoink/affordkit/blob/main/flutter/README.md) or [JavaScript](https://github.com/momomoink/affordkit/blob/main/js/README.md) package and answers
requests with `kit.answer(request)`. This package is the other end, for a Python backend: `AffordRemote` sends those requests over
your channel, gives the model its tools, and turns each answer into text for it. Standard library only, Python 3.10+, async.

```sh
pip install affordkit
```

## Connect an agent

The app answers the agent's requests with `kit.answer(request)` (JSON in, JSON out), over the channel you already have. Where the
model runs, `AffordRemote` gives it its tools and runs them:

```python
from anthropic import AsyncAnthropic
from affordkit import AffordRemote, anthropic_tools, anthropic_result

async def ask_the_app(request: dict) -> dict:
    return await socket.ask("affordkit", request)  # the app: socket.on("affordkit", kit.answer)

ui = AffordRemote(send=ask_the_app)
ui.seen(screen_sent_with_the_message)  # optional: what the user was looking at

client = AsyncAnthropic()
res = await client.messages.create(model=model, max_tokens=4096, messages=messages, tools=anthropic_tools(ui.tools()))
results = [await anthropic_result(ui, b) for b in res.content if b.type == "tool_use" and ui.has(b.name)]
messages += [{"role": "assistant", "content": res.content}, {"role": "user", "content": results}]
```

With OpenAI's Chat Completions:

```python
from openai import AsyncOpenAI
from affordkit import openai_tools, openai_result

res = await AsyncOpenAI().chat.completions.create(model=model, messages=messages, tools=openai_tools(ui.tools()))
msg = res.choices[0].message
messages.append(msg)
messages += [await openai_result(ui, c) for c in msg.tool_calls or [] if ui.has(c.function.name)]
```

After each act the model gets what changed on screen, not the whole tree again:

```
Done.

The screen changed:
Now at /reply/7 (was /message/7) — can go back.
+ [n12 key=compose.body] textbox "Body" — read, write, append, clear
+ [n13 key=compose.send] button "Send" — press(deny)
- [thread.reply] button "Reply"
```

Or call it yourself: `answer = await ui.handle(name, input)` gives a `ToolAnswer` with `text`, `is_error`, `code`, `context` (the
screen it left) and `images` (`{"mime", "data"}`, a look with `picture` or an op `view`). It never raises: a failure is an answer
with `is_error` and a code — `not_found`, `no_op`, `bad_args`, `denied`, `needs_confirm`, `declined`, `disabled`, `unreachable`,
`timeout`, `unavailable`, `away`, `expired`, `failed`.

Other stacks: `openai_responses_tools` / `openai_responses_result` (the Responses API), `mcp_handlers` (serve the app's screen as an
MCP server's tools), `runners` (each tool with an async `run`, for LangChain or a loop of your own). They return plain dicts in each
SDK's shape and take the SDK's tool-call objects or dicts; no SDK is a dependency.

Options, all keyword: `timeout` (seconds, default 45), `screen` (`"changes"` or `"whole"`), `tools` (which tools to offer),
`max_nodes`, `present` (a function: when it returns `False` the user has left the app, and the screen tools answer `away`),
`on_handoff` (where a handoff the agent leaves goes: the agent gets `ui_handoff`; see
[Handoffs](https://github.com/momomoink/affordkit/blob/main/docs/js/handoffs.md)) and `handoff_ttl` (seconds, default 24 h). Times
are seconds, as is usual in Python; on the wire everything stays as the protocol says (camelCase keys, `expiresAt` in ms).

## Tests

The tests run the shared conformance cases (`../conformance/remote.json`, written from the TypeScript reference) and unit tests of
their own. No Python needed, with Docker (from Git Bash on Windows, keep `MSYS_NO_PATHCONV=1` and the `cygpath`):

```sh
MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "$PWD/.."):/repo" -w /repo/python python:3.12.7-slim \
  sh -c "pip install -q -e '.[test]' && pytest -q"
```

On Linux or macOS, `-v "$PWD/..:/repo"`; or with a local Python, `pip install -e '.[test]' && pytest -q` in this folder.
