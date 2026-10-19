import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<AffordNode> all(AffordNode n) => [n, for (final c in n.children) ...all(c)];
AffordNode find(AffordNode root, String name) => all(root).firstWhere((n) => n.name == name);

void main() {
  late AffordKit kit;
  late TextEditingController body;
  late int later, sent;
  late bool notify;
  late String typed;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              Row(children: [
                ElevatedButton(onPressed: () => sent++, child: const Text('Send')).afford('Send', policy: Policy.deny, kit: kit),
                TextButton(onPressed: () => later++, child: const Text('Later')).afford('Later', kit: kit),
              ]),
              TextField(controller: body, onChanged: (t) => typed = t).afford('Body', kit: kit),
              Switch(value: notify, onChanged: (v) => setState(() => notify = v)).afford('Notify me', kit: kit),
              const TextField(obscureText: true).afford('Password', kit: kit),
            ]).afford('Compose', description: 'Writing a mail', kit: kit),
          ),
        ),
      ),
    ));
  }

  setUp(() {
    kit = AffordKit();
    body = TextEditingController(text: 'Hi Wang,\nsee you Tuesday.');
    later = 0;
    sent = 0;
    notify = false;
    typed = '';
  });

  testWidgets('builds the tree: afforded widgets under their afforded ancestor, in reading order, ops from what they are', (tester) async {
    await pump(tester);
    final ctx = kit.context();
    final compose = ctx.root.children.single;
    expect(compose.name, 'Compose');
    expect(compose.description, 'Writing a mail');
    expect([for (final n in compose.children) [n.role.wire, n.name]], [
      ['button', 'Send'],
      ['button', 'Later'],
      ['textbox', 'Body'],
      ['switch', 'Notify me'],
      ['textbox', 'Password'],
    ]);
    expect(find(ctx.root, 'Send').ops.map((o) => o.toJson()).toList(), [
      {'name': 'press', 'policy': 'deny'},
    ]);
    expect(find(ctx.root, 'Body').state, {'length': 25});
    expect(find(ctx.root, 'Notify me').state, {'checked': false});
    expect(find(ctx.root, 'Password').ops.every((o) => o.policy == Policy.deny), true);
    // Content is read on demand, never sent with the tree
    expect('${ctx.toJson()}', isNot(contains('see you Tuesday')));
  });

  testWidgets('runs the calls: reads, types, taps, refuses what is denied, returns the next context', (tester) async {
    await pump(tester);
    final ctx = kit.context();
    String id(String name) => find(ctx.root, name).id;
    final res = await tester.runAsync(() => kit.execute([
          NodeCall(id('Body'), 'read'),
          NodeCall(id('Body'), 'write', {'text': 'Hi Wang, Tuesday works for me.'}),
          NodeCall(id('Later'), 'press'),
          NodeCall(id('Send'), 'press'),
          NodeCall(id('Notify me'), 'set', {'on': true}),
          NodeCall(id('Password'), 'read'),
          Call.fromJson({'node': id('Later'), 'op': 'fly'}),
        ]));
    await tester.pump();
    final r = res!.results;
    expect([for (final x in r) x.ok], [true, true, true, false, true, false, false]);
    expect(r[0].value, 'Hi Wang,\nsee you Tuesday.');
    expect(body.text, 'Hi Wang, Tuesday works for me.');
    expect(typed, 'Hi Wang, Tuesday works for me.');
    expect(later, 1);
    expect(sent, 0);
    expect(r[3].error, contains('user does this themselves'));
    expect(notify, true);
    expect(r[6].error, contains('has no op fly'));
    expect(find(kit.context().root, 'Notify me').state, {'checked': true});
  });

  testWidgets('asks before confirm ops, offers tools and routes', (tester) async {
    var asked = 0;
    kit.confirm = (call, {node, tool}) async {
      asked++;
      return false;
    };
    var route = '/mail/inbox';
    kit.routes = AffordRoutes(current: () => route, routes: const [RouteSpec('/settings/:tab', 'A settings page')], navigate: (r) async => route = r);
    kit.registerTool(AffordTool('insert_at_cursor', 'Insert text where the cursor is', execute: (a) async => 'inserted ${a['text']}'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TextButton(onPressed: () => later++, child: const Text('x')).afford('Archive', policy: Policy.confirm, kit: kit)),
    ));
    final ctx = kit.context();
    expect(ctx.toJson()['route'], {
      'current': '/mail/inbox',
      'routes': [
        {'path': '/settings/:tab', 'description': 'A settings page'},
      ],
    });
    final res = await tester.runAsync(() => kit.execute([
          NodeCall(find(ctx.root, 'Archive').id, 'press'),
          const ToolCall('insert_at_cursor', {'text': 'hi'}),
          const NavigateCall('/settings/ai'),
        ]));
    expect(asked, 1);
    expect(later, 0);
    expect([for (final x in res!.results) [x.ok, x.value ?? x.error]], [
      [false, 'The user said no'],
      [true, 'inserted hi'],
      [true, '/settings/ai'],
    ]);
    expect(res.context.currentRoute, '/settings/ai');
  });

  testWidgets('shows each op before it runs (onAct) and types text in a bit at a time', (tester) async {
    final seen = <String>[];
    final steps = <String>[];
    kit
      ..onAct = ((e) async => seen.add('${e.op} ${e.node.name} ${e.rect != null}'))
      ..typeDelay = const Duration(milliseconds: 100);
    body.addListener(() => steps.add(body.text));
    await pump(tester);
    final ctx = kit.context();
    String id(String name) => find(ctx.root, name).id;
    final res = await tester.runAsync(() => kit.execute([
          NodeCall(id('Body'), 'read'),
          NodeCall(id('Later'), 'press'),
          NodeCall(id('Body'), 'write', {'text': 'Tuesday works for me, see you then!'}),
        ]));
    expect([for (final r in res!.results) r.ok], [true, true, true]);
    // (not for reads)
    expect(seen, ['press Later true', 'write Body true']);
    expect(body.text, 'Tuesday works for me, see you then!');
    expect(steps.length, greaterThan(5));
    expect(steps.first.length, lessThan(10));
  });
}
