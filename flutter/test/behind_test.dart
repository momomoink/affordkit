import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<AffordNode> all(AffordNode n) => [n, for (final c in n.children) ...all(c)];
/// Runs [f] while pumping frames, and gives its result.
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

void main() {
  testWidgets('a page under the one on top is in the tree, behind; its controls work by their callbacks, unseen', (tester) async {
    final kit = AffordKit();
    final nav = GlobalKey<NavigatorState>();
    final acts = <ActEvent>[];
    final pressed = <String>[];
    var notify = false;
    var route = '/inbox';
    kit
      ..onAct = ((e) async => acts.add(e))
      ..routes = AffordRoutes(current: () => route, routes: const [RouteSpec('/inbox', 'Inbox'), RouteSpec('/mail', 'A mail')], navigate: (_) async {});
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Column(children: [
            ElevatedButton(onPressed: () => pressed.add('archive'), child: const Text('Archive')).afford('Archive', key: 'archive', kit: kit),
            Switch(value: notify, onChanged: (v) => setState(() => notify = v)).afford('Notify', key: 'notify', kit: kit),
          ]),
        ),
      ),
    ));
    expect([for (final n in kit.context().root.children) n.key], ['archive', 'notify']);

    route = '/mail';
    nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: TextButton(onPressed: () => pressed.add('reply'), child: const Text('Reply')).afford('Reply', key: 'reply', kit: kit)),
    ));
    await tester.pumpAndSettle();
    final root = kit.context().root;
    // The page on top, then the one under it (named by its route when it was on top)
    expect([for (final n in root.children) n.key ?? n.name], ['reply', '/inbox']);
    final under = root.children.last;
    expect([under.role, under.state], [Role.page, {'behind': true}]);
    expect([for (final n in under.children) n.key], ['archive', 'notify']);

    final res = await drive(tester, kit.execute(const [NodeCall('reply', 'press'), NodeCall('archive', 'press'), NodeCall('notify', 'set', {'on': true})]));
    await tester.pumpAndSettle();
    expect([for (final r in res.results) r.error ?? 'ok'], ['ok', 'ok', 'ok']);
    expect(pressed, ['reply', 'archive']);
    expect(notify, true);
    // Reply tapped where it shows; the two behind, with no place to show a tap
    expect([for (final a in acts) [a.node.key, a.behind, a.rect != null]], [
      ['reply', false, true],
      ['archive', true, false],
      ['notify', true, false],
    ]);

    // A dialog over it all: the page under it is behind too
    showDialog<void>(
      context: nav.currentContext!,
      builder: (_) => AlertDialog(content: TextButton(onPressed: () => pressed.add('ok'), child: const Text('Ok')).afford('Ok', key: 'ok', kit: kit)),
    );
    await tester.pumpAndSettle();
    final withDialog = kit.context().root;
    expect([for (final n in withDialog.children) n.key ?? n.name], ['ok', '/mail', '/inbox']);
    await drive(tester, kit.execute(const [NodeCall('reply', 'press')]));
    expect(pressed.last, 'reply');
    // (and the dialog is still open: the tap didn't land on its barrier)
    expect(find.text('Ok'), findsOneWidget);
  });
}
