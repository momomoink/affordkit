<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/affordkit-dark.svg">
    <img src="brand/affordkit.svg" alt="AffordKit" width="160">
  </picture>
</p>

<h1 align="center">AffordKit</h1>

<p align="center">Your app's UI, for AI agents to see and use.</p>

AffordKit is a frontend library: it lets an AI agent on your backend use your app's UI the way a person would. Open that mail,
press Reply, type the answer; the user watches it happen, on their own screen.

> [!TIP]
> **Already have an app? Add AffordKit with ease.** Install the skill in your coding agent and ask it to "add AffordKit to this
> app": it does the whole job, and asks you what the agent may do. [How →](docs/adapt-your-app.md)
>
> ```text
> /plugin install affordkit --marketplace momomoink/affordkit
> ```

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/concept-dark.svg">
    <img src="brand/concept.svg" alt="Your app's screen goes to AffordKit, which gives the agent a small tree of its controls (the AffordTree); the agent answers with calls (press, type, go to a page), which your app runs under your rules (allow, confirm, deny)." width="860">
  </picture>
</p>

## Why

- **Not pixels.** The agent doesn't read screenshots and guess where to click. It gets the screen as a few lines of text, each
  control with what it is, what it shows and what can be done to it; fast, cheap, and it doesn't miss.
- **Not a second API.** What the agent does goes through the same buttons, fields and pages the user has, with the same checks.
  There is nothing extra to build and keep in step.
- **The user stays in charge.** You decide what it may just do, what needs the user's yes first, and what is theirs alone (send,
  pay). They see each step, can stop it, and can keep using the app meanwhile: the agent is told what they did.

## How it works

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/how-it-works-dark.svg">
    <img src="brand/how-it-works.svg" alt="What AffordKit gives you, and what is yours. In your app, AffordKit builds the AffordTree from your UI (kit.context()) and answers requests with kit.answer(request), running each call under your rules (allow, confirm, deny) with routes, settle, watchUser and onAct. On your server, AffordRemote gives your agent (your model, loop and prompt, or an agent like Claude Code) the screen as tools (ui_look, ui_act, ui_navigate, ui_peek, ui_tool, ui_handoff) for the Anthropic and OpenAI APIs or MCP, and sends requests with send(request). Over your own channel, UiRequest (look, or calls) goes to the app and UiAnswer (the tree after, results, what the user did) comes back. Packages: affordkit for Flutter, affordkit/dom for the web, affordkit for Node." width="900">
  </picture>
</p>

AffordKit is the two solid parts. In the app, the **kit** builds the AffordTree from your UI and runs what the agent asks. On your
server, **`AffordRemote`** turns the screen into tools for your agent, in the shape its API takes. The agent itself is yours (your
model, loop and prompt, or an agent like Claude Code), and so is the channel between app and server; AffordKit doesn't run or
host either. That channel carries two messages: a `UiRequest` (look, or calls) and a `UiAnswer` (the tree after, the results, and
what the user did meanwhile). One round:

**1. The screen becomes an AffordTree.** Only the controls that mean something, never their content until it is read:

```
Route: /message/42 — can go back
[w4 key=thread.reply] button "Reply" — press
[w7 key=thread.body] text "Message" — read
[w9 key=compose.send] button "Send" — press(deny)
```

**2. The agent answers with calls:** press, type, scroll, go to a page, or a tool of your app's.

**3. Your app runs them under your rules,** and the agent gets back what changed, not the whole tree again:

```
Done.

The screen changed:
Now at /reply/42 (was /message/42) — can go back.
+ [w12 key=compose.body] textbox "Body" — read, write, append, clear
+ [w13 key=compose.send] button "Send" — press(deny)
```

It goes on like that, step by step, until the goal is done.

## A taste

Most controls are found by themselves. Name the ones that matter, and say what the agent may do:

```dart
// Flutter
ElevatedButton(onPressed: send, child: const Text('Send'))
    .afford('Send', key: 'compose.send', policy: Policy.deny);
```

```html
<!-- Web, any framework -->
<button data-afford-key="compose.send" data-afford-policy="deny">Send</button>
```

The app answers the agent's requests over the channel it already has; where the model runs, `AffordRemote` turns them into its
tools:

```ts
import { AffordRemote, anthropicTools, anthropicResult } from 'affordkit';

const ui = new AffordRemote({ send: (request) => askTheApp(request) }); // the app: kit.answer(request)
const res = await client.messages.create({ model, max_tokens, messages, tools: anthropicTools(ui.tools()) });
```

OpenAI, MCP and other loops are covered too.

## What it takes care of

- **Long lists:** one node with a preview; the agent searches, fetches and scrolls to the entry it wants.
- **Pages:** the agent knows where the user is, can go to a page, or look at one before going.
- **Your rules:** `allow`, `confirm` (the user says yes first), `deny` (the user's own act). Passwords are never read.
- **Waiting for the screen:** each step answers once what it set off (a search, a page loading) has shown; your app says when.
- **The user's own hands:** what they do while the agent works goes to it, with the screen as it is after.
- **The user leaving:** the agent finishes another way and leaves a handoff, a way back to what it did.

## Pick your platform

- **Flutter**: [`flutter/README.md`](flutter/README.md) (`flutter pub add affordkit`)
- **JavaScript / TypeScript**, for any web framework and for the agent's side on a server:
  [`js/README.md`](js/README.md) (`npm install affordkit`)

A Flutter app with its model on a TypeScript server uses both: the Flutter package in the app, the npm package on the server.
They speak the same JSON.

## Let your coding agent add it

[`skills/affordkit`](skills/affordkit/SKILL.md) is an agent skill for adding AffordKit to an app you already have, or making one
thing in it doable by its agent ("let the assistant reply to mail"): from installing it and putting the controls into the tree
to deciding what the agent may do and connecting it. How to install it in Claude Code, claude.ai or another agent, and what it
does: [Add AffordKit to the app you already have](docs/adapt-your-app.md).

## Docs

[`docs/`](docs/README.md): a set per platform ([`docs/flutter`](docs/flutter/README.md), [`docs/js`](docs/js/README.md)), each with concepts, getting started, what to expose to the agent, connecting an agent and
handoffs (for when the user has left the app); and the [protocol](docs/protocol.md).

## Contributing

- `js/`: `npm install`, `npm test`, `npm run typecheck`, `npm run build`.
- `flutter/`: `flutter test`, `flutter analyze`.
- Keep `js/src/protocol.ts` and `flutter/lib/src/protocol.dart` in step.
- After changing `docs/`, run `node scripts/sync-skill.mjs`: the skill's references are copies of the docs.

The logo and the picture above are in [`brand/`](brand): `affordkit.svg` and `concept.svg` for light grounds, the `-dark` ones for
dark grounds. MIT license.
