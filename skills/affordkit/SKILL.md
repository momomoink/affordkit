---
name: affordkit
description: Add AffordKit to an existing web (DOM, React, Vue, Svelte) or Flutter app so an AI agent can see and operate its UI, and connect the app to an agent backend; or make one feature of an app doable by its agent (e.g. "let the assistant open and reply to mail"). Use when the user wants to make an app agent-operable, add or install AffordKit, adapt an app to AffordKit, let an assistant do something on screen, tag or mark UI controls for an agent, decide what an AI assistant may do in the app, expose a custom widget or a function to an agent, or hook an agent (Anthropic, OpenAI, MCP or a custom loop) up to the app's screen.
license: MIT
---

# Adding AffordKit to an app

AffordKit is a frontend library: it turns an app's screen into a tree of controls an agent can read (the AffordTree), and runs
the agent's calls (press, type, scroll, navigate, app tools) under the app's own policies: `allow`, `confirm` (the user says yes
first) or `deny` (the user's own act). Its agent side (`AffordRemote`, in the npm package) gives a model on a backend the screen
as tools. Your job is to put the app's controls into the tree with the right names, keys and policies, and connect it to the
agent, without changing what the app does for its users.

There are two jobs. Work out which one the user asked for:

- **Adapt a whole app** ("add AffordKit", "make the app agent-operable"): the [workflow](#workflow) below, all of it.
- **Make one thing doable** ("let the assistant reply to mail", "it should be able to change the theme"), in an app that may or
  may not have AffordKit yet: [one goal](#one-goal) first; it sends you into the workflow only for the steps that goal needs.

The references come in one set per platform. Find the platform in step 1, then read only that set, as you need it:

| | Flutter | Web (JavaScript / TypeScript) |
|---|---|---|
| The tree, ops, policies, containers, pages, app tools | [flutter/concepts.md](references/flutter/concepts.md) | [js/concepts.md](references/js/concepts.md) |
| Install, set up, afford or name controls, containers, routes, tools | [flutter/getting-started.md](references/flutter/getting-started.md) | [js/getting-started.md](references/js/getting-started.md) |
| Which policy fits what (read before step 4) | [flutter/what-to-expose.md](references/flutter/what-to-expose.md) | [js/what-to-expose.md](references/js/what-to-expose.md) |
| Transports, the agent's side, answers, error codes, model APIs | [flutter/connecting-an-agent.md](references/flutter/connecting-an-agent.md) | [js/connecting-an-agent.md](references/js/connecting-an-agent.md) |
| When the user has left the app: `away`, `ui_handoff`, notifications, `runHandoff` | [flutter/handoffs.md](references/flutter/handoffs.md) | [js/handoffs.md](references/js/handoffs.md) |

An agent backend in TypeScript (a Node server) uses [js/connecting-an-agent.md](references/js/connecting-an-agent.md) whatever
the app is written in. [protocol.md](references/protocol.md) is the JSON both speak, for a custom agent side.

## One goal

When the user wants the agent to be able to do one thing, work from that goal, not from the whole app:

```
- [ ] 1. Write the goal as the user would say it, and what done looks like on screen
- [ ] 2. Walk the path by hand: every screen and control a person touches, and where it can go another way
- [ ] 3. Cover each step (AffordKit not in the app yet: workflow steps 1-3 first, then 10 at the end)
- [ ] 4. Decide the policy of each step; the last irreversible one (send, pay, delete) is usually the user's
- [ ] 5. Run the goal with the real model, several ways of saying it, and fix what it trips on
```

1. **The goal.** "Reply to Wang's mail about the meeting saying I'll be there": done is the reply page open, the text in the
   body, Send left to the user. Write down 3 or 4 ways a user might ask, including vague ones ("answer him").
2. **The path.** Do it in the app yourself and list what you touch: search or the list, the entry, Reply, the body. Note what
   can block the way: the item not among those loaded, a dialog in front, a page still loading, a picker that needs a value
   typed into it. The agent needs a way past each of them.
3. **Cover each step.** For every control on the path, check it is in the tree with a name the model will understand and a key:
   print the tree on that screen (step 11). What is usually missing:
   - the search field and its submit, the "load more" button, the list as a container with `items` that searches the server;
   - a route for the page the goal ends on (`/message/:id`), so the agent can go straight there by id, loaded or not;
   - a custom op where a tap isn't the action (a recipient field that only takes a chip on Enter: an op that sets the
     recipients; a mail body in an iframe the kit can't see into: a `read` op that returns its text);
   - an app tool when the goal has no screen path at all.
4. **Policies,** by [step 4](#4-inventory-actions-and-decide-policies)'s rules. Ask the user about anything that sends, pays,
   deletes or changes who can see something.
5. **Try it for real.** Send each way of asking through the actual agent and read its steps: what it looked at, what failed and
   why. A model going in circles on a step almost always means something on the path is unnamed, missing, or answers before the
   screen has settled (step 10). Fix the app, not the prompt, when you can. Then tell the user what now works, how they ask for
   it, and what is left to them.

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
- **Let the screen settle.** Give the kit a `settle` (web: the `AffordKit` option; Flutter: `AffordKit.settle`, and
  `AffordRoutes.settle` for navigation) that resolves once what a step set off has loaded: the list after a search, a page, a
  mail being fetched. Wait on the app's own loading state, bounded (10-15 s). Without it the agent sees a spinner, decides
  nothing happened and repeats itself.
- **Turn on `kit.watchUser(true)` while the agent works** (off when its turn ends). What the user does themselves meanwhile goes
  to the agent with its next answer (`userActions`, put at the top of the tool's answer by `AffordRemote`), with the screen as
  it is after, so it works with their change instead of undoing it.
- **Tell the model to work towards a goal,** in the app's system prompt: say what done looks like, take one step, check the
  screen that comes back ("Now at …"), try another way when a step fails (a route, a search, the list) rather than the same step
  again, and stop only when the goal shows or several ways have failed, then say plainly which. Leave denied actions (Send) to
  the user. Give its screen steps a budget (about 25) and stop it after a few failures in a row. Pass a failed step on as a
  failed tool call (`isError`), not as plain text.
- **Show the user it is working.** `onAct` shows where it is about to press or type (a ring for a moment). While waiting for its
  reply, a thin progress bar at the top with what it is on and a Stop does more than a spinner in the chat. Treat the chat as
  one instruction at a time: once sent, put it out of the way, bring it back with the reply, and don't take another message, or
  open the chat, until then; the server should refuse a second one too.
- An agent running in the app itself: `kit.agent()`, no transport.
- **When the user leaves the app** (a phone app in the background, a hidden tab): pass `present` so the screen tools answer
  `away` at once. If the app sends push notifications, also pass `onHandoff` so the agent can leave a handoff (`ui_handoff`):
  store it on the server, push only its id, and on tap fetch it over the app's authenticated API and run
  `kit.runHandoff(handoff)`. Never run one taken from the notification payload or a deep link. See the handoffs reference.

### 11. Verify

- Print what the model reads for each main screen: `describe(kit.context())` (web, from `affordkit`) or
  `describe(kit.context().toJson())` (Flutter). Check for unnamed or duplicate names, missing keys, secrets, long lists that
  aren't containers, and dangerous actions without `deny` or `confirm`.
- Add tests: render a screen, then assert the expected keys are in `kit.context()` and the policies of everything that sends,
  pays, deletes or changes rights. Run one round-trip: `await kit.execute([{ node: '<key>', op: 'press' }])` and check the result.
- Run the app's existing tests: affording must not change behavior.
- Check the screens where things open over others: a dialog, a sheet or a menu must be in the tree while it shows (the page
  under a modal is not what the agent should act on). Something drawn in an iframe or a canvas is not seen into: give its
  container an op that reads or does what is needed.
- Run a real goal end to end with the actual model (see [one goal](#one-goal), step 5).

## Report to the user

When done, tell the user: which screens are covered, the actions you set to `deny` and `confirm` (and anything you left out),
the keys the agent will use most, the app tools you registered, how the agent is connected, and what you could not cover.
