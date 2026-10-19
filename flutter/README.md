<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit-dark.svg">
    <img src="https://raw.githubusercontent.com/momomoink/affordkit/main/brand/affordkit.svg" alt="AffordKit" width="140">
  </picture>
</p>

# AffordKit for Flutter

Your Flutter app's UI, for AI agents to see and use. Widgets put into the tree with `.afford()` become nodes (what each is, what
it shows, its state, the ops it allows), and the agent's calls run on them: a tap where the user would tap, text typed in as if by
the keyboard. The same JSON protocol as the TypeScript package ([`../js`](../js/README.md)).

```dart
import 'package:affordkit/affordkit.dart';

ElevatedButton(onPressed: send, child: const Text('Send')).afford('Send', policy: Policy.deny);
TextField(controller: body).afford('Body', key: 'compose.body');

// A long list is one node; its entries are fetched, searched and scrolled to by the kit
ListView.builder(itemBuilder: (_, i) => MailRow(mails[i]).affordItem(mails[i].id))
    .affordContainer('Inbox', key: 'mail.list');

final context = AffordKit.instance.context();        // the screen, for the agent
final next = await AffordKit.instance.execute(calls); // the agent's calls, and the screen after
```

- **Pages:** `AffordKit.instance.routes = AffordRoutes(...)` lets the agent go to a page, go back, and peek at one first. Put an
  `AffordPreviewHost` around the app (in `MaterialApp.builder`) for peeks built off screen and for pictures of the screen.
- **App tools:** `registerTool(AffordTool(...))` for what needs no screen (a setting, a refresh).
- **Your own widgets:** `.afford(name, role: ..., state: {...}, ops: [CustomOp(...)])`.
- **Hooks:** `onAct` before each op (show the user where the agent is about to tap), `confirm` for ops with policy confirm,
  `typeDelay` to type text in a little at a time.
- **The agent's side:** `kit.answer(request)` answers an agent over any transport; `AffordAgent` is that agent's side in Dart,
  with the tools in the Anthropic, OpenAI and MCP shapes (`kit.agent()` for one in the app itself).
