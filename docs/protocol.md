# Protocol

Both runtimes speak this JSON (protocol version `1`). The TypeScript types are in [`js/src/protocol.ts`](https://github.com/momomoink/affordkit/blob/main/js/src/protocol.ts),
the Dart ones in [`flutter/lib/src/protocol.dart`](https://github.com/momomoink/affordkit/blob/main/flutter/lib/src/protocol.dart).

## Context

What `kit.context()` returns, and what goes to the agent:

```json
{
  "protocol": 1,
  "route": {
    "current": "/message/42",
    "pattern": "/message/:id",
    "params": { "id": "42" },
    "canGoBack": true,
    "routes": [{ "path": "/message/:id", "description": "One mail" }]
  },
  "tools": [{ "name": "set_theme", "description": "…", "inputSchema": { "type": "object", "properties": {} }, "policy": "allow" }],
  "root": {
    "id": "app",
    "role": "app",
    "name": "",
    "ops": [{ "name": "read", "policy": "allow" }],
    "children": [
      { "id": "w4", "key": "thread.reply", "role": "button", "name": "Reply", "ops": [{ "name": "press", "policy": "allow" }] },
      {
        "id": "w12", "key": "mail.list", "role": "container", "name": "Inbox",
        "state": { "kind": "list", "count": 312, "first": 0, "last": 9 },
        "ops": [{ "name": "item", "policy": "allow" }, { "name": "items", "policy": "allow" }],
        "preview": [{ "key": "mail.list[42]", "id": "42", "index": 0, "name": "Lunch on Tuesday?" }]
      }
    ]
  }
}
```

A node: `id`, `key?`, `role`, `name`, `description?`, `state?` (string, number or boolean values), `value?`, `ops`
(`{ name, description?, params?, policy }`, `params` a JSON schema), `children?`, `preview?` (containers).

A page under the one on top is a node with `"state": { "behind": true }` and the page's controls as its children.

## Calls

```json
{ "node": "w4", "op": "press" }
{ "node": "compose.body", "op": "write", "args": { "text": "Tuesday works." } }
{ "node": "mail.list", "op": "item", "args": { "query": "invoice" } }
{ "tool": "set_theme", "args": { "theme": "dark" } }
{ "navigate": "/settings/notifications" }
{ "navigate": "back" }
{ "peek": "/settings/notifications" }
```

`node` is an id or a key. An entry's key is its container's key and the entry id: `mail.list[42]`; controls inside it continue
with a dot: `mail.list[42].reply`.

## Results

```json
{ "call": { "node": "w4", "op": "press" }, "ok": true }
{ "call": { "node": "w9", "op": "press" }, "ok": false, "code": "denied", "error": "Not allowed: the user does this themselves" }
{ "call": { "node": "mail.list", "op": "item", "args": { "id": "42" } }, "ok": true,
  "value": { "key": "mail.list[42]", "id": "42", "index": 0, "source": "live", "root": { "…": "the entry's tree" } } }
```

`value` is what a read returned, what a tool answered, an entry's tree (`item`), a page of entries (`items`:
`{ count?, offset, items }`), a peeked page (`{ route, source, root?, … }`, `source` one of `live`, `preview`, `seen`, `declared`), or
a picture (`{ "type": "image", "mime": "image/png", "data": "<base64>", "width": 240, "height": 180 }`).

## Requests and answers

```json
{ "look": true, "picture": true }
{ "calls": [{ "node": "thread.reply", "op": "press" }] }
```

```json
{ "context": { "…": "…" }, "results": [{ "…": "…" }], "picture": { "type": "image", "mime": "image/png", "data": "…" } }
{ "error": "…", "code": "failed" }
```

### What the user did meanwhile

While the agent works the screen the user can still use it. With `kit.watchUser(true)` (an app turns it on while its agent is
working, off when it is done) the kit notes what they do themselves — never its own calls — and the next answer carries it, oldest
first, with the AffordTree (the context's root) as it is after it:

```json
{
  "context": { "…": "…" },
  "results": [{ "…": "…" }],
  "userActions": [
    { "at": 1792711772948, "op": "press", "node": { "id": "w9", "key": "mail.list[42]", "role": "listitem", "name": "Lunch on Tuesday?" }, "route": "/message/42" },
    { "at": 1792711775001, "op": "write", "node": { "id": "w31", "key": "compose.subject", "role": "textbox", "name": "Subject" }, "value": "Re: lunch" }
  ]
}
```

`op` is named as the agent would call it: `press`, `write`, `toggle`, `select`, `scroll` on a node; `navigate` (with `route`) or
`back`. `value` is cut short and never a password field's. `AffordRemote` puts it at the top of the tool's answer, so the agent
sees the screen moved and why.

## Error codes

`not_found`, `no_op`, `bad_args`, `denied`, `needs_confirm`, `declined`, `disabled`, `unreachable`, `timeout`, `unavailable`,
`away` (the user is not in the app now: its screen can't be worked), `expired` (a handoff past its `expiresAt`), `failed`.

## Handoffs

What an agent leaves for a user who is away, run by the app when they come back
([Flutter](flutter/handoffs.md), [JavaScript](js/handoffs.md)):

```json
{
  "v": 1,
  "message": "回复写好了，在草稿箱",
  "route": "/drafts",
  "calls": [{ "key": "draft.d81", "op": "press" }],
  "expiresAt": 1792540800000,
  "id": "h_5f2c"
}
```

`message` (at most 500 characters) is for the user. `route` (optional) is gone to first. `calls` (at most 20) run after it, in
order: `{ key, op, args? }`, each addressing a control by its key, never by an id from a look (`n12`, `w4`, `peek:…` are
refused); `node` is taken for `key`. `expiresAt` is ms since the epoch; `id` is the host's.
