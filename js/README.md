<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit-dark.svg">
    <img src="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit.svg" alt="AffordKit" width="140">
  </picture>
</p>

# AffordKit

Your app's UI, for AI agents to see and use. The controls on screen become a small tree — what each is, what it's called, a short
state, and the operations you'd expect of it (a button is pressed, a field read and written, an entry of a long list fetched) — and the agent
answers with calls that the app runs under its own policies (`allow`, `confirm`, `deny`).

The same JSON protocol on every platform: this package (TypeScript / JavaScript, for the DOM) and the Flutter package ([`../flutter`](../flutter/README.md)).

```js
import { AffordKit } from 'affordkit/dom';
import { describe, AGENT_TOOLS, toCall, describeResult } from 'affordkit';

const kit = new AffordKit();
const ctx = kit.context();                       // → the agent (describe(ctx) as text for a prompt)
const { results, context } = await kit.execute([ // the agent's calls → its next round
  { node: 'compose.body', op: 'write', args: { text: 'Hi!' } },
  { node: 'mail.list', op: 'item', args: { id: '42' } }, // one entry of a container, as a tree of its own
  { node: 'mail.list[42].star', op: 'press' },
]);
```

## Plain JavaScript, no build step

The package ships as ES modules (`dist/*.js`, with `.d.ts` types beside them for editors). In a page, import it directly:

```html
<button data-afford-key="send" data-afford-policy="deny">Send</button>
<div data-afford-container="list" data-afford-key="todo" aria-label="To do">
  <div data-afford-item="milk">Milk <button data-afford-key="done">Done</button></div>
  <div data-afford-item="bread">Bread <button data-afford-key="done">Done</button></div>
</div>

<script type="module">
  // From your server (copy node_modules/affordkit/dist), or a CDN once published
  import { AffordKit } from './affordkit/dom.js';
  import { describe, describeResult } from './affordkit/index.js';

  const kit = new AffordKit();
  console.log(describe(kit.context()));
  // [n3 key=todo] container "To do" (list) 2 entries, showing 0–1 (entry keys: todo[<id>]) — read, item, items, scroll_to, scroll
  //   · [todo[milk]] #0 "Milk Done"
  //   · [todo[bread]] #1 "Bread Done"

  const { results } = await kit.execute([{ node: 'todo', op: 'item', args: { id: 'bread' } }]);
  console.log(describeResult(results[0]));
  // Entry todo[bread] #1:
  // [n5 key=todo[bread]] listitem "Bread Done" — read, press
  //   [n6 key=todo[bread].done] button "Done" — press
  await kit.execute([{ node: 'n6', op: 'press' }]); // (or by key: todo[bread].done)
</script>
```


Build it with `pnpm --filter affordkit build` (or `tsc -p tsconfig.build.json`).

## Containers

Many of the same thing — a mail list, a grid, a thread's messages, tabs — is a **container**: one node in the tree that says what
of (`kind`), how many (`count`), which show (`first`–`last`), and a short preview of those (`preview`: key, index, name), but not
their controls. The agent fetches the entry it wants with the container's `item` op (by `id` or key, `index`, or `query`) and gets
it back as a tree of its own — live ids and keys it can act on, that round or the next. Entries' keys are made from the
container's (`todo[milk]`), controls inside them under that (`todo[milk].done`); a key can also be acted on straight away, and the
entry is fetched first (scrolled to, when it isn't built). Containers nest: `thread[a].files[1].open`.

- `data-afford-container="<kind>"` (or `data-afford-list`) marks one; `data-afford-item="<id>"` its entries. A `<ul>` / `<ol>` with
  more than 20 items is a container by itself; a shorter one is a plain list, its items in the tree.
- What is in a container besides its entries (a "show older" button) shows as its children.
- With nothing more, the kit finds entries itself: `items {query}` and `item {query}` match all of an entry's text (each word),
  and when the list holds fewer than asked for — a virtualized one renders only what shows — it scrolls through it a page at a
  time, then back (or, for `item`, stays on the one found). An entry not rendered is scrolled to the same way.
- A virtualized one can still say it all itself — faster, with data not loaded yet (a server search), and filters of its own (and
  it can build one off screen for `item` with `preview: true`):

```js
kit.registerContainer(listEl, {
  key: 'mail.list',
  name: 'Inbox',
  kind: 'list',
  itemId: (el) => el.dataset.id,
  indexOf: (el) => Number(el.dataset.index),
  count: () => mails.length,
  items: ({ offset, limit, query }) => mails.slice(offset, offset + limit).map((m) => ({ id: m.id, name: m.subject })),
  scrollTo: ({ id, index }) => virtualizer.scrollToIndex(index ?? mails.findIndex((m) => m.id === id)),
  build: ({ id }) => ({ root: renderRowOffscreen(id) }), // optional
});
```

Container ops: `item {id | index | query, preview}`, `items {offset, limit, query}`, `scroll_to {index | item}`, `scroll {by: pages}`,
`read`.

## Pages

`kit.setRoutes({ current, routes, navigate, back, canGoBack, settle, preview })`: the agent sees where the user is, can navigate
(or go back), and can `peek` at another page's tree before going there, then act on it by key after navigating.

## Hooking up an agent

The agent's side is `AffordRemote`: give it a way to send a request to the app, and it gives the agent its tools (`ui_look`,
`ui_act`, `ui_tool`, `ui_navigate`, `ui_peek`) and runs them. The app answers each request with its kit's `answer()`. The
transport is yours — a WebSocket, HTTP, a message port — and only JSON crosses it.

```js
// Where the agent runs (a server, a worker)
import { AffordRemote } from 'affordkit';
const ui = new AffordRemote({ send: (request) => socket.ask(request) });
ui.seen(contextSentWithTheMessage); // optional: the screen the user's message came with
const { text, isError, code } = await ui.handle(name, input); // a tool the model called → its result

// In the app
socket.onAsk((request) => kit.answer(request));

// Or an agent in the page itself: no transport
const ui = kit.agent();
```

`handle` never throws: a failure is an answer with `isError` and a `code`. The Flutter package has the same, in Dart:
`AffordAgent(send: ...)`, `kit.answer(request)`, `kit.agent()`.

### What the agent gets back

After an act, not the whole tree again but what it did to the screen (from what the agent last saw) — the route if it changed,
the nodes that came (`+`), went (`-`) or changed (`~`):

```
Done.

The screen changed:
Now at /reply/7 (was /message/7) — can go back.
+ [w2 key=compose.body] textbox "Body" — read, write, append, clear
+ [w3 key=compose.send] button "Send" — press(deny)
- [thread.reply] button "Reply"
```

When most of the screen changed it is the whole new screen; `screen: 'whole'` asks for that every time. `describeChange(before,
after)` does it for a loop of your own.

### Agent stacks

The tools in each stack's shape, and the answers back in it — plain objects, no SDK imported:

```js
import { anthropicTools, anthropicResult, openaiTools, openaiResult, openaiResponsesTools, openaiResponsesResult, mcpHandlers, runners } from 'affordkit';

// Anthropic Messages API
const res = await client.messages.create({ model, max_tokens, messages, tools: anthropicTools(ui.tools()) });
const results = [];
for (const block of res.content) if (block.type === 'tool_use' && ui.has(block.name)) results.push(await anthropicResult(ui, block));
messages.push({ role: 'assistant', content: res.content }, { role: 'user', content: results });

// OpenAI Chat Completions (openaiResponsesTools / openaiResponsesResult for the Responses API)
const r = await openai.chat.completions.create({ model, messages, tools: openaiTools(ui.tools()) });
for (const call of r.choices[0].message.tool_calls ?? []) messages.push(await openaiResult(ui, call));

// MCP (@modelcontextprotocol/sdk): the app's screen as an MCP server's tools — any MCP client can work it
const h = mcpHandlers(ui);
server.setRequestHandler(ListToolsRequestSchema, h.list);
server.setRequestHandler(CallToolRequestSchema, h.call);

// Anything else (LangChain, the AI SDK, a loop of your own): each tool with a run function
for (const t of runners(ui)) register(t.name, t.description, t.inputSchema, async (input) => (await t.run(input)).text);
```

### Errors

Each failed result has a `code`, for the loop to act on without reading the words:

| code | |
|---|---|
| `not_found` | no such node (it went), route, tool or entry |
| `no_op` | the node has no such op |
| `bad_args` | the op's arguments are missing or wrong |
| `denied` | policy `deny`: the user does this themselves |
| `needs_confirm` | policy `confirm`, and the app gave no way to ask: nothing was done |
| `declined` | the user was asked and said no |
| `disabled` | the control is disabled (or read-only) |
| `unreachable` | something is over it and it can't be worked from there |
| `timeout` | the app did not answer in time |
| `unavailable` | no app to work, or it could not answer |
| `failed` | anything else that went wrong doing it |

An app's own ops and tools can say which by throwing `new AffordError(code, message)`.
