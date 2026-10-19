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

## Install

```sh
npm install affordkit       # web: the DOM runtime (affordkit/dom) and the agent's side (affordkit)
flutter pub add affordkit   # Flutter
```

Then follow [Getting started: web](docs/getting-started-web.md) or [Getting started: Flutter](docs/getting-started-flutter.md).
Everything else is in [the docs](docs/README.md).

## Let your coding agent add it

[`skills/affordkit`](skills/affordkit/SKILL.md) is an agent skill: it walks a coding agent through adding AffordKit to an
existing project, from installing it and putting the controls into the tree to deciding what the agent may do and connecting it
to an agent backend. Install it, then ask your agent to "add AffordKit to this app".

**Claude Code**, as a plugin from this repository:

```text
/plugin install affordkit --marketplace momomoink/affordkit
```

On Claude Code before 2.1.275, add the marketplace first:

```text
/plugin marketplace add momomoink/affordkit
/plugin install affordkit@affordkit
```

The skill is then `/affordkit:affordkit`, and Claude also uses it by itself when you ask for AffordKit.

**Claude Code, without the plugin:** copy `skills/affordkit/` to `~/.claude/skills/affordkit/` (all your projects) or to
`.claude/skills/affordkit/` in one project.

**claude.ai:** zip the `skills/affordkit/` folder and upload it in Settings (Features / Capabilities, under Skills). This needs a
plan with code execution enabled.

**Other agents:** the skill follows the open [Agent Skills](https://agentskills.io) format. Copy the folder to wherever your agent
loads skills from; see its own documentation for the path.

## Brand

The logo is in [`brand/`](brand): `affordkit.svg` for light grounds, `affordkit-dark.svg` for dark ones.

## Contributing

- `js/`: `npm install`, `npm test`, `npm run typecheck`, `npm run build`.
- `flutter/`: `flutter test`, `flutter analyze`.
- Keep `js/src/protocol.ts` and `flutter/lib/src/protocol.dart` in step.
- After changing `docs/`, run `node scripts/sync-skill.mjs`: the skill's references are copies of the docs.
