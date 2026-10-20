# Getting started: Flutter

In Flutter a widget is in the tree when you wrap it with `.afford(...)`. What it is and what it can do come from the widget
itself: a button is pressed, a text field read and written, a switch set. Every afforded widget that is built is in the tree,
including those on pages under the one on top.

## Install

```sh
flutter pub add affordkit
```

or add it to your `pubspec.yaml`:

```yaml
dependencies:
  affordkit: ^0.1.0
```

To work on AffordKit and your app together, point at a local checkout in a `pubspec_overrides.yaml` next to your
`pubspec.yaml`, and keep that file out of git:

```yaml
dependency_overrides:
  affordkit:
    path: ../affordkit/flutter
```

## Set up the kit

`AffordKit.instance` is the kit most apps use. Put an `AffordPreviewHost` around the app: it builds pages off screen for peeks
and takes pictures of the screen.

```dart
import 'package:affordkit/affordkit.dart';

MaterialApp(
  navigatorKey: navigatorKey,
  builder: (context, child) => AffordPreviewHost(child: child!),
  home: const HomePage(),
);

final kit = AffordKit.instance
  // (in a cascade, a function needs its parentheses)
  ..confirm = ((call, {node, tool}) => askTheUser(node?.name ?? tool?.name ?? '?')) // ops with policy confirm
  ..onAct = (event) async { /* show where the agent is about to tap: event.rect; event.behind when unseen */ }
  ..typeDelay = const Duration(milliseconds: 40); // type text in a few characters at a time
```

## Afford widgets

```dart
TextField(controller: body).afford('Body', key: 'compose.body');

ElevatedButton(onPressed: send, child: const Text('Send'))
    .afford('Send', key: 'compose.send', policy: Policy.deny);

IconButton(icon: const Icon(Icons.archive), onPressed: archive)
    .afford('Archive', key: 'thread.archive', description: 'Moves the mail to the archive');

Switch(value: notify, onChanged: setNotify).afford('Notify me', key: 'settings.notify');

Row(children: [...]).afford('Filters', role: Role.region); // keeps a group together in the tree
```

`.afford(name, {key, description, role, policy, policies, ops, state, kit})`:

- `role`: guessed from the widget type (buttons, `InkWell` and `GestureDetector` are buttons; `TextField` is a textbox;
  `Switch`, `Checkbox`, `ListTile`, `Tab`, `Text`, `Scaffold`, dialogs...). Say it for widgets of your own.
- `policy` for all ops, `policies` per op (`{'write': Policy.confirm}`).
- `state`: what a widget of your own says of itself (`{'disabled': true}`, `{'checked': value}`, `{'selected': true}`), over what
  the kit finds.

Afford widgets in your shared components once (your app's title bar button, settings row, switch row) and every screen that
uses them is covered.

## Your own widgets and functions

A widget the kit cannot read needs a role and its state:

```dart
FancySwitch(value: on, onChanged: setOn)
    .afford('Dark mode', role: Role.switch_, state: {'checked': on});
```

The standard ops tap the widget, so they work for any widget that responds to a tap. When a tap is not what you want, add an op
of your own (one named like a standard op replaces it):

```dart
MailRow(mail).affordItem(
  '${mail.id}',
  ops: [
    CustomOp(
      'archive',
      description: 'Archive this mail',
      run: (args) async {
        await api.archive(mail.id);
        return null;
      },
    ),
  ],
);
```

`run(args)` gets the agent's arguments; what it returns goes back to the agent. Throw `AffordError(ErrorCode.notFound, '...')` to
say why it failed.

## Long lists: containers

```dart
ListView.builder(
  itemCount: mails.length,
  itemBuilder: (context, i) => MailRow(mails[i]).affordItem('${mails[i].id}', index: i),
).affordContainer('Inbox', key: 'mail.list', kind: 'list');
```

That is enough: the kit reads the list builder, builds entries off screen to search them, and scrolls to any entry. Say more
for data that is not all loaded, or for a faster search:

```dart
.affordContainer(
  'Inbox',
  key: 'mail.list',
  kind: 'list',
  count: () => total,
  items: (offset, limit, query) async => [
    for (final m in await api.search(query, offset: offset, limit: limit))
      ItemSummary(id: '${m.id}', name: m.subject, description: m.from),
  ],
  indexOf: (id) => mails.indexWhere((m) => '${m.id}' == id),
  scrollTo: (target) => scrollToMail(target.id, target.index),
)
```

Afforded widgets inside an entry get keys under it: `mail.list[42].reply`.

## Pages

```dart
kit.routes = AffordRoutes(
  current: () => currentRoute(),             // e.g. '/message/42'
  routes: const [
    RouteSpec('/mail/:box', 'A mailbox', params: {'box': RouteParam(values: ['inbox', 'archive'])}),
    RouteSpec('/message/:id', 'One mail: reply, forward, archive'),
    RouteSpec('/settings/:section', 'Settings'),
  ],
  navigate: (route) async => openRoute(route),
  back: () async => navigatorKey.currentState?.maybePop(),
  canGoBack: () => navigatorKey.currentState?.canPop() ?? false,
  preview: (route) => pageFor(route),        // optional: the page's widget, built off screen for a peek
);
```

Keep the trees of pages already seen across runs with `kit.snapshots()` / `kit.loadSnapshots(saved)`.

## App tools

```dart
kit.registerTool(AffordTool(
  'set_theme',
  'Switch the app between light, dark and the system setting',
  inputSchema: const {
    'type': 'object',
    'properties': {'theme': {'type': 'string', 'enum': ['light', 'dark', 'system']}},
    'required': ['theme'],
  },
  execute: (args) async {
    await settings.setTheme('${args['theme']}');
    return 'Done';
  },
));
```

## Connect the agent

Answer the agent's requests with `kit.answer(request)` over whatever your app already has (a WebSocket, push, your API). Both
are JSON maps:

```dart
api.onAffordRequest((id, request) async => api.affordAnswer(id, await kit.answer(request)));
```

An agent that runs in the app itself needs no transport: `final ui = kit.agent();`. See
[Connecting an agent](connecting-an-agent.md).

## Check what the agent sees

```dart
debugPrint(describe(kit.context().toJson()));
```

That is the text the model reads. In a widget test, pump a screen and assert on `kit.context()`: the nodes you expect, their keys,
and the policies of anything that sends, pays or deletes.
