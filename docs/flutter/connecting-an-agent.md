# Connecting an agent

Your app holds the kit; your model runs somewhere: on your server, or called from the app itself. They talk in two messages:

- **request** (agent → app): `{"look": true}` (optionally `"picture": true`), or `{"calls": [...]}`;
- **answer** (app → agent): `{"context": ..., "results": [...], "picture": ...}`, or `{"error": "...", "code": "..."}`.

Both are JSON maps. The app answers with `kit.answer(request)`.

## The app's side

Answer the agent's requests over the channel your app already has to its backend (a WebSocket, server-sent events, push):

```dart
myChannel.onRequest((String id, Map<String, Object?> request) async {
  final answer = await AffordKit.instance.answer(request);
  await myChannel.reply(id, answer);
});
```

- Answer every request: `answer` never throws, it answers with `{error, code}`.
- Tag each request with the id of the app instance the user is chatting from (a uuid made at startup), so another device of the
  same user doesn't answer it.
- Requests may come while the app is in the background, where no frames are drawn: give the agent's side a timeout, and tell
  it when the app goes to the background and comes back (its `present`), so the agent knows to leave a [handoff](handoffs.md).
- `onAct` lets you show the user each step: a ring where the agent is about to tap, a line saying what it is doing. Hide your own
  chat sheet while the agent works, so the user sees the screen it works on, and bring it back when the agent's turn ends.

### What the user does meanwhile

The user's hands stay on the screen while the agent works it. Turn on `kit.watchUser(true)` when the agent starts working the
screen (its first request with calls) and off when its turn ends: the kit notes what the user does themselves on afforded widgets,
and the next `answer` carries it as `userActions`, oldest first, with the screen as it is after them:

```dart
final answer = await AffordKit.instance.answer(request);
// {"context": ..., "results": [...], "userActions": [{"at": 1792711772948, "op": "press", "node": {"id": "w9", "key": "mail.list[42]",
//   "role": "listitem", "name": "Lunch on Tuesday?"}, "route": "/message/42"}]}
```

- Taps are `press`, `toggle` (value `on` / `off`) or `select` (value: what was picked) on the nearest afforded widget under the
  finger; typing is one `write` per field per burst (value: its text after, cut short; never a password field's); a page changed
  is `navigate` or `back` (with `route`). A tap that opens a page carries that page's `route`. Scrolling isn't noted.
- Never the kit's own calls: nothing is noted while it runs them (or a handoff), nor for a moment after.
- At most the latest 30 are kept; off forgets what wasn't taken. `takeUserActions()` takes them yourself, when the app answers
  its own way (take them before reading the screen); `onUserAction` is told each one as it is noted.
- On the agent's side, `AffordAgent` (and `AffordRemote` in TypeScript) puts them at the top of the tool's answer
  (`describeUserActions`), so the model sees the screen moved under it, and why.

## The agent's side, in Dart

When the model is called from Dart (in the app itself, or a Dart server), `AffordAgent` is the agent's side:

```dart
final ui = AffordKit.instance.agent();                       // in the app: no transport
// or, on a Dart server:
final ui = AffordAgent(send: (request) => askTheApp(userSession, request), timeout: const Duration(seconds: 45));
ui.seen(screenSentWithTheMessage);                           // optional: the screen the user's message came with
```

- `ui.tools()`: the five tools (`ui_look`, `ui_act`, `ui_tool`, `ui_navigate`, `ui_peek`; `ui_tool` only when the app has tools of
  its own; `ui_handoff` too with `onHandoff`), each with `name`, `description` and `inputSchema`.
- `ui.has(name)`: whether a tool the model called is one of these.
- `ui.handle(name, input)`: runs one and completes with a `ToolAnswer`: `text`, `isError`, `code`, `images`, `context`. It never
  throws: a failure is an answer with `isError` and a `code`.

`wholeScreen: true` gives the whole tree after every act instead of what changed.

### When the user has left

`present` says whether the user is in the app (`kit.agent()` follows the app's lifecycle by itself); while it says no, the screen
tools answer `ErrorCode.away` at once. `onHandoff` adds a sixth tool, `ui_handoff`, for the agent to leave the user a message and
the calls that take them to what it did when they come back. See [Handoffs](handoffs.md).

### Model APIs

The tools and results in each API's JSON shape:

```dart
// Anthropic Messages API
final request = {'model': model, 'max_tokens': 1024, 'messages': messages, 'tools': anthropicTools(ui.tools())};
// for each tool_use block in the reply:
final toolResult = await anthropicResult(ui, block); // {type: tool_result, tool_use_id, content, is_error?}, pictures included

// OpenAI Chat Completions
final tools = openaiTools(ui.tools());
final toolMessage = await openaiResult(ui, toolCall); // {role: tool, tool_call_id, content}

// MCP: tools/list and tools/call results
final list = mcpToolList(ui);
final result = await mcpToolCall(ui, name, arguments);
```

## The agent's side on a TypeScript server

A Flutter app often has its model on a Node server. There the agent's side is `AffordRemote` from the npm package `affordkit`,
with the same tools and answers and adapters for the Anthropic, OpenAI and MCP SDKs; its `send` delivers the request to the app
and resolves with the app's answer. See the JavaScript package's
[Connecting an agent](https://github.com/momomoink/affordkit/blob/main/docs/js/connecting-an-agent.md).

## What the model gets back

`ui_look` gives the whole screen as text (with a picture of the screen when asked and the app has an `AffordPreviewHost`). After
an act, the model gets what it did to the screen, from what it last saw:

```
Done.

The screen changed:
Now at /reply/7 (was /message/7) — can go back.
+ [w21 key=compose.body] textbox "Body" — read, write, append, clear
+ [w22 key=compose.send] button "Send" — press(deny)
+ [behind-2] page "/message/7" (behind) — now under what shows: its 6 controls still work, unseen
```

When most of the screen changed, the answer is the whole new screen. `describe(contextJson)` and
`describeChange(before, after)` make the same text for a loop of your own.

## Error codes

| `ErrorCode` | on the wire | meaning |
|---|---|---|
| `notFound` | `not_found` | no such node (it went), route, tool or entry |
| `noOp` | `no_op` | the node has no such op |
| `badArgs` | `bad_args` | the op's arguments are missing or wrong |
| `denied` | `denied` | policy deny: the user does this themselves |
| `needsConfirm` | `needs_confirm` | policy confirm, and the app gave no way to ask: nothing was done |
| `declined` | `declined` | the user was asked and said no |
| `disabled` | `disabled` | the widget is disabled (or read-only) |
| `unreachable` | `unreachable` | something is over it and it has no callback to call |
| `timeout` | `timeout` | the app did not answer in time |
| `unavailable` | `unavailable` | no app to work, or it could not answer |
| `away` | `away` | the user is not in the app now (`present` says so): the screen can't be worked; leave a handoff |
| `expired` | `expired` | a handoff past its `expiresAt`: not run |
| `failed` | `failed` | anything else that went wrong doing it |

Your own ops and tools can say which by throwing `AffordError(ErrorCode.x, 'message')`.

## Prompting

The tool descriptions explain the tree, containers, keys and policies to the model. Add what is specific to your app:

- what the user is looking at when they write (send `kit.context().toJson()` with the chat message, and `ui.seen()` it);
- that it should work the screen the user sees, step by step, and leave denied actions (Send) to the user;
- that it should go to a page before acting on it when the user is watching, rather than act on pages underneath.
