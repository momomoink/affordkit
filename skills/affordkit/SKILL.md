---
name: affordkit
description: Add AffordKit to an existing web (DOM, React, Vue, Svelte) or Flutter app so an AI agent can see and operate its UI, and connect the app to an agent backend. Use when the user wants to make an app agent-operable, add or install AffordKit, tag or mark UI controls for an agent, decide what an AI assistant may do in the app, expose a custom widget or a function to an agent, or hook an agent (Anthropic, OpenAI, MCP or a custom loop) up to the app's screen.
license: MIT
---

# Adding AffordKit to an existing app

AffordKit turns an app's screen into a tree of controls an agent can read, and runs the agent's calls (press, type, scroll,
navigate, app tools) under the app's own policies: `allow`, `confirm` (the user says yes first) or `deny` (the user's own act).
Your job is to install it, put the app's controls into the tree with the right names, keys and policies, and connect it to the
agent, without changing what the app does for its users.

The references come in one set per platform. Find the platform in step 1, then read only that set, as you need it:

| | Flutter | Web (JavaScript / TypeScript) |
|---|---|---|
| The tree, ops, policies, containers, pages, app tools | [flutter/concepts.md](references/flutter/concepts.md) | [js/concepts.md](references/js/concepts.md) |
| Install, set up, afford or name controls, containers, routes, tools | [flutter/getting-started.md](references/flutter/getting-started.md) | [js/getting-started.md](references/js/getting-started.md) |
| Which policy fits what (read before step 4) | [flutter/what-to-expose.md](references/flutter/what-to-expose.md) | [js/what-to-expose.md](references/js/what-to-expose.md) |
| Transports, the agent's side, answers, error codes, model APIs | [flutter/connecting-an-agent.md](references/flutter/connecting-an-agent.md) | [js/connecting-an-agent.md](references/js/connecting-an-agent.md) |

An agent backend in TypeScript (a Node server) uses [js/connecting-an-agent.md](references/js/connecting-an-agent.md) whatever
the app is written in. [protocol.md](references/protocol.md) is the JSON both speak, for a custom agent side.

## Workflow

Copy this checklist into your notes and tick it off:

```
- [ ] 1. Survey the project
- [ ] 2. Install AffordKit
- [ ] 3. Create the kit
- [ ] 4. Inventory actions and decide policies (ask the user about the risky ones)
- [ ] 5. Put controls into the tree, shared components first
- [ ] 6. Make long lists containers
- [ ] 7. Cover custom widgets and add custom ops where a tap won't do
- [ ] 8. Declare routes
- [ ] 9. Register app tools for actions that need no screen
- [ ] 10. Connect the agent
- [ ] 11. Verify: print the tree, add tests for keys and policies
```

### 1. Survey the project

Find out, before changing anything:

- **Platform.** `pubspec.yaml` with a `flutter` dependency means the Flutter package. A `package.json` web app (React, Vue,
  Svelte, Angular, plain HTML) means the DOM package. An app with both (a web client and a phone app) gets both, and the agent
  side once.
- **Shared UI components.** Buttons, icon buttons, title bars, list rows, settings rows, form fields, dialogs. Afford these once
  and every screen that uses them is covered.
- **Navigation.** The router (React Router, Vue Router, Next.js, go_router, `Navigator`) and the app's routes.
- **Lists.** Long, virtualized or paged lists, and where their data comes from (loaded, or searched on a server).
- **The agent.** Is there already an assistant or a backend that runs a model? Where does the model run, and what channel does
  the app already have to it (WebSocket, server-sent events, push, HTTP)?
- **Tests.** How UI tests run, so you can add checks for the tree.

### 2. Install AffordKit

Web: `npm install affordkit` (or pnpm / yarn). Flutter: `flutter pub add affordkit`. Before the packages are published, or to
develop against a local checkout, see the Install sections of the getting-started references. A local path override
(`pubspec_overrides.yaml`, `pnpm link`) must never be committed: the committed dependency is always a version.

### 3. Create the kit

- **Web:** one `new AffordKit({ skip, confirm })` from `affordkit/dom`, created once at startup. `skip` leaves out the app's own
  assistant panel.
- **Flutter:** use `AffordKit.instance`, set `confirm`, `onAct` and `typeDelay`, and put `AffordPreviewHost` in
  `MaterialApp.builder`.

`confirm` must ask the user in the app's own UI (a dialog or a card) and resolve with their answer. Without it, `confirm`
actions come back `needs_confirm` and are not done.

### 4. Inventory actions and decide policies

List every action on every main screen and give each one a choice:

| Choice | For |
|---|---|
| allow | reversible, visible in the app: open, navigate, search, filter, type into a draft, star, mark read, archive |
| confirm | hard to undo, or leaves the app for the user: delete permanently, unsubscribe, accept an invite, change an account setting |
| deny | the user's own act: send, pay, publish, sign, grant permissions, change who can see something |
| leave out | what the agent must not see: secrets, other people's private data, admin areas, the agent's own chat panel |

Rules:

- When unsure between two, pick the stricter.
- Show the user your list of `confirm`, `deny` and left-out actions, and ask about anything ambiguous before going on. Policy
  is their call, not yours.
- Never make a secret readable. Password and one-time-code fields are denied by themselves; mark other secret fields
  (`data-afford-secret` on the web) or leave them out.
- A custom op or app tool gets the same policy as the control it stands for. Never add a tool that does what a denied control
  does (a `send_now` tool beside a denied Send).

### 5. Put controls into the tree

- **Web:** native elements are already in the tree. Add `data-afford` (name), `data-afford-key`, `data-afford-describe`,
  `data-afford-policy`, `data-afford-role`, `data-afford-skip` in markup, or `kit.register(el, { ... })` in component code (React:
  in a ref callback, returning its undo).
- **Flutter:** wrap widgets with `.afford(name, key:, description:, role:, policy:, policies:, state:, ops:)`. Only afforded
  widgets are in the tree, so cover every control the agent should reach.

Conventions:

- **Name** = the label the user sees. Add a `description` for icon-only or ambiguous controls.
- **Keys** for controls the agent will use often, in a stable scheme: `<screen>.<control>` (`compose.body`, `thread.reply`,
  `settings.notifications`). Keys inside a list entry are relative to the entry (`reply` becomes `mail.list[42].reply`).
- **Shared components first.** Give the component a way to pass a key and a policy through (a title bar button that affords
  itself from its tooltip, with optional `affordKey` and `policy` parameters, is a good pattern). Then fill in the gaps per screen.
- **One node per meaning.** Afford the button, not its icon and label too. Wrap groups that belong together (a toolbar, a filter
  bar) as a `region`.
- **Don't change layout or behavior.** `.afford()` and `register` add no visual layer. Don't restructure widgets to afford them.

### 6. Make long lists containers

Anything over a couple of dozen entries, virtualized or paged:

- **Web:** `data-afford-container="list"` with `data-afford-item="<id>"` on the entries, or `kit.registerContainer(el, { key, name,
  itemId, count, items, scrollTo })`.
- **Flutter:** `.affordContainer(name, key:, kind:)` on the list and `.affordItem(id, index:)` on each row.

With nothing more the kit searches entries by their text and scrolls to reach them. When the data is not all loaded, give `items`
a real search (`items(offset, limit, query)` calling the server) and `count`.

### 7. Custom widgets and custom ops

- A widget of the app's own that isn't a native control: give it a `role` and its `state` (`{checked}`, `{selected}`,
  `{disabled}`) so the agent knows what it is and how it stands.
- A standard op taps the control, which works for anything that responds to a tap. Add a `CustomOp` (Flutter) or an `ops` entry
  (web) when a tap is not the right action, or to replace one (an op named `press` or `set` replaces the standard one).
- Prefer real taps for what the user watches happen; use custom ops for what has no good path on screen.

### 8. Declare routes

Give the kit the app's routes with a description each, and `params` values when there are only a few:
`kit.setRoutes({ current, routes, navigate, back, canGoBack })` (web) or `kit.routes = AffordRoutes(...)` (Flutter). Every screen
the agent should reach needs a route. Add `preview` if the app can build a page off screen, so the agent can peek before going.

### 9. Register app tools

Actions that need no screen (switch a setting, refresh, export): `kit.registerTool({ name, description, inputSchema, policy, execute })`
(web) or `kit.registerTool(AffordTool(name, description, inputSchema:, policy:, execute:))` (Flutter). Snake_case names, a
description that says what it does, a JSON schema with `enum` where values are fixed, a policy by step 4's rules.

### 10. Connect the agent

- **App side:** answer each request with `kit.answer(request)` over the channel the app already has. Tag requests with the id of
  the app instance the user is chatting from. Answer every request, even with an error.
- **Agent side:** `new AffordRemote({ send, timeoutMs })` (TypeScript) or `AffordAgent(send: ...)` (Dart). Give the model
  `ui.tools()` in its stack's shape (`anthropicTools`, `openaiTools`, `openaiResponsesTools`, `mcpHandlers`, `runners`) and run
  its calls with `ui.handle(name, input)` (or `anthropicResult`, `openaiResult`, ...).
- Send `kit.context()` with each user message and call `ui.seen(context)`, so the first act answers with what changed.
- Tell the model, in the app's system prompt, to work the screen the user sees step by step and leave denied actions (Send) to
  the user.
- An agent running in the app itself: `kit.agent()`, no transport.

### 11. Verify

- Print what the model reads for each main screen: `describe(kit.context())` (web, from `affordkit`) or
  `describe(kit.context().toJson())` (Flutter). Check for unnamed or duplicate names, missing keys, secrets, long lists that
  aren't containers, and dangerous actions without `deny` or `confirm`.
- Add tests: render a screen, then assert the expected keys are in `kit.context()` and the policies of everything that sends,
  pays, deletes or changes rights. Run one round-trip: `await kit.execute([{ node: '<key>', op: 'press' }])` and check the result.
- Run the app's existing tests: affording must not change behavior.

## Report to the user

When done, tell the user: which screens are covered, the actions you set to `deny` and `confirm` (and anything you left out),
the keys the agent will use most, the app tools you registered, how the agent is connected, and what you could not cover.
