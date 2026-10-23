# Getting started: web

AffordKit for the web works on the DOM, so it fits any framework (React, Vue, Svelte, plain HTML). The tree is built by
subtraction: buttons, links, fields, choices, tabs, dialogs, lists and headings are found by themselves. You add names, keys,
policies and operations where the defaults are not enough.

## Install

```sh
npm install affordkit
```

The package ships ES modules with types: `affordkit` (the protocol and the agent's side, no DOM) and `affordkit/dom` (the runtime
in the page).

To work on AffordKit and your app together, clone the repository beside your app and `npm install ../affordkit/js` (keep that
out of your committed `package.json`).

## Create the kit

One kit per page, created once:

```ts
import { AffordKit } from 'affordkit/dom';

export const kit = new AffordKit({
  // Leave the agent's own chat panel out of the tree
  skip: '#assistant-panel',
  // Ask the user before ops with policy confirm (without this, they come back needsConfirm)
  confirm: async ({ call, node, tool }) => window.confirmAgentAction(node?.name ?? tool?.name ?? '?'),
});

console.log(kit.context()); // the screen as a tree
```

Options: `root` (the part of the page the agent sees; default the whole document), `skip` (a selector left out, besides
`data-afford-skip`), `confirm`, `isVisible` (whether an element is on screen), `maxRead` (longest text a read returns),
`settle` (resolves once what the agent's calls changed has rendered; default a frame or two), `onAct` (before each op runs on an
element: show the user where), `onUserAction` (each thing the user does themselves while watched: see
[The user's own hands](concepts.md#the-users-own-hands)).

## Name things, give them keys and policies

With attributes, in markup:

```html
<button data-afford-key="compose.send" data-afford-policy="deny">Send</button>
<textarea data-afford="Body" data-afford-key="compose.body"></textarea>
<section data-afford="Filters" data-afford-role="region">…</section>
<div data-afford-skip>…the agent never sees this…</div>
```

| Attribute | Means |
|---|---|
| `data-afford="Name"` | The node's name (default: its label, text, `aria-label` or placeholder). |
| `data-afford-key="compose.send"` | A key that stays the same across pages and visits. |
| `data-afford-describe="…"` | What it is for, when the name is not enough. |
| `data-afford-role="region"` | Its role, when the element doesn't say it. |
| `data-afford-policy="deny"` | The policy for all its ops, or per op: `"press:deny, write:confirm"`. |
| `data-afford-secret` | A secret field (passwords and fields named like tokens or API keys are found by themselves). |
| `data-afford-skip` | Leave it, and everything in it, out. |
| `data-afford-container="list"` | A container (`data-afford-list` is the same, of kind list). |
| `data-afford-item="42"` | One entry of the container above it. |
| `data-afford-index="7"` | That entry's index among all, when only some are rendered. |

Or in code, which is what a component library does:

```ts
const undo = kit.register(element, {
  name: 'Send',
  key: 'compose.send',
  description: 'Sends the mail',
  role: 'button',
  policy: 'deny',            // or { press: 'deny' }
  skip: false,
});
// call undo() when the element goes away (most frameworks: in the ref's cleanup)
```

In React, register through a ref callback; React 19 runs the function it returns on unmount:

```tsx
<button ref={(el) => el && kit.register(el, { key: 'compose.send', policy: 'deny' })} onClick={send}>Send</button>
```

## Your own components

A custom control that is not a native element needs a role, and often its own ops. An op of your own with a standard name
(`press`, `set`) replaces the default:

```ts
kit.register(starEl, {
  name: 'Star',
  key: 'thread.star',
  role: 'checkbox',
  ops: [
    {
      name: 'set',
      description: 'Star or unstar the mail',
      params: { type: 'object', properties: { on: { type: 'boolean' } }, required: ['on'] },
      run: async ({ on }) => store.setStarred(id, Boolean(on)),
    },
  ],
});
```

`run(args, element)` gets the agent's arguments; what it returns goes back to the agent. Throw `new AffordError(code, message)`
(from `affordkit`) to say why it failed.

A custom op can do something no tap does (`archive` on a mail row). Prefer real taps for what the user should see happen; use a
custom op where a tap is not possible or would be a long detour.

## Long lists: containers

A short `<ul>` is a plain list. Anything long, virtualized or paged should be a container:

```html
<ul data-afford-container="list" data-afford-key="mail.list" aria-label="Inbox">
  <li data-afford-item="42">Lunch on Tuesday? <button data-afford-key="reply">Reply</button></li>
  …
</ul>
```

With nothing more, the kit searches entries by their text and scrolls through the list to reach ones not rendered. A
virtualized list, or one whose data is not all loaded, should say more:

```ts
kit.registerContainer(listEl, {
  key: 'mail.list',
  name: 'Inbox',
  kind: 'list',
  itemId: (el) => el.dataset.id,
  indexOf: (el) => Number(el.dataset.index),
  count: () => mails.length,
  items: async ({ offset, limit, query }) => {
    const page = await api.search({ query, offset, limit }); // can search the server, not just what is loaded
    return { count: page.total, items: page.mails.map((m) => ({ id: m.id, name: m.subject, description: m.from })) };
  },
  scrollTo: ({ id, index }) => virtualizer.scrollToIndex(index ?? mails.findIndex((m) => m.id === id)),
});
```

Controls inside an entry get keys under the entry's: `mail.list[42].reply`.

## Pages

```ts
kit.setRoutes({
  current: () => location.pathname,
  routes: [
    { path: '/mail/:box', description: 'A mailbox', params: { box: { values: ['inbox', 'archive', 'sent'] } } },
    { path: '/message/:id', description: 'One mail: reply, forward, archive' },
    { path: '/settings/:section', description: 'Settings' },
  ],
  navigate: (route) => router.push(route),
  back: () => history.back(),
  canGoBack: () => history.length > 1,
  // Optional: build a page off screen for a peek
  preview: async (route) => ({ root: await renderOffscreen(route), dispose: () => unmountOffscreen() }),
});
```

Keep the trees of pages already seen across reloads with `kit.snapshots()` and `kit.loadSnapshots(saved)`: peeks then know
pages not visited yet this run.

## App tools

For what needs no screen:

```ts
kit.registerTool({
  name: 'set_theme',
  description: 'Switch the app between light, dark and the system setting',
  inputSchema: { type: 'object', properties: { theme: { type: 'string', enum: ['light', 'dark', 'system'] } }, required: ['theme'] },
  policy: 'allow',
  execute: async ({ theme }) => settings.setTheme(String(theme)),
});
```

## Connect the agent

The page answers the agent's requests with `kit.answer(request)`. Send it over whatever your app already has (a WebSocket, your
API):

```ts
socket.on('affordkit', async ({ id, request }) => socket.emit('affordkit-answer', { id, answer: await kit.answer(request) }));
```

An agent that runs in the page itself needs no transport: `const ui = kit.agent()`.

See [Connecting an agent](connecting-an-agent.md) for the agent's side.

## Check what the agent sees

```ts
import { describe } from 'affordkit';
console.log(describe(kit.context()));
```

This is the text the model reads. Look for unnamed buttons, two controls with the same name, missing keys on things the agent
will use often, and anything that should be denied.
