import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The future done, pumping frames (and fake time) while it runs.
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
  late AffordKit kit;
  late TextEditingController body;
  late int later;
  late bool notify;
  late String route;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => later++,
                  child: const Text('Later'),
                ).afford('Later', key: 'later', kit: kit),
                TextButton(
                  onPressed: () => setState(() => route = '/settings'),
                  child: const Text('Settings'),
                ).afford('Settings', kit: kit),
                TextField(controller: body).afford('Body', kit: kit),
                Switch(
                  value: notify,
                  onChanged: (v) => setState(() => notify = v),
                ).afford('Notify me', kit: kit),
                const TextField(obscureText: true).afford('Password', kit: kit),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<List<Object?>?> look() async =>
      (await kit.answer({'look': true}))['userActions'] as List<Object?>?;

  setUp(() {
    kit = AffordKit();
    body = TextEditingController();
    later = 0;
    notify = false;
    route = '/mail';
    kit.routes = AffordRoutes(
      current: () => route,
      routes: const [
        RouteSpec('/mail', 'Mail'),
        RouteSpec('/settings', 'Settings'),
      ],
      navigate: (r) async => route = r,
    );
  });

  tearDown(() => kit.watchUser(false));

  testWidgets(
    'what the user taps and types while watched goes in the next answer, then is gone',
    (tester) async {
      await pump(tester);
      kit.watchUser(true);
      await tester.tap(find.text('Later'));
      await tester.enterText(find.byType(TextField).first, 'Tues');
      await tester.enterText(find.byType(TextField).first, 'Tuesday works');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(later, 1);
      final acts = await look();
      expect(
        [
          for (final a in acts!.cast<Map>())
            {...a}
              ..remove('at')
              ..remove('node'),
        ],
        [
          {'op': 'press', 'route': '/mail'},
          // (one per field per burst: what it says after)
          {'op': 'write', 'value': 'Tuesday works', 'route': '/mail'},
          {'op': 'toggle', 'value': 'on', 'route': '/mail'},
        ],
      );
      expect((acts.first as Map)['node'], {
        'id': kit.context().root.children.first.id,
        'key': 'later',
        'role': 'button',
        'name': 'Later',
      });
      expect((acts.first as Map)['at'], isA<int>());
      // Taken: the next answer has none
      expect(await look(), isNull);
    },
  );

  testWidgets('a tap that changes the page says where it led', (tester) async {
    await pump(tester);
    kit.watchUser(true);
    await tester.tap(find.text('Settings'));
    await tester.pump();
    final acts = (await look())!.cast<Map>();
    expect(acts.length, 1);
    expect(acts.single['op'], 'press');
    expect(acts.single['route'], '/settings');
  });

  testWidgets('the kit\'s own calls are not noted', (tester) async {
    await pump(tester);
    kit.watchUser(true);
    final root = kit.context().root;
    String id(String name) =>
        root.children.firstWhere((n) => n.name == name).id;
    final answer = await drive(
      tester,
      kit.answer({
        'calls': [
          {'node': id('Later'), 'op': 'press'},
          {
            'node': id('Body'),
            'op': 'write',
            'args': {'text': 'from the agent'},
          },
          {'node': id('Notify me'), 'op': 'toggle'},
          {'navigate': '/settings'},
        ],
      }),
    );
    // (and what they set off a moment after)
    await tester.pump(const Duration(milliseconds: 400));
    expect(later, 1);
    expect(body.text, 'from the agent');
    expect(notify, true);
    expect(answer['userActions'], isNull);
    expect(await look(), isNull);
  });

  testWidgets('nothing is noted while not watched', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Later'));
    await tester.enterText(find.byType(TextField).first, 'hello');
    kit.watchUser(true);
    expect(await look(), isNull);
    // Off forgets what wasn't taken
    await tester.tap(find.text('Later'));
    kit.watchUser(false);
    kit.watchUser(true);
    expect(await look(), isNull);
  });

  testWidgets('a password\'s text is never in it', (tester) async {
    await pump(tester);
    kit.watchUser(true);
    await tester.enterText(find.byType(TextField).last, 'hunter2');
    final acts = (await look())!.cast<Map>();
    expect(acts.single['op'], 'write');
    expect((acts.single['node'] as Map)['name'], 'Password');
    expect(acts.single.containsKey('value'), false);
    expect('$acts', isNot(contains('hunter2')));
  });

  test('UserAction JSON both ways', () {
    final j = {
      'at': 1792711772948,
      'op': 'press',
      'node': {
        'id': 'w9',
        'key': 'mail.list[42]',
        'role': 'listitem',
        'name': 'Lunch on Tuesday?',
      },
      'route': '/message/42',
    };
    expect(UserAction.fromJson(j).toJson(), j);
    expect(
      describeUserActions([j]),
      contains('- pressed [mail.list[42]] listitem "Lunch on Tuesday?"'),
    );
    expect(describeUserActions(const []), '');
  });
}
