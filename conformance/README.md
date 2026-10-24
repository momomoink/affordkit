# Conformance

`remote.json` is what the agent side (`AffordRemote` and the stack adapters) must do, the same in every language AffordKit has
it in: TypeScript (`js/`), Python (`python/`), Go (`go/`). Each port has a test that runs every case in it and compares
**exactly**: the same request sent to the app, the same text back to the model, the same error flag and code.

The file is written from the TypeScript implementation, which is the reference: change behavior there, then

```sh
cd js && CONFORMANCE_UPDATE=1 npx vitest run test/conformance.test.ts
```

and the other ports' tests fail until they do the same.

## A case

```jsonc
{
  "name": "…",
  "options": { "timeoutMs": 50, "screen": "whole", "tools": ["ui_look"], "maxNodes": 3, "present": false, "handoff": true },
  "seen": { /* a context, or null: what the agent was shown before (remote.seen) */ },
  "steps": [
    {
      "tool": "ui_act",                       // the tool the model called
      "input": { "node": "w4", "op": "press" },// its input (absent: {})
      "reply": { /* how the app answers this step's request, if it sends one */ },
      "handoffSays": "notification sent"      // ui_handoff with a host: what the host returns, or { "throws", "code" }
    }
  ],
  "expect": {
    "toolsBefore": ["ui_look", "…"],          // remote.tools() names after seen, before the first step
    "toolsAfter": ["…"],                      // and after the last step
    "steps": [
      {
        "request": { "calls": [ /* … */ ] },  // what was sent to the app (absent: nothing was)
        "handoff": { /* the handoff given to the host, without expiresAt */ },
        "text": "…", "isError": false, "code": "not_found",
        "images": [{ "mime": "image/png", "data": "…" }]
      }
    ]
  }
}
```

- `options`: absent fields take the defaults. `present: false` means the user is away (`present` returns false); `handoff: true`
  means there is a handoff host (`onHandoff`), which records the handoff and returns `handoffSays` (or raises it, with its code).
- `reply` is one of: a `UiAnswer` (return it); `{ "never": true }` (never answer: the step times out after `timeoutMs`);
  `{ "throws": "message", "code"?: "…" }` (the transport fails: an `AffordError` with that code, or a plain error without one).
- A handoff's `expiresAt` is the time it was left: check that it is a number, then leave it out before comparing.

`shapes` is what each stack adapter gives for the same remote: the tools (`anthropicTools`, `openaiTools`, `openaiResponsesTools`,
`mcpList`) and results, with and without a picture, with an error, and with arguments that aren't JSON. The remote behind them
answers every request with the `inbox` screen and a picture (`answering`), or with `{ error: "gone", code: "unavailable" }`
(`failing`); see `js/test/conformance.test.ts`.

## Things to get exactly right

- **JSON in text.** Where the text holds a value as JSON (a node's value, a tool's result, a name in a preview), it is what
  `JSON.stringify` gives: no spaces, non-ASCII as it is, and object keys **in the order they came in**. Keep the order from the
  app's answer (Python dicts do; in Go, keep the raw JSON instead of decoding into a map).
- **Numbers** are printed as JavaScript does: `312`, not `312.0`.
- **Dates.** A peeked page seen at `seenAt` (ms) prints it as ISO 8601 in UTC with milliseconds: `2026-10-21T22:09:32.948Z`.
- **Strings** are compared byte for byte, line breaks (`\n`) included; the dashes and arrows in them (`—`, `–`, `…`, `·`, `∈`) are
  Unicode characters, not ASCII look-alikes.
