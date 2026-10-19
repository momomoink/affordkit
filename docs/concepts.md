# Concepts

## The tree

AffordKit turns what is on screen into a tree of **nodes**. Each node is a control or a meaningful part of the page:

```
Route: /message/42 — can go back
[w3 key=thread.star] button "Star" — press
[w4 key=thread.reply] button "Reply" — press
[w7 key=thread.body] text "Message" = "Can we meet on Tuesday at ten?" — read
[w9 key=compose.send] button "Send" — press(deny)
```

A node has:

- **`id`**: stable while the control stays on screen. Calls refer to it.
- **`key`** (optional): a name your app gives it that stays the same across pages and visits (`compose.body`). Calls can use the
  key instead of the id, also for a control on a page the agent has only peeked at.
- **`role`**: what it is: `button`, `link`, `textbox`, `checkbox`, `switch`, `radio`, `select`, `tab`, `container`, `list`,
  `listitem`, `heading`, `text`, `image`, `dialog`, `region`, `page`, `app`, `other`.
- **`name`**: what the user sees it called.
- **`description`** (optional): what it is for, when the name is not enough.
- **`state`** (optional): a short state, such as `{checked: true}`, `{disabled: true}`, `{length: 320}`, `{selected: true}`.
- **`value`** (optional): what a text, a heading or a part with no controls in it shows, cut short when long. A text field's
  content is never here (only its `length`): the agent reads it with the `read` op.
- **`ops`**: what can be done to it, each with its policy.

The two runtimes build the tree differently:

- **Web (DOM)**: by subtraction. Buttons, links, fields, choices, tabs, dialogs, lists and headings are found by themselves;
  layout and decoration are passed through. You add names, keys, policies and ops where the defaults are not enough.
- **Flutter**: by addition. A widget is in the tree when you wrap it with `.afford(...)`. Every afforded widget that is built
  is in the tree, on screen or not.

A node sits under the nearest node above it in the tree. Layout in between does not count. If two afforded buttons share an
unafforded `Row`, they are siblings under whatever afforded ancestor that `Row` has (or the root). To keep a group together
(a toolbar, a filter bar), afford the group too, with role `region`.

Siblings are ordered as people read: top to bottom, then left to right.

## Ops

Each role has standard ops:

| Role | Ops |
|---|---|
| `button`, `link` | `press` |
| `textbox` | `read`, `write {text}`, `append {text}`, `clear` |
| `checkbox`, `switch` | `toggle`, `set {on}` |
| `radio`, `tab` | `select` |
| `select` | `read`, `choose {option}` (web), `press` (Flutter: opens the choices) |
| `text`, `listitem`, `region`, `page`, `dialog`, `app` | `read` (all the text in it) |
| `image` | `view` (the picture itself) |
| `container` | `read`, `item`, `items`, `scroll_to`, `scroll` |

In Flutter, `page`, `region` and `dialog` also have `view`: a picture of that part of the screen.

How a standard op is carried out:

- **press, toggle, set, select**: a real tap in the middle of the control (Flutter: a pointer down and up through the gesture
  system; web: `click()`). The tap reaches whatever is on top there, as a finger would. When something covers the control (a
  dialog, another page), the kit calls the control's own callback instead (`onPressed`, `onTap`, `onChanged`).
- **write, append, clear**: the text is put into the field the way typing would: its controller (Flutter) or value (web) changes
  and the change events fire. With `typeDelay` (Flutter) it goes in a few characters at a time.
- **read**: the text of the control and everything in it.

Your app can add its own ops to a node, or replace a standard one (an op of your own named `press` replaces the tap). See the
getting-started guides.

## Policies

Every op has a policy:

- **`allow`**: the agent may do it.
- **`confirm`**: the agent may do it after the user says yes. The kit asks through your `confirm` callback; without one, the call
  comes back with `needsConfirm` and nothing is done.
- **`deny`**: only the user does this. The agent sees the control (so it can tell the user where it is) but cannot use it.

Set a policy for all of a node's ops, or per op. Password fields are found by themselves and all their ops are denied. See
[What to expose](what-to-expose.md) for which policy fits what.

## Containers

A long list, a grid or a thread of messages would flood the tree. A **container** is one node for all of them:

```
[w12 key=mail.list] container "Inbox" (list) 312 entries, showing 0–9 (entry keys: mail.list[<id>]) — read, item, items, scroll_to, scroll
  · [mail.list[42]] #0 "Lunch on Tuesday?" — Wang, 10:02
  · [mail.list[41]] #1 "Invoice for October" — Acme
  · … 310 more; op item fetches an entry's controls, items pages through them
```

The agent fetches the entry it wants with **`item`** (by `id`, `index`, or `query`) and gets it back as a tree of its own, with
ids and keys it can act on: `mail.list[42].reply`. An entry's key can also be used straight away, even for an entry not on
screen: the kit fetches it (scrolls to it) first. **`items`** pages through all entries (`offset`, `limit`, `query`).
**`scroll_to`** and **`scroll`** move the container.

Containers nest: `thread[a].files[1].open`.

Your app can tell the container about entries it has not built (a virtualized list, data not loaded yet, a server search). With
nothing more, the kit finds entries by itself: it searches all of an entry's text, and when the list holds fewer entries than
asked for, it scrolls through it a page at a time. In Flutter it can also build every entry of a list builder off screen to read
them.

## Pages

Tell the kit your app's **routes** (`/mail/:box`, `/settings/:section`) and the agent can:

- see where the user is (`Route: /message/42 — can go back`);
- go to a route, or back (`navigate`);
- **peek** at another page's tree without taking the user there, to plan: built off screen when your app can build it, or as it
  last showed. Ids from a peek cannot be acted on; the agent navigates there and then acts by key.

When a page is covered by another one or by a dialog (Flutter), its controls stay in the tree under a node marked `behind`.
They still work, pressed through their callbacks, but the user does not see it happen. The agent is told to go to that page
first when the user is watching.

## App tools

Some things need no screen at all: changing a setting, refreshing data, starting an export. Register them as **tools**: a name,
a description, a JSON schema for the arguments, a policy, and a function. They appear with the tree, and the agent calls them
with `ui_tool`.

## The agent's side

The agent gets five tools: `ui_look` (the screen, optionally with a picture), `ui_act` (an op on a node), `ui_tool` (an app tool),
`ui_navigate` (a route, or back) and `ui_peek` (another page). After each act it is told what changed on screen, not the whole tree
again: the route if it changed, and the nodes that came (`+`), went (`-`) or changed (`~`). Failed calls carry a code
(`not_found`, `denied`, `needs_confirm`, ...). See [Connecting an agent](connecting-an-agent.md).
