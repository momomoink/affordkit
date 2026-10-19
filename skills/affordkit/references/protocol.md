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
