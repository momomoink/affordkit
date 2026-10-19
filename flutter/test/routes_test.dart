import 'dart:convert';

import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<AffordNode> all(AffordNode n) => [n, for (final c in n.children) ...all(c)];

/// Runs [f] while pumping frames (navigation animates, taps rebuild), and gives its result.
Future<T> drive<T>(WidgetTester tester, Future<T> f) async {
  T? value;
  var done = false;
  f.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done, true, reason: 'did not finish');
  return value as T;
}

class _AiPage extends StatefulWidget {
  const _AiPage();
  @override
  State<_AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<_AiPage> {
  bool tagging = false;
  final signature = TextEditingController();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(children: [
      Switch(value: tagging, onChanged: (v) => setState(() => tagging = v)).afford('Tag new mail', key: 'ai.tagging'),
      TextField(controller: signature).afford('Signature', key: 'ai.signature'),
    ]),
  );
}

Widget _inbox() => Scaffold(
  body: Column(children: [
    ElevatedButton(onPressed: () {}, child: const Text('Compose')).afford('Compose', key: 'mail.compose'),
  ]),
);

void main() {
  testWidgets('peeks at a page built off screen, navigates there and acts by key in one round, goes back', (tester) async {
    final kit = AffordKit();
    final nav = GlobalKey<NavigatorState>();
    final history = ['/mail/inbox'];
    var previews = 0;
    Widget page(String route) => route.startsWith('/settings') ? const _AiPage() : _inbox();
    kit.routes = AffordRoutes(
      current: () => history.last,
      routes: const [
        RouteSpec('/mail/:folder', 'A mail folder', params: {'folder': RouteParam(values: ['inbox', 'sent'])}),
        RouteSpec('/settings/:tab', 'A settings page', params: {'tab': RouteParam(values: ['general', 'ai'])}),
      ],
      navigate: (route) async {
        history.add(route);
        nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => page(route)));
      },
      back: () async {
        history.removeLast();
        nav.currentState!.pop();
      },
      canGoBack: () => history.length > 1,
      // Wait out the page transition
      settle: () => Future<void>.delayed(const Duration(milliseconds: 400)),
      preview: (route) {
        previews++;
        return page(route);
      },
    );
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: (context, child) => AffordScope(kit: kit, child: AffordPreviewHost(kit: kit, child: child!)),
      home: _inbox(),
    ));

    final ctx = kit.context();
    expect(ctx.route!.toJson(), containsPair('pattern', '/mail/:folder'));
    expect(ctx.route!.params, {'folder': 'inbox'});
    expect(ctx.route!.canGoBack, false);
    expect(all(ctx.root).map((n) => n.key), contains('mail.compose'));

    // The settings page, built off screen: its controls and keys, ids not live; the user's page untouched
    final peek = await drive(tester, kit.peek('/settings/ai'));
    expect(peek.source, PageSource.preview);
    expect(previews, 1);
    final keys = [for (final n in all(peek.root!)) ?n.key];
    expect(keys, ['ai.tagging', 'ai.signature']);
    expect(all(peek.root!).where((n) => n.key != null).every((n) => n.id.startsWith('peek:')), true);
    await tester.pump();
    expect(find.byType(Switch), findsNothing);
    expect(all(kit.context().root).map((n) => n.key), isNot(contains('ai.tagging')));

    // One round: go there, switch tagging on, write the signature
    final done = await drive(tester, kit.execute(const [
      NavigateCall('/settings/ai'),
      NodeCall('ai.tagging', 'set', {'on': true}),
      NodeCall('ai.signature', 'write', {'text': 'Momo'}),
    ]));
    expect([for (final r in done.results) r.error ?? 'ok'], ['ok', 'ok', 'ok']);
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Momo');
    expect(done.context.route!.current, '/settings/ai');
    expect(done.context.route!.canGoBack, true);

    // Peek ids are refused; unknown routes too; back goes back
    final refused = await drive(tester, kit.execute([NodeCall(all(peek.root!).firstWhere((n) => n.key == 'ai.tagging').id, 'read')]));
    expect(refused.results.single.error, contains('navigate to the page first'));
    final back = await drive(tester, kit.execute(const [NavigateCall('/nope'), NavigateCall('back')]));
    expect(back.results.first.error, contains('No route /nope'));
    expect(back.results.last.ok, true);
    expect(back.context.route!.current, '/mail/inbox');

    // What it saw is kept: as JSON for the next run, where a peek knows the settings page
    final next = AffordKit()..loadSnapshots(jsonDecode(jsonEncode(kit.snapshots())) as Map<String, Object?>);
    next.routes = AffordRoutes(current: () => '/mail/inbox', routes: kit.routes!.routes, navigate: (_) async {});
    final seen = await next.peek('/settings/ai');
    expect(seen.source, PageSource.seen);
    expect([for (final n in all(seen.root!)) ?n.key], ['ai.tagging', 'ai.signature']);
    expect((await next.peek('/settings/general')).source, PageSource.seen);
  });
}
