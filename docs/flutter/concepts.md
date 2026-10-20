# Concepts

## The tree

AffordKit turns what is on screen into a tree of **nodes**. Each node is a widget you afforded:

```
Route: /message/42 — can go back
[w3 key=thread.star] button "Star" — press
[w4 key=thread.reply] button "Reply" — press
[w7 key=thread.body] text "Message" = "Can we meet on Tuesday at ten?" — read
[w9 key=compose.send] button "Send" — press(deny)
```

The tree is built **by addition**: a widget is in it when you wrap it with `.afford(...)` (or `.affordContainer`,
`.affordItem`). What it is and what it can do come from the widget itself. Every afforded widget that is built is in the tree, on
screen or not, so an unafforded widget is invisible to the agent and an afforded one on a page underneath is still there.

A node has:

- **`id`**: stable while the widget stays built. Calls refer to it.
- **`key`** (optional): a name your app gives it that stays the same across pages and visits (`compose.body`). Calls can use the
  key instead of the id, also for a widget on a page the agent has only peeked at.
- **`role`**: `button`, `link`, `textbox`, `checkbox`, `switch_` (`switch` on the wire), `radio`, `select`, `tab`, `container`,
  `list`, `listitem`, `heading`, `text`, `image`, `dialog`, `region`, `page`, `app`, `other`. Guessed from the widget type when you
  don't say it.
- **`name`**: the name you give it in `.afford(name)`; for a list entry with no name, the first line of its text.
- **`description`** (optional): what it is for, when the name is not enough.
- **`state`** (optional): a short state: `{disabled: true}` (a button with no `onPressed`), `{checked: true}` (switches and
  checkboxes), `{length: 320, focused: true}` (text fields), and whatever your widget says with `state:`.
- **`value`** (optional): what a text, a heading or a part with no afforded widgets in it shows, cut short when long. A text
  field's content is never here (only its `length`): the agent reads it with the `read` op.
- **`ops`**: what can be done to it, each with its policy.

A node sits under the nearest afforded ancestor. Widgets in between (`Padding`, `Row`, `Column`) don't count: if two afforded
buttons share an unafforded `Row`, they are siblings under whatever afforded ancestor that `Row` has (or the root). To keep a group
together (a toolbar, a filter bar), afford the group too, with `role: Role.region`. Siblings are ordered as people read: top to
bottom, then left to right.

## Ops

| Role | Ops |
|---|---|
| `button`, `link` | `press` |
| `textbox` | `read`, `write {text}`, `append {text}`, `clear` |
| `checkbox`, `switch_` | `toggle`, `set {on}` |
| `radio`, `tab` | `select` |
| `select` | `read`, `press` (opens the choices) |
| `listitem` | `read`, `press` (open it) |
| `text`, `list`, `other` | `read` |
| `heading` | none: its words are its `value` |
| `region`, `page`, `dialog` | `read`, `view` (a picture of that part of the screen) |
| `image` | `view` |
| `container` | `read`, `item`, `items`, `scroll_to`, `scroll` |

How they are carried out:

- **press, toggle, set, select**: a real tap in the middle of the widget: a pointer down and up through Flutter's gesture
  system, so ink ripples and gesture recognizers behave as for a finger, and the tap reaches whatever is on top there. When
  something covers the widget (a dialog, another page), the kit calls the widget's own callback instead: `onPressed`, `onTap`,
  `onChanged`.
- **write, append, clear**: the text goes into the field's controller and `onChanged` is called, as typing would. With
  `typeDelay`, it goes in a few characters at a time, so the user sees it typed.
- **view**: a PNG of that part of the screen, taken from the `AffordPreviewHost`.

Your app can add ops to a node, or replace a standard one: a `CustomOp` named `press` replaces the tap.

`onAct` is called before each op that changes something, with the node, the op and where it is on screen (`rect`; `behind`
when the widget can't be seen): show the user where the agent is about to tap, and wait a moment so they see it.

## Policies

Every op has a policy:

- **`Policy.allow`**: the agent may do it.
- **`Policy.confirm`**: the agent may do it after the user says yes. The kit asks through your `confirm` callback; without one,
  the call comes back with `needsConfirm` and nothing is done.
- **`Policy.deny`**: only the user does this. The agent sees the widget (so it can tell the user where it is) but cannot use it.

Set `policy:` for all of a node's ops, or `policies:` per op. Obscured text fields (`obscureText: true`) are found by themselves:
the agent sees them, and all their ops are denied. See [What to expose](what-to-expose.md).

## Containers

A long list, a grid or a thread of messages would flood the tree. A **container** is one node for all of them:

```
[w12 key=mail.list] container "Inbox" (list) 312 entries, showing 0–9 (entry keys: mail.list[<id>]) — read, item, items, scroll_to, scroll
  · [mail.list[42]] #0 "Lunch on Tuesday?" — Wang, 10:02
  · [mail.list[41]] #1 "Invoice for October" — Acme
  · … 310 more; op item fetches an entry's controls, items pages through them
```

Wrap the list with `.affordContainer(...)` and each row with `.affordItem(id)`. The agent fetches the entry it wants with
**`item`** (by `id`, `index`, or `query`) and gets it back as a tree of its own: `mail.list[42].reply`. An entry's key can also be
used straight away, even for a row not built: the kit scrolls to it first. **`items`** pages through all entries;
**`scroll_to`** and **`scroll`** move the list. Containers nest: `thread[a].files[1].open`.

With nothing more, the kit finds entries by itself: it reads the list's builder (`ListView.builder`, `GridView.builder`,
`SliverList`), builds every entry off screen under the `AffordPreviewHost` to read its text and index, and jumps to an entry not
built from the ones that are. When it can't (no host, an endless builder), it scrolls through the list a page at a time. Give the
container `count`, `items`, `indexOf` or `scrollTo` for data not all loaded, a server search, or a faster jump.

## Pages

Tell the kit your app's **routes** (`/mail/:box`, `/settings/:section`) with `AffordRoutes`, and have each page say its route
while it is open. The agent can then:

- see where the user is (`Route: /message/42 — can go back`);
- go to a route, or back (`navigate`);
- **peek** at another page's tree without taking the user there, to plan: built off screen when your `preview` returns its widget,
  or as it last showed. Ids from a peek cannot be acted on; the agent navigates there and then acts by key.

A page covered by another page or by a dialog stays in the tree as a node marked `behind`, with its afforded widgets under it.
They still work, pressed through their callbacks, but the user does not see it happen. The agent is told to go to that page
first when the user is watching.

Keep the trees of pages already seen across runs with `kit.snapshots()` and `kit.loadSnapshots()`.

## App tools

Some things need no screen: changing a setting, refreshing data, starting an export. Register them with
`kit.registerTool(AffordTool(...))`: a name, a description, a JSON schema for the arguments, a policy, and a function. They
appear with the tree, and the agent calls them with `ui_tool`.

## The agent's side

The agent gets five tools: `ui_look` (the screen, optionally with a picture of it), `ui_act` (an op on a node), `ui_tool` (an
app tool), `ui_navigate` (a route, or back) and `ui_peek` (another page). After each act it is told what changed on screen, not
the whole tree again: the route if it changed, and the nodes that came (`+`), went (`-`) or changed (`~`). Failed calls carry a
code (`not_found`, `denied`, `needs_confirm`, ...). See [Connecting an agent](connecting-an-agent.md).

## Handoffs

When the user has left the app (it is in the background, drawing no frames), its screen can't be worked: the screen tools answer
`away`. The agent does what it can with your backend's tools, and may leave a **handoff** (`ui_handoff`): a short message, and
calls by key that take the user to what it did. Your app tells the user (a notification), and runs it when they come back
(`kit.runHandoff`), under the same policies. See [Handoffs](handoffs.md).
