# Connecting an agent

Your page holds the kit; your model runs somewhere (your server, a worker, the page itself). They talk in two messages:

- **request** (agent → page): `{ "look": true }`, or `{ "calls": [ ... ] }`;
- **answer** (page → agent): `{ "context": ..., "results": [ ... ] }`, or `{ "error": "...", "code": "..." }`.

The page answers with `kit.answer(request)`. The agent's side is `AffordRemote`, from `affordkit` (no DOM, so it runs on a server):
give it a `send` function, and it gives the model its tools and runs them.

## The page's side

```ts
import { kit } from './affordkit-setup';

socket.on('affordkit', async ({ id, request }) => {
  socket.emit('affordkit-answer', { id, answer: await kit.answer(request) });
});
```

Answer every request, even when something goes wrong (`kit.answer` never throws: it answers with `{ error, code }`).

## The agent's side

```ts
import { AffordRemote } from 'affordkit';

const ui = new AffordRemote({
  send: (request) => askThePage(userSession, request), // resolves with the page's kit.answer(request)
  timeoutMs: 45_000,                                   // then the tool fails with code timeout
});
ui.seen(screenSentWithTheMessage);                     // optional: the screen the user's message came with
```

- `ui.tools()`: the five tools (`ui_look`, `ui_act`, `ui_tool`, `ui_navigate`, `ui_peek`; `ui_tool` only when the page has tools of
  its own; `ui_handoff` too with `onHandoff`), each `{ name, description, inputSchema }`.
- `ui.has(name)`: whether a tool the model called is one of these.
- `ui.handle(name, input)`: runs one and resolves with `{ text, isError, code, images, context }`. It never throws: a failure is an
  answer with `isError` and a `code`.

Options: `screen: 'whole'` for the whole tree after every act instead of what changed, `tools` to offer only some, `maxNodes`.

An agent running in the page itself needs no transport: `const ui = kit.agent()`.

### When the user has left

`present: () => boolean` says whether the user is in the app; while it says no, the screen tools answer code `away` at once.
`onHandoff(handoff)` adds a sixth tool, `ui_handoff`, for the agent to leave the user a message and the calls that take them to
what it did when they come back. See [Handoffs](handoffs.md).

## What the model gets back

`ui_look` gives the whole page as text. After an act, the model gets what it did to the page, from what it last saw:

```
Done.

The screen changed:
Now at /reply/7 (was /message/7) — can go back.
+ [n12 key=compose.body] textbox "Body" — read, write, append, clear
+ [n13 key=compose.send] button "Send" — press(deny)
- [thread.reply] button "Reply"
```

When most of the page changed, the answer is the whole new page. `describe(context)` and `describeChange(before, after)` make the
same text for a loop of your own.

The `view` op returns a picture beside the text (`images`); pass it to models that take images.

## Error codes

| code | meaning |
|---|---|
| `not_found` | no such node (it went), route, tool or entry |
| `no_op` | the node has no such op |
| `bad_args` | the op's arguments are missing or wrong |
| `denied` | policy deny: the user does this themselves |
| `needs_confirm` | policy confirm, and the page gave no way to ask: nothing was done |
| `declined` | the user was asked and said no |
| `disabled` | the control is disabled (or read-only) |
| `unreachable` | something is over it and it can't be worked from there |
| `timeout` | the page did not answer in time |
| `unavailable` | no page to work, or it could not answer |
| `away` | the user is not in the app now (`present` says so): the screen can't be worked; leave a handoff |
| `expired` | a handoff past its `expiresAt`: not run |
| `failed` | anything else that went wrong doing it |

The text says it in words for the model; the code is for your loop (on `needs_confirm`, ask the user and try again). Your own ops
and tools can say which by throwing `new AffordError(code, message)`.

## Agent stacks

Plain objects in each stack's shape; no SDK is imported.

**Anthropic Messages API**

```ts
import { anthropicTools, anthropicResult } from 'affordkit';

const res = await client.messages.create({ model, max_tokens, system, messages, tools: anthropicTools(ui.tools()) });
const results = [];
for (const block of res.content) if (block.type === 'tool_use' && ui.has(block.name)) results.push(await anthropicResult(ui, block));
messages.push({ role: 'assistant', content: res.content }, { role: 'user', content: results });
```

Pictures go into the `tool_result` as image blocks.

**OpenAI**: `openaiTools` / `openaiResult` for Chat Completions, `openaiResponsesTools` / `openaiResponsesResult` for the Responses
API. Chat Completions tool results are text, so pictures are left out there.

**MCP**: the page's screen as an MCP server's tools, for any MCP client:

```ts
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { mcpHandlers } from 'affordkit';

const h = mcpHandlers(ui);
server.setRequestHandler(ListToolsRequestSchema, h.list);
server.setRequestHandler(CallToolRequestSchema, h.call);
```

**Anything else** (LangChain, the AI SDK, a loop of your own): `runners(ui)` gives each tool with a `run(input)` function.

## Transports

The page and the model are usually on two machines. Use the channel your app already has: a WebSocket, or server-sent events
plus a POST back. Tag each request with the id of the page instance the user is chatting from, so another tab or device of the
same user doesn't answer. Put a timeout on every request.

## Prompting

The tool descriptions explain the tree, containers, keys and policies to the model. Add what is specific to your app:

- what the user is looking at when they write (send `kit.context()` with the chat message, and `ui.seen()` it);
- that it should work the page the user sees, step by step, and leave denied actions (Send) to the user.
