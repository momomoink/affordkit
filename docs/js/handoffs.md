# Handoffs: when the user has left the app

An agent works the page the user is looking at. When the user has left (the tab is hidden, the app is in the background, the
phone is in their pocket), there is no screen to work: nobody sees it, and a backgrounded mobile app draws no frames at all.
The agent should then do what it can with your backend's own tools (write the draft, file the expense), and leave the user a
**handoff**: a short message, and the calls that take them to what it did when they come back.

AffordKit defines the handoff, gives the agent a tool for it, checks it, and runs it in the page. It does not send it: how the
user hears of it (a push notification, an email, a badge) is your app's.

## A handoff

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

- `message`: what the agent did and what is waiting, for the user to read (at most 500 characters).
- `route`: where to go first, one of the app's routes filled in. Optional.
- `calls`: then these, in order: an op on a control by its **key** (at most 20). Never by id: ids from a look are long gone by
  the time the user comes back, so a call addressed to one (`n12`, `peek:…`) is refused.
- `expiresAt`: when it stops being good (ms since the epoch). The agent's side sets it (a day by default).
- `id`: your id for it, set when you store it.

`parseHandoff(input)` checks one (the agent's input, what you stored) and gives it back in this shape, or `null` when it is not
one or it has expired; `handoffProblem(input)` says what is wrong with it; `handoffExpired(handoff)` whether its time is up.

## The agent's side

Tell `AffordRemote` whether the user is in the app, and where handoffs go:

```ts
import { AffordRemote } from 'affordkit';

const ui = new AffordRemote({
  send: (request) => askThePage(session, request),
  present: () => session.visible,              // the page reports document.visibilityState over your channel
  onHandoff: async (handoff) => {
    const id = await db.handoffs.insert({ userId: session.userId, ...handoff, used: false });
    await push.send(session.userId, { title: 'Momo', body: handoff.message, data: { handoff: id } });
    return 'notification sent';
  },
  handoffTtlMs: 24 * 3600_000,                 // the default
});
```

- `present: () => boolean`: while it returns `false`, `ui_look`, `ui_act`, `ui_navigate`, `ui_peek` and `ui_tool` answer at once
  with code `away` (`isError: true`), without asking the page. The text tells the model the user is not in the app, to use its
  other tools, and to leave a handoff. `ui_tool` is unavailable too: the app's own tools run in the app. Without `present`, the
  user is taken to be there.
- `onHandoff(handoff)`: without it, `ui_handoff` is not offered. With it, `ui.tools()` (and so `anthropicTools`, `openaiTools`,
  `openaiResponsesTools`, `mcpHandlers` and `runners`) includes `ui_handoff`. The agent's input is checked with
  `parseHandoff` first, and its route against the routes the agent has seen; a bad one answers `bad_args`, and `onHandoff` is not
  called. What `onHandoff` resolves with (`'notification sent'`) is told the model: `Handoff left: notification sent`.

An agent in the page itself takes the same options: `kit.agent({ present: () => document.visibilityState === 'visible', onHandoff })`.

The tool the model gets:

```json
{
  "name": "ui_handoff",
  "inputSchema": {
    "type": "object",
    "properties": {
      "message": { "type": "string" },
      "route": { "type": "string" },
      "calls": { "type": "array", "items": { "type": "object", "properties": { "key": {}, "op": {}, "args": {} }, "required": ["key", "op"] } }
    },
    "required": ["message"]
  }
}
```

Its description tells the model to use it only when the user is away, to address controls by key, and to keep it to bringing
the user to the result (open the page, the item), never anything that sends, pays, deletes or can't be undone.

## The page's side

When the user taps the notification, fetch the handoff by its id from your server, then run it:

```ts
const handoff = parseHandoff(await api.get(`/handoffs/${id}`)); // your authenticated API; it marks it used
if (handoff) {
  const result = await kit.runHandoff(handoff);
  if (!result.ok) toast(`${handoff.message} (${result.error})`);
}
```

`kit.runHandoff(handoff, { confirm?, now? })`:

1. refuses it when it has expired (code `expired`) or is not a valid handoff (code `bad_args`);
2. goes to its `route`, and waits for the page to show (your routes' `settle`);
3. runs its calls in order, the way the agent's calls run: `deny` is never run, `confirm` asks (the `confirm` given here, else
   the kit's own; with neither, it stops there with `needs_confirm`, not done);
4. stops at the first call that fails.

It resolves with `{ ok, ran, stoppedAt?, code?, error?, results }`: how many calls ran, the index of the call it stopped at (`-1`
before any: invalid, expired, or the route could not be gone to), why, and each step's result.

## A worked example

The user asked Momo, a mail assistant, to answer a mail, then put the phone away.

1. The agent calls `ui_look`, and gets `Failed (away): The user is not in the app right now ...`.
2. It writes the reply with your backend's tool: `create_draft({ inReplyTo: 'm42', body: '...' })` → draft `d81`.
3. It calls `ui_handoff`:

   ```json
   { "message": "回复写好了，在草稿箱", "route": "/drafts", "calls": [{ "key": "draft.d81", "op": "press" }] }
   ```

4. `onHandoff` stores it (id `h_5f2c`) and pushes a notification whose data is only `{ "handoff": "h_5f2c" }`; the model is told
   `Handoff left: notification sent`.
5. The user taps the notification. The page reads the id, fetches `/handoffs/h_5f2c` over its signed-in API (the server checks
   it is this user's, unused and not expired, and marks it used), and calls `kit.runHandoff(handoff)`.
6. The page goes to `/drafts` and presses `draft.d81`: the draft is open, where the user can read it and press Send themselves.

## Security

- **Put only the id in the notification.** Fetch the handoff over your authenticated API when it is tapped. A notification's
  payload or a deep link can be forged by anyone who can open a link on the device (on Android, any app can send an intent):
  never run a handoff carried in one.
- **Never run a handoff from an unauthenticated source.** Check on the server that it belongs to the signed-in user.
- **One-shot.** Mark it used when it is fetched, so it can't be run twice.
- **It expires.** `runHandoff` refuses an expired one; your server should not hand one out either.
- **Policies still apply.** A handoff runs under the same `allow` / `confirm` / `deny` as the agent's live calls: it can't
  press what the agent couldn't.
