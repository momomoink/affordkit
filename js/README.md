<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit-dark.svg">
    <img src="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit.svg" alt="AffordKit" width="140">
  </picture>
</p>

# AffordKit for JavaScript

Your web app's UI, for AI agents to see and use. Works with any framework: React, Vue, Svelte, Angular, plain HTML.

The page's controls become a tree the agent reads: what each is, what it shows, its state, and what can be done to it. The agent
answers with calls (press, type, scroll, go to a page) that your app runs under its own rules: `allow`, `confirm` (the user says
yes first) or `deny` (the user's own act).

```
Route: /message/42 — can go back
[n4 key=thread.reply] button "Reply" — press
[n7] heading "Lunch on Tuesday?"
[n9 key=compose.send] button "Send" — press(deny)
```

Two entry points:

- **`affordkit/dom`**: the runtime in the page.
- **`affordkit`**: the protocol and the agent's side (no DOM), for your server or worker: the agent's tools, answers as text, and
  the Anthropic, OpenAI and MCP shapes.

Building a Flutter app? See the [Flutter README](https://github.com/momomoink/affordkit/blob/main/flutter/README.md).

## Install

```sh
npm install affordkit
```

## Set up

```ts
import { AffordKit } from 'affordkit/dom';

export const kit = new AffordKit({
  skip: '#assistant-panel', // leave the agent's own chat out
  confirm: async ({ node, tool }) => askTheUser(node?.name ?? tool?.name ?? '?'), // ops with policy confirm
});
```

Nothing needs registering to be seen: buttons, links, fields, choices, tabs, dialogs, lists and headings are in the tree by
themselves. Add names, keys and policies where the defaults are not enough.

## Name things, give them keys and policies

In markup:

```html
<button data-afford-key="compose.send" data-afford-policy="deny">Send</button>
<textarea data-afford="Body" data-afford-key="compose.body"></textarea>
<button data-afford="Archive" data-afford-describe="Moves the mail to the archive"><svg aria-hidden="true">…</svg></button>
<div data-afford-skip>…the agent never sees this…</div>
```

Or in code, for components:

```tsx
// React: register in a ref callback; React 19 runs the returned undo on unmount
<button ref={(el) => el && kit.register(el, { key: 'compose.send', policy: 'deny' })} onClick={send}>Send</button>
```

| Attribute | Means |
|---|---|
| `data-afford="Name"` | the node's name (default: label, text, `aria-label`, placeholder) |
| `data-afford-key` | a key that stays the same across visits (`<screen>.<control>`) |
| `data-afford-describe` | what it is for |
| `data-afford-role` | its role, when the element doesn't say it |
| `data-afford-policy` | `allow`, `confirm`, `deny`, or per op: `"press:deny, write:confirm"` |
| `data-afford-secret` | a secret field (password fields are found by themselves) |
| `data-afford-skip` | leave it out, with everything in it |
| `data-afford-container` / `data-afford-item` | a long list, and its entries |

Each role has its ops: `press` for buttons and links, `read` / `write` / `append` / `clear` for fields, `toggle` / `set` for
checkboxes, `select` for tabs and radios, `choose` for selects, `read` for text, `view` for images.

## Your own components and functions

A custom control needs a role, and an op of its own where a click is not the action (one named like a standard op, such as
`press` or `set`, replaces it):

```ts
kit.register(starEl, {
  name: 'Star',
  key: 'thread.star',
  role: 'checkbox',
  ops: [{
    name: 'set',
    params: { type: 'object', properties: { on: { type: 'boolean' } }, required: ['on'] },
    run: async ({ on }) => store.setStarred(id, Boolean(on)),
  }],
});
```

What `run` returns goes back to the agent. Throw `new AffordError(code, message)` (from `affordkit`) to say why it failed.

## Long lists

A list is one node with a preview of what shows; the agent fetches the entry it wants as a tree of its own
(`mail.list[42].reply`), searches, and scrolls:

```html
<ul data-afford-container="list" data-afford-key="mail.list" aria-label="Inbox">
  <li data-afford-item="42">Lunch on Tuesday? <button data-afford-key="reply">Reply</button></li>
</ul>
```

With nothing more, the kit searches entries by their text and scrolls through the list to reach ones not rendered. A
virtualized list, or one whose data is on a server, says more:

```ts
kit.registerContainer(listEl, {
  key: 'mail.list',
  name: 'Inbox',
  itemId: (el) => el.dataset.id,
  count: () => total,
  items: async ({ offset, limit, query }) => api.searchMail({ query, offset, limit }), // [{ id, name, description }]
  scrollTo: ({ id, index }) => virtualizer.scrollToIndex(index ?? indexOfMail(id)),
});
```

## Pages and app tools

```ts
kit.setRoutes({
  current: () => location.pathname,
  routes: [
    { path: '/mail/:box', description: 'A mailbox', params: { box: { values: ['inbox', 'archive'] } } },
    { path: '/message/:id', description: 'One mail: reply, forward, archive' },
  ],
  navigate: (route) => router.push(route),
  back: () => history.back(),
});

// What needs no screen
kit.registerTool({
  name: 'set_theme',
  description: 'Switch between light, dark and the system setting',
  inputSchema: { type: 'object', properties: { theme: { type: 'string', enum: ['light', 'dark', 'system'] } }, required: ['theme'] },
  execute: async ({ theme }) => settings.setTheme(String(theme)),
});
```

## Connect an agent

The page answers the agent's requests with `kit.answer(request)` (JSON in, JSON out), over the channel you already have. Where
the model runs, `AffordRemote` gives it its tools and runs them:

```ts
// In the page
socket.on('affordkit', async ({ id, request }) => socket.emit('affordkit-answer', { id, answer: await kit.answer(request) }));

// On the server
import { AffordRemote, anthropicTools, anthropicResult } from 'affordkit';

const ui = new AffordRemote({ send: (request) => askThePage(request) });
ui.seen(screenSentWithTheMessage); // optional: what the user was looking at

const res = await client.messages.create({ model, max_tokens, messages, tools: anthropicTools(ui.tools()) });
const results = [];
for (const block of res.content) if (block.type === 'tool_use' && ui.has(block.name)) results.push(await anthropicResult(ui, block));

// An agent in the page itself needs no transport
const local = kit.agent();
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

Other stacks: `openaiTools` / `openaiResult` (Chat Completions), `openaiResponsesTools` / `openaiResponsesResult`, `mcpHandlers`
(serve the page's screen as an MCP server's tools), `runners` (LangChain, the AI SDK, a loop of your own). A failed call carries a
code: `not_found`, `no_op`, `bad_args`, `denied`, `needs_confirm`, `declined`, `disabled`, `unreachable`, `timeout`,
`unavailable`, `failed`. More in [Connecting an agent](https://github.com/momomoink/affordkit/blob/main/docs/js/connecting-an-agent.md).

## What to let the agent do

- **Allow** what is reversible and visible: open, search, type into a draft, star, archive.
- **Confirm** what is hard to undo or leaves the app: delete, unsubscribe, accept an invite.
- **Deny** the user's own acts: send, pay, publish, grant permissions. The agent can still point to them.
- **Leave out** secrets, other people's private data, and the agent's own chat panel (`data-afford-skip`, or `skip`).

More in [What to expose](https://github.com/momomoink/affordkit/blob/main/docs/js/what-to-expose.md).

## Plain JavaScript

The package is ES modules with `.d.ts` types beside them; it works in a page without a build step:

```html
<script type="module">
  import { AffordKit } from './node_modules/affordkit/dist/dom.js';
  import { describe } from './node_modules/affordkit/dist/index.js';
  const kit = new AffordKit();
  console.log(describe(kit.context())); // the text the model reads
</script>
```

## Let your coding agent add it

The repository has an agent skill that adds AffordKit to an existing app: it surveys the project, names the controls, asks you
about the risky actions, makes lists containers, declares routes and tools, and connects the agent. In Claude Code:

```text
/plugin install affordkit --marketplace momomoink/affordkit
```

Then ask it to "add AffordKit to this app". Other ways to install it are in the
[repository README](https://github.com/momomoink/affordkit#let-your-coding-agent-add-it).

## More

- [Getting started: web](https://github.com/momomoink/affordkit/blob/main/docs/js/getting-started.md): every option, in more detail.
- [Concepts](https://github.com/momomoink/affordkit/blob/main/docs/js/concepts.md): the tree, ops, policies, containers, pages.
- [Protocol](https://github.com/momomoink/affordkit/blob/main/docs/protocol.md): the JSON.
