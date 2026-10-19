<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit-dark.svg">
    <img src="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit.svg" alt="AffordKit" width="140">
  </picture>
</p>

# AffordKit for Flutter

Your Flutter app's UI, for AI agents to see and use.

Wrap widgets with `.afford()` and they become a tree the agent reads: what each is, what it shows, its state, and what can be
done to it. The agent answers with calls (press, type, scroll, go to a page) that your app runs under its own rules: `allow`,
`confirm` (the user says yes first) or `deny` (the user's own act). A tap lands where the user would tap; text is typed in as if
by the keyboard.

```
Route: /message/42 — can go back
[w4 key=thread.reply] button "Reply" — press
[w7 key=thread.body] text "Message" = "Can we meet on Tuesday at ten?" — read
[w9 key=compose.send] button "Send" — press(deny)
```

Using JavaScript or TypeScript? See the [JavaScript README](https://github.com/momomoink/affordkit/blob/main/js/README.md).

## Install

```sh
flutter pub add affordkit
```

Before it is on pub.dev, depend on the repository:

```yaml
dependencies:
  affordkit:
    git:
      url: https://github.com/momomoink/affordkit.git
      ref: v0.1.0
      path: flutter
```

To work on AffordKit and your app together, add a `pubspec_overrides.yaml` beside your `pubspec.yaml` and keep it out of git:

```yaml
dependency_overrides:
  affordkit:
    path: ../affordkit/flutter
```

## Set up

```dart
import 'package:affordkit/affordkit.dart';

MaterialApp(
  // Builds pages off screen for peeks, and takes pictures of the screen
  builder: (context, child) => AffordPreviewHost(child: child!),
  home: const HomePage(),
);

AffordKit.instance
  // (in a cascade, a function needs its parentheses)
  ..confirm = ((call, {node, tool}) => askTheUser(node?.name ?? tool?.name ?? '?')) // ops with policy confirm
  ..onAct = (event) async { /* show where the agent is about to tap: event.rect */ }
  ..typeDelay = const Duration(milliseconds: 40); // type text in a few characters at a time
```

## Put widgets into the tree

```dart
TextField(controller: body).afford('Body', key: 'compose.body');

ElevatedButton(onPressed: send, child: const Text('Send'))
    .afford('Send', key: 'compose.send', policy: Policy.deny);

IconButton(icon: const Icon(Icons.archive), onPressed: archive)
    .afford('Archive', key: 'thread.archive', description: 'Moves the mail to the archive');

Switch(value: notify, onChanged: setNotify).afford('Notify me', key: 'settings.notify');

Row(children: [...]).afford('Filters', role: Role.region); // keeps a group together
```

- **name**: what the user sees it called. **key**: a name that stays the same across visits (`<screen>.<control>`), so the agent
  can act right after going to a page.
- **role** is guessed from the widget (buttons, `InkWell`, `GestureDetector`, `TextField`, `Switch`, `Checkbox`, `ListTile`,
  `Tab`, `Text`, dialogs); say it for widgets of your own.
- **policy** for all ops, **policies** per op (`{'write': Policy.confirm}`). Password fields are denied by themselves.
- Afford your shared components once (title bar buttons, list rows, settings rows) and every screen using them is covered.

Each role has its ops: `press` for buttons, `read` / `write` / `append` / `clear` for text fields, `toggle` / `set` for switches
and checkboxes, `select` for tabs and radios, `read` for text, `view` (a picture) for images and parts of the screen.

## Your own widgets and functions

Give a widget of your own its role and state:

```dart
MomoSwitch(value: on, onChanged: setOn).afford('Dark mode', role: Role.switch_, state: {'checked': on});
```

Standard ops tap the widget, so anything that responds to a tap works. When a tap is not the action you want, add an op of your
own (one named like a standard op, such as `press`, replaces it):

```dart
MailRow(mail).affordItem('${mail.id}', ops: [
  CustomOp('archive', description: 'Archive this mail', run: (args) async {
    await api.archive(mail.id);
    return null;
  }),
]);
```

What `run` returns goes back to the agent. Throw `AffordError(ErrorCode.notFound, '...')` to say why it failed.

## Long lists

A list is one node with a preview of what shows; the agent fetches the entry it wants as a tree of its own
(`mail.list[42].reply`), searches, and scrolls:

```dart
ListView.builder(
  itemCount: mails.length,
  itemBuilder: (context, i) => MailRow(mails[i]).affordItem('${mails[i].id}', index: i),
).affordContainer('Inbox', key: 'mail.list', kind: 'list');
```

That is enough: the kit reads the list builder, builds entries off screen to search them, and scrolls to any of them. For data
that is not all loaded, give it a search: `items: (offset, limit, query) => ...`, and `count`.

## Pages and app tools

```dart
AffordKit.instance.routes = AffordRoutes(
  current: () => currentRoute(),
  routes: const [
    RouteSpec('/mail/:box', 'A mailbox', params: {'box': RouteParam(values: ['inbox', 'archive'])}),
    RouteSpec('/message/:id', 'One mail: reply, forward, archive'),
  ],
  navigate: (route) async => openRoute(route),
  back: () async => navigatorKey.currentState?.maybePop(),
  canGoBack: () => navigatorKey.currentState?.canPop() ?? false,
);

// What needs no screen
AffordKit.instance.registerTool(AffordTool(
  'set_theme',
  'Switch between light, dark and the system setting',
  inputSchema: const {'type': 'object', 'properties': {'theme': {'type': 'string', 'enum': ['light', 'dark', 'system']}}},
  execute: (args) async {
    await settings.setTheme('${args['theme']}');
    return 'Done';
  },
));
```

The agent can go to a route, go back, and peek at a page before going there. Pages under the one on top (another page, a dialog)
stay in the tree as nodes marked `behind`; their controls still work, without the user seeing it.

## Connect an agent

Your app answers the agent's requests with `kit.answer(request)` (JSON in, JSON out), over the channel you already have:

```dart
myChannel.onRequest((id, request) async => myChannel.reply(id, await AffordKit.instance.answer(request)));
```

Where the model runs, the agent's side gives it five tools (`ui_look`, `ui_act`, `ui_tool`, `ui_navigate`, `ui_peek`) and runs
them. After each act the model is told what changed on screen, not the whole tree again, and a failed call carries a code
(`not_found`, `denied`, `needs_confirm`, ...).

- **Model on your server in TypeScript or JavaScript:** `AffordRemote` from the npm package, with the Anthropic, OpenAI and MCP
  shapes. See [Connecting an agent](https://github.com/momomoink/affordkit/blob/main/docs/connecting-an-agent.md).
- **Model called from Dart** (in the app, or a Dart server):

```dart
final ui = AffordKit.instance.agent();                    // in the app itself
// or: AffordAgent(send: (request) => myChannel.ask(request)) over a transport

final body = {'model': model, 'messages': messages, 'tools': anthropicTools(ui.tools())};
// for each tool_use block in the reply:
final result = await anthropicResult(ui, block);          // the tool_result block, pictures included
```

Dart also has `openaiTools` / `openaiResult` and `mcpToolList` / `mcpToolCall`.

## What to let the agent do

- **Allow** what is reversible and visible: open, search, type into a draft, star, archive.
- **Confirm** what is hard to undo or leaves the app: delete, unsubscribe, accept an invite.
- **Deny** the user's own acts: send, pay, publish, grant permissions. The agent can still point to them.
- **Leave out** secrets, other people's private data, and the agent's own chat panel (just don't afford them).

More in [What to expose](https://github.com/momomoink/affordkit/blob/main/docs/what-to-expose.md).

## Let your coding agent add it

The repository has an agent skill that adds AffordKit to an existing app: it surveys the project, affords the controls, asks you
about the risky actions, makes lists containers, declares routes and tools, and connects the agent. In Claude Code:

```text
/plugin install affordkit --marketplace momomoink/affordkit
```

Then ask it to "add AffordKit to this app". Other ways to install it are in the
[repository README](https://github.com/momomoink/affordkit#let-your-coding-agent-add-it).

## More

- [Getting started: Flutter](https://github.com/momomoink/affordkit/blob/main/docs/getting-started-flutter.md): every option, in
  more detail.
- [Concepts](https://github.com/momomoink/affordkit/blob/main/docs/concepts.md): the tree, ops, policies, containers, pages.
- [Protocol](https://github.com/momomoink/affordkit/blob/main/docs/protocol.md): the JSON.
