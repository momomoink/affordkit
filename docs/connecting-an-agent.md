# Connecting an agent

Your app holds the kit; your model runs somewhere (your server, a worker, the page itself). They talk in two messages:

- **request** (agent → app): `{ "look": true }` (optionally `"picture": true`), or `{ "calls": [ ... ] }`;
- **answer** (app → agent): `{ "context": ..., "results": [ ... ], "picture": ... }`, or `{ "error": "...", "code": "..." }`.

The app answers with `kit.answer(request)`. The agent's side is `AffordRemote` (TypeScript) or `AffordAgent` (Dart): give it a
`send` function, and it gives the model its tools and runs them.

## The agent's side

```ts
import { AffordRemote, anthropicTools, anthropicResult } from 'affordkit';

const ui = new AffordRemote({
  send: (request) => transport.ask(appId, request), // resolves with the app's kit.answer(request)
  timeoutMs: 45_000,                                // then the tool fails with code timeout
});
ui.seen(screenSentWithTheMessage);                  // optional: the screen the user's message came with
```

`ui.tools()` are the five tools (`ui_look`, `ui_act`, `ui_tool`, `ui_navigate`, `ui_peek`; `ui_tool` only when the app has tools of
its own). `ui.handle(name, input)` runs one and resolves with `{ text, isError, code, images, context }`. It never throws: a failure
is an answer with `isError` and a `code`.

In Dart it is the same: `AffordAgent(send: ...)`, `agent.tools()`, `agent.handle(name, input)`. An agent in the app itself needs no
transport: `kit.agent()`.

### What the model gets back

`ui_look` gives the whole screen as text. After an act, the model gets what it did to the screen, from what it last saw, not the
whole tree again:

```
Done.

The screen changed:
Now at /reply/7 (was /message/7) — can go back.
+ [w2 key=compose.body] textbox "Body" — read, write, append, clear
+ [w3 key=compose.send] button "Send" — press(deny)
- [thread.reply] button "Reply"
```

A dialog opening over the page is one line (`+ [behind-3] page "/mail/inbox" (behind) — now under what shows: its 12 controls still
work, unseen`), not each control again. When most of the screen changed, the answer is the whole new screen. Pass
`screen: 'whole'` (Dart: `wholeScreen: true`) for the whole tree every time.

`ui_look` with `picture: true`, and the `view` op, return a picture beside the text (`images`). Pass it to models that take images.

### Error codes

| code | meaning |
|---|---|
| `not_found` | no such node (it went), route, tool or entry |
| `no_op` | the node has no such op |
| `bad_args` | the op's arguments are missing or wrong |
| `denied` | policy deny: the user does this themselves |
| `needs_confirm` | policy confirm, and the app gave no way to ask: nothing was done |
| `declined` | the user was asked and said no |
| `disabled` | the control is disabled (or read-only) |
| `unreachable` | something is over it and it can't be worked from there |
| `timeout` | the app did not answer in time |
| `unavailable` | no app to work, or it could not answer |
| `failed` | anything else that went wrong doing it |

The text says it in words for the model; the code is for your loop (on `needs_confirm`, ask the user and try again).

## Agent stacks

Plain objects in each stack's shape; no SDK is imported.

**Anthropic Messages API**

```ts
const res = await client.messages.create({ model, max_tokens, system, messages, tools: anthropicTools(ui.tools()) });
const results = [];
for (const block of res.content) if (block.type === 'tool_use' && ui.has(block.name)) results.push(await anthropicResult(ui, block));
messages.push({ role: 'assistant', content: res.content }, { role: 'user', content: results });
```

Pictures go into the `tool_result` as image blocks.

**OpenAI** (`openaiTools` / `openaiResult` for Chat Completions, `openaiResponsesTools` / `openaiResponsesResult` for the
Responses API). Chat Completions tool results are text, so pictures are left out there.

**MCP**: the app's screen as an MCP server's tools, for any MCP client:

```ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const h = mcpHandlers(ui);
server.setRequestHandler(ListToolsRequestSchema, h.list);
server.setRequestHandler(CallToolRequestSchema, h.call);
```

**Anything else** (LangChain, the AI SDK, a loop of your own): `runners(ui)` gives each tool with a `run(input)` function.

Dart has `anthropicTools`, `anthropicResult`, `openaiTools`, `openaiResult`, `mcpToolList` and `mcpToolCall`.

## Transports

The app and the agent are usually on two machines. Use the channel your app already has:

- **Server-sent events or WebSocket + a POST back**: the server pushes `{ id, client, request }` to the app, the app POSTs
  `{ id, answer }`. Tag requests with the id of the app instance the user is chatting from, so another device of the same user
  doesn't answer.
- **The same page**: `kit.agent()`.

Put a timeout on every request (the app may be in the background) and answer every request, even with an error.

## Prompting

The tool descriptions explain the tree, containers, keys and policies to the model. Add what is specific to your app:

- what the user is looking at when they write (send `kit.context()` with the chat message and `ui.seen()` it);
- that it should work the screen the user sees, step by step, and leave denied actions (Send) to the user;
- that it should go to a page before acting on it when the user is watching, rather than act on pages underneath.
