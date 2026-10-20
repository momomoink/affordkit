# Handoffs: when the user has left the app

An agent works the screen the user is looking at. When the user has left the app (it is in the background, the phone is in their
pocket), there is no screen to work: Flutter draws no frames in the background, and iOS suspends the app soon after. The agent
should then do what it can with your backend's own tools (write the draft, file the expense), and leave the user a **handoff**: a
short message, and the calls that take them to what it did when they come back.

AffordKit defines the handoff, gives the agent a tool for it, checks it, and runs it in the app. It does not send it: how the
user hears of it (a push notification, usually) is your app's.

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
- `calls`: then these, in order: an op on a widget by its **key** (at most 20). Never by id: ids from a look are long gone by the
  time the user comes back, so a call addressed to one (`w12`, `peek:…`) is refused.
- `expiresAt`: when it stops being good (ms since the epoch). The agent's side sets it (a day by default).
- `id`: your id for it, set when you store it.

In Dart it is a `Handoff` (`message`, `route`, `calls` of `HandoffCall(key, op, args)`, `expiresAt` as a `DateTime`, `id`;
`toJson()`, `isExpired()`, `withId(id)`). `parseHandoff(json)` checks one (the agent's input, what you stored) and gives it back,
or `null` when it is not one or it has expired; `handoffProblem(json)` says what is wrong with it.

## The agent's side

Tell the agent whether the user is in the app, and where handoffs go:

```dart
final ui = AffordKit.instance.agent(
  onHandoff: (handoff) async {
    await api.storeHandoff(handoff.toJson());              // your server keeps it, and sends the push with its id only
    return 'notification sent';
  },
);
// or, on a Dart server:
final ui = AffordAgent(
  send: (request) => askTheApp(session, request),
  present: () => session.appInForeground,                  // the app reports its lifecycle over your channel
  onHandoff: (handoff) => store.andNotify(session.userId, handoff),
  handoffTtl: const Duration(hours: 24),                   // the default
);
```

- `present`: while it returns `false`, `ui_look`, `ui_act`, `ui_navigate`, `ui_peek` and `ui_tool` answer at once with
  `ErrorCode.away` (`isError: true`), without asking the app. The text tells the model the user is not in the app, to use its
  other tools, and to leave a handoff. `ui_tool` is unavailable too: the app's own tools run in the app. `kit.agent()` defaults
  it to the app's lifecycle (away when paused, hidden or detached); `AffordAgent` without it takes the user to be there. A
  server-side agent learns the lifecycle from the app: send `AppLifecycleListener` changes over your channel.
- `onHandoff(handoff)`: without it, `ui_handoff` is not offered. With it, `ui.tools()` (and so `anthropicTools`, `openaiTools`,
  `mcpToolList`) includes `ui_handoff`. The agent's input is checked with `parseHandoff` first, and its route against the routes
  the agent has seen; a bad one answers `bad_args`, and `onHandoff` is not called. What it completes with (`'notification sent'`)
  is told the model: `Handoff left: notification sent`.

The tool the model gets takes `{ message, route?, calls?: [{ key, op, args? }] }`. Its description tells the model to use it only
when the user is away, to address widgets by key, and to keep it to bringing the user to the result (open the page, the item),
never anything that sends, pays, deletes or can't be undone.

## The app's side

When the user taps the notification, fetch the handoff by its id from your server, then run it:

```dart
// (your push plugin's "notification opened" stream, e.g. FirebaseMessaging.onMessageOpenedApp)
pushes.onOpened.listen((Map<String, Object?> data) async {
  final id = data['handoff'];
  if (id is! String) return;
  final handoff = parseHandoff(await api.fetchHandoff(id)); // your authenticated API; it marks it used
  if (handoff == null) return;
  final result = await AffordKit.instance.runHandoff(handoff);
  if (!result.ok) showSnackBar('${handoff.message} (${result.error})');
});
```

`kit.runHandoff(handoff, {confirm, now})`:

1. refuses it when it has expired (`ErrorCode.expired`) or is not a valid handoff (`ErrorCode.badArgs`);
2. goes to its `route`, and waits for the page to show (your routes' `settle`);
3. runs its calls in order, the way the agent's calls run: each through `onAct`, so your overlay shows the steps; `deny` is never
   run, `confirm` asks (the `confirm` given here, else the kit's own; with neither, it stops there with `needsConfirm`, not done);
4. stops at the first call that fails.

It completes with a `HandoffResult`: `ok`, `ran` (how many calls ran), `stoppedAt` (the index of the call it stopped at, `-1`
before any: invalid, expired, or the route could not be gone to), `code`, `error`, and each step's `results`.

Run it once the app is in the foreground and its first page has shown (a tap on a notification may start the app cold).

## A worked example

The user asked Momo, a mail assistant, to answer a mail, then put the phone away.

1. The agent calls `ui_look`, and gets `Failed (away): The user is not in the app right now ...`.
2. It writes the reply with your backend's tool: `create_draft({inReplyTo: 'm42', body: '...'})` → draft `d81`.
3. It calls `ui_handoff`:

   ```json
   { "message": "回复写好了，在草稿箱", "route": "/drafts", "calls": [{ "key": "draft.d81", "op": "press" }] }
   ```

4. `onHandoff` stores it (id `h_5f2c`) and pushes a notification whose data is only `{"handoff": "h_5f2c"}`; the model is told
   `Handoff left: notification sent`.
5. The user taps the notification. The app reads the id, fetches the handoff over its signed-in API (the server checks it is
   this user's, unused and not expired, and marks it used), and calls `AffordKit.instance.runHandoff(handoff)`.
6. The app goes to `/drafts` and presses `draft.d81` (your `onAct` ring shows where): the draft is open, where the user can read
   it and press Send themselves.

## Security

- **Put only the id in the notification.** Fetch the handoff over your authenticated API when it is tapped. A notification's
  payload or a deep link can be forged (on Android, any app can send your app an intent): never run a handoff carried in one.
- **Never run a handoff from an unauthenticated source.** Check on the server that it belongs to the signed-in user.
- **One-shot.** Mark it used when it is fetched, so it can't be run twice.
- **It expires.** `runHandoff` refuses an expired one; your server should not hand one out either.
- **Policies still apply.** A handoff runs under the same `allow` / `confirm` / `deny` as the agent's live calls: it can't
  press what the agent couldn't.
