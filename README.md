<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/affordkit-dark.svg">
    <img src="brand/affordkit.svg" alt="AffordKit" width="160">
  </picture>
</p>

<h1 align="center">AffordKit</h1>

<p align="center">Your app's UI, for AI agents to see and use.</p>

The controls on screen become a small tree: what each is, what it's called, what it shows, a short state, and the operations
you'd expect of it (a button is pressed, a field read and written, an entry of a long list fetched). The agent answers with calls
that the app runs under its own policies (`allow`, `confirm`, `deny`), and gets back what they changed on screen.

| Package | For | Folder |
|---|---|---|
| `affordkit` (npm) | TypeScript / JavaScript: the DOM runtime, and the agent's side for any stack | [`js/`](js/README.md) |
| `affordkit` (pub) | Flutter | [`flutter/`](flutter/README.md) |

Both speak the same JSON protocol (`js/src/protocol.ts`, `flutter/lib/src/protocol.dart`: keep the two in step), so an agent
written against one works the other.

- **The tree:** controls in reading order, under the nearest afforded parent; pages under the one on top as nodes of their own.
- **Containers:** a long list is one node with a preview; an entry is fetched as a tree of its own, searched, scrolled to.
- **Routes and app tools:** go to a page, peek at one without going, or run something the app can do without its screen.
- **The agent's side:** `AffordRemote` (TS) / `AffordAgent` (Dart) over any transport, answers as text, error codes, and the
  shapes of the Anthropic, OpenAI and MCP stacks.

The logo is in [`brand/`](brand): `affordkit.svg` for light grounds, `affordkit-dark.svg` for dark ones.
