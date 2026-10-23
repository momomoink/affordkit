# Concepts

## The tree

AffordKit turns the page into a tree of **nodes**. Each node is a control or a meaningful part of the page:

```
Route: /message/42 — can go back
[n3 key=thread.star] button "Star" — press
[n4 key=thread.reply] button "Reply" — press
[n6] heading "Lunch on Tuesday?"
[n7 key=thread.body] region "Message" = "Can we meet on Tuesday at ten?" — read
[n9 key=compose.send] button "Send" — press(deny)
```

The tree is built **by subtraction**: buttons, links, fields, checkboxes, switches, radios, selects, tabs, dialogs, lists and
headings (native elements and their ARIA roles) are found by themselves; layout and decoration are passed through; hidden
elements are left out. You add names, keys, policies and operations where the defaults are not enough, with `data-afford-*`
attributes or `kit.register`.

A node has:

- **`id`**: stable while the element stays in the page. Calls refer to it.
- **`key`** (optional): a name your app gives it that stays the same across pages and visits (`compose.body`). Calls can use the
  key instead of the id, also for a control on a page the agent has only peeked at.
- **`role`**: `button`, `link`, `textbox`, `checkbox`, `switch`, `radio`, `select`, `tab`, `container`, `list`, `listitem`,
  `heading`, `text`, `image`, `dialog`, `region`, `page`, `app`, `other`.
- **`name`**: what the user sees it called: its label, text, `aria-label` or placeholder, or the name you give it.
- **`description`** (optional): what it is for, when the name is not enough.
- **`state`** (optional): a short state: `{checked: true}`, `{disabled: true}`, `{focused: true}`, `{length: 320}`,
  `{selected: true}`, `{expanded: false}`, `{value: "5 min"}` for a select.
- **`value`** (optional): what a heading, a text or a part with no controls in it shows, cut short when long. A field's content
  is never here (only its `length`): the agent reads it with the `read` op.
- **`ops`**: what can be done to it, each with its policy.

Nodes nest as the page does, without the layout in between. Siblings are in reading order.

## Ops

| Role | Ops |
|---|---|
| `button`, `link` | `press` |
| `textbox` | `read`, `write {text}`, `append {text}`, `clear` |
| `checkbox`, `switch` | `toggle`, `set {on}` |
| `radio`, `tab` | `select` |
| `select` | `read` (the choice and the options), `choose {option}` |
| `listitem` | `read`, `press` (open it) |
| `text`, `list`, `region`, `dialog`, `page`, `app`, `other` | `read` (all the text in it) |
| `heading` | none: its words are its `value` |
| `image` | `view` (the picture itself: an `img` or a `canvas`) |
| `container` | `read`, `item`, `items`, `scroll_to`, `scroll` |

How they are carried out:

- **press, toggle, set, select**: `click()` on the element, so your click handlers run as for a user's click.
- **write, append, clear**: the field's value is set the way typing would, and `input` and `change` fire, so controlled inputs
  (React, Vue) see it.
- **choose**: the option is selected and `input` / `change` fire.
- **view**: the image drawn into a canvas and returned as a PNG; an image from another site that can't be read comes back as its
  address.

After the calls, the kit waits for the page to render what they changed (a frame or two, or your `settle`) before it answers.

Your app can add ops to a node, or replace a standard one: an op of your own named `press` replaces the click.

## Policies

Every op has a policy:

- **`allow`**: the agent may do it.
- **`confirm`**: the agent may do it after the user says yes. The kit asks through your `confirm` option; without one, the call
  comes back with `needsConfirm` and nothing is done.
- **`deny`**: only the user does this. The agent sees the control (so it can tell the user where it is) but cannot use it.

Set a policy for all of a node's ops, or per op (`data-afford-policy="press:deny, write:confirm"`). Password fields, and fields
named like secrets, tokens, API keys or one-time codes, are found by themselves: the agent sees they exist and whether they are
filled, and all their ops are denied. See [What to expose](what-to-expose.md).

## Containers

A long list, a grid or a thread of messages would flood the tree. A **container** is one node for all of them:

```
[n12 key=mail.list] container "Inbox" (list) 312 entries, showing 0–9 (entry keys: mail.list[<id>]) — read, item, items, scroll_to, scroll
  · [mail.list[42]] #0 "Lunch on Tuesday?" — Wang, 10:02
  · [mail.list[41]] #1 "Invoice for October" — Acme
  · … 310 more; op item fetches an entry's controls, items pages through them
```

The agent fetches the entry it wants with **`item`** (by `id`, `index`, or `query`) and gets it back as a tree of its own, with
ids and keys it can act on: `mail.list[42].reply`. An entry's key can also be used straight away, even for an entry not rendered:
the kit brings it in first. **`items`** pages through all entries (`offset`, `limit`, `query`). **`scroll_to`** and **`scroll`**
move the container. Containers nest: `thread[a].files[1].open`.

A `<ul>` or `<ol>` with more than 20 items is a container by itself; mark others with `data-afford-container`, or register them.
With nothing more, the kit finds entries by itself: it searches all of an entry's text, and when the list holds fewer entries than
asked for (a virtualized list renders only what shows), it scrolls through it a page at a time. Give the container `count`,
`items` and `scrollTo` for data not all loaded, or a server search.

## Pages

Tell the kit your app's **routes** (`/mail/:box`, `/settings/:section`) and the agent can:

- see where the user is (`Route: /message/42 — can go back`);
- go to a route, or back (`navigate`);
- **peek** at another page's tree without taking the user there, to plan: built off screen when your app gives a `preview`, or as
  it last showed. Ids from a peek cannot be acted on; the agent navigates there and then acts by key.

Keep the trees of pages already seen across reloads with `kit.snapshots()` and `kit.loadSnapshots()`.

## The user's own hands

The user can still use the page while the agent works it. Turn on `kit.watchUser(true)` while your agent is working (off when it is
done: that also forgets what was noted) and the kit notes what the user does themselves on the tree's nodes — `press`, `write` (one
entry per field per burst of typing, the text cut to 80 characters, never a password's), `toggle` (`on`/`off`), `select` (what they
picked) — and `navigate` / `back` when the route changes without the kit doing it. Never the kit's own calls: while it runs them,
and for 300 ms after, only events the browser marks as a person's (`isTrusted`) count. Nothing in what the tree leaves out (`skip`:
your agent's chat) is noted.

`kit.answer()` hands what was noted to the agent (`userActions`, oldest first, at most the latest 30) with the tree as it is after
it, and starts afresh. `onUserAction` (an option) is called as each is noted, if your app wants to react itself.

## App tools

Some things need no screen: changing a setting, refreshing data, starting an export. Register them as **tools**: a name, a
description, a JSON schema for the arguments, a policy, and a function. They appear with the tree, and the agent calls them with
`ui_tool`.

## The agent's side

The agent gets five tools: `ui_look` (the page, optionally with a picture where the app can take one), `ui_act` (an op on a
node), `ui_tool` (an app tool), `ui_navigate` (a route, or back) and `ui_peek` (another page). After each act it is told what
changed, not the whole tree again: the route if it changed, and the nodes that came (`+`), went (`-`) or changed (`~`). Failed
calls carry a code (`not_found`, `denied`, `needs_confirm`, ...). See [Connecting an agent](connecting-an-agent.md).

## Handoffs

When the user has left the app, its screen can't be worked: the screen tools answer `away`. The agent does what it can with your
backend's tools, and may leave a **handoff** (`ui_handoff`): a short message, and calls by key that take the user to what it did.
Your app tells the user (a notification), and runs it when they come back (`kit.runHandoff`), under the same policies. See
[Handoffs](handoffs.md).
