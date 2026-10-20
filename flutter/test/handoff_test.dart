import 'dart:convert';

import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// A mail app with an inbox and a drafts page: a draft opens when pressed; one draft may not be touched, one needs a yes.
Future<({AffordKit kit, List<String> history, List<String> opened})> app(
  WidgetTester tester,
) async {
  final kit = AffordKit();
  final nav = GlobalKey<NavigatorState>();
  final history = ['/mail/inbox'];
  final opened = <String>[];
  Widget draft(String id, String name, [Policy? policy]) => TextButton(
    onPressed: () => opened.add('draft.$id'),
    child: Text(name),
  ).afford(name, key: 'draft.$id', policy: policy);
  Widget drafts() => Scaffold(
    body: Column(
      children: [
        draft('7', 'Re: Lunch?'),
        draft('8', 'Re: Contract', Policy.deny),
        draft('9', 'Re: Invoice', Policy.confirm),
      ],
    ),
  );
  kit.routes = AffordRoutes(
    current: () => history.last,
    routes: const [
      RouteSpec('/mail/:folder', 'A mail folder'),
      RouteSpec('/drafts', 'The drafts'),
    ],
    navigate: (route) async {
      history.add(route);
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => drafts()));
    },
    settle: () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      builder: (context, child) => AffordScope(kit: kit, child: child!),
      home: Scaffold(
        body: ElevatedButton(
          onPressed: () {},
          child: const Text('Compose'),
        ).afford('Compose', key: 'mail.compose'),
      ),
    ),
  );
  return (kit: kit, history: history, opened: opened);
}

const good = Handoff(
  message: '回复写好了，在草稿箱',
  route: '/drafts',
  calls: [HandoffCall('draft.7', 'press')],
);

void main() {
  test("handoffs checked: a good one (calls by key, ui_act's node too); not ids, too many calls, no message, expired", () {
    final json = {
      'v': 1,
      'message': '回复写好了，在草稿箱',
      'route': '/drafts',
      'calls': [
        {'key': 'draft.7', 'op': 'press'},
      ],
    };
    expect(parseHandoff(json)!.toJson(), json);
    expect(good.toJson(), json);
    final byNode = parseHandoff({
      'message': ' Done ',
      'calls': [
        {
          'node': 'mail.list[42].reply',
          'op': 'write',
          'args': {'text': 'hi'},
        },
      ],
    })!;
    expect(byNode.message, 'Done');
    expect(byNode.calls.single.toCall().toJson(), {
      'node': 'mail.list[42].reply',
      'op': 'write',
      'args': {'text': 'hi'},
    });
    for (final id in ['n12', 'w4', 'p3', 'app', 'behind-2', 'peek:w1']) {
      final input = {
        'message': 'x',
        'calls': [
          {'key': id, 'op': 'press'},
        ],
      };
      expect(parseHandoff(input), isNull);
      expect(handoffProblem(input), contains("use the control's key"));
    }
    final many = [
      for (var i = 0; i < 21; i++) {'key': 'draft.$i', 'op': 'press'},
    ];
    expect(
      handoffProblem({'message': 'x', 'calls': many}),
      contains('Too many calls'),
    );
    expect(
      parseHandoff({'message': 'x', 'calls': many.take(20).toList()}),
      isNotNull,
    );
    expect(parseHandoff({'route': '/drafts'}), isNull);
    expect(parseHandoff({'message': '   '}), isNull);
    expect(handoffProblem({'message': 'x' * 501}), contains('too long'));
    expect(parseHandoff({'message': 'x', 'route': 'back'}), isNull);
    expect(
      parseHandoff({
        'message': 'x',
        'calls': [
          {'key': 'a', 'op': 'press', 'args': <Object?>[]},
        ],
      }),
      isNull,
    );
    expect(parseHandoff({'v': 2, 'message': 'x'}), isNull);
    expect(parseHandoff('{"message":"x"}'), isNull);
    // Expired: not a handoff any more
    final at = DateTime.fromMillisecondsSinceEpoch(2000);
    expect(parseHandoff({...json, 'expiresAt': 1000}, now: at), isNull);
    expect(
      parseHandoff({...json, 'expiresAt': 3000}, now: at)!.expiresAt,
      DateTime.fromMillisecondsSinceEpoch(3000),
    );
    expect(
      Handoff(
        message: 'x',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ).isExpired(at),
      true,
    );
    expect(const Handoff(message: 'x').isExpired(at), false);
  });

  testWidgets(
    'while the user is away the screen tools answer code away at once (the app\'s lifecycle in kit.agent())',
    (tester) async {
      var asked = 0;
      var present = false;
      final ui = AffordAgent(
        send: (r) async => {'error': 'unexpected ${jsonEncode(r)}'},
        present: () {
          asked++;
          return present;
        },
      );
      for (final (name, input) in [
        ('ui_look', <String, Object?>{}),
        ('ui_act', <String, Object?>{'node': 'reply', 'op': 'press'}),
        ('ui_navigate', <String, Object?>{'route': '/drafts'}),
        ('ui_peek', <String, Object?>{'route': '/drafts'}),
        ('ui_tool', <String, Object?>{'name': 'refresh'}),
      ]) {
        final a = await ui.handle(name, input);
        expect([a.isError, a.code], [true, ErrorCode.away]);
        expect(a.text, contains('not in the app right now'));
      }
      expect(asked, 5);
      expect((await ui.handle('ui_fly')).code, ErrorCode.badArgs);
      present = true;
      expect((await ui.handle('ui_look')).code, ErrorCode.unavailable);

      // In the app: the app's lifecycle says
      final (:kit, history: _, opened: _) = await app(tester);
      final inApp = kit.agent();
      expect((await drive(tester, inApp.handle('ui_look'))).isError, false);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      expect((await inApp.handle('ui_look')).code, ErrorCode.away);
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      expect((await drive(tester, inApp.handle('ui_look'))).isError, false);
    },
  );

  testWidgets(
    'ui_handoff: offered only with onHandoff, checked, given to the host, what the host said told the agent',
    (tester) async {
      final (:kit, history: _, opened: _) = await app(tester);
      expect(
        kit.agent().tools().map((t) => t.name),
        isNot(contains('ui_handoff')),
      );
      expect(
        (await kit.agent().handle('ui_handoff', {'message': 'x'})).code,
        ErrorCode.notFound,
      );
      expect(
        AffordAgent(
          send: kit.answer,
          only: const ['ui_look', 'ui_handoff'],
        ).tools().map((t) => t.name),
        ['ui_look'],
      );

      final left = <Handoff>[];
      var away = false;
      final ui = kit.agent(
        present: () => !away,
        onHandoff: (h) async {
          left.add(h.withId('h1'));
          return 'notification sent';
        },
      );
      expect(ui.tools().last.name, 'ui_handoff');
      expect(anthropicTools(ui.tools()).last['name'], 'ui_handoff');
      expect(
        (openaiTools(ui.tools()).last['function'] as Map)['name'],
        'ui_handoff',
      );
      expect(
        (mcpToolList(ui)['tools'] as List).map((t) => (t as Map)['name']),
        contains('ui_handoff'),
      );
      await drive(tester, ui.handle('ui_look'));

      away = true;
      expect(
        (await ui.handle('ui_look')).text,
        contains('leave a handoff (ui_handoff)'),
      );
      final bad = await ui.handle('ui_handoff', {
        'message': 'Done',
        'calls': [
          {'key': 'w12', 'op': 'press'},
        ],
      });
      expect([bad.isError, bad.code], [true, ErrorCode.badArgs]);
      expect(
        (await ui.handle('ui_handoff', {
          'message': 'Done',
          'route': '/nowhere',
        })).text,
        contains('No route /nowhere'),
      );
      expect(left, isEmpty);

      final before = DateTime.now();
      final ok = await ui.handle('ui_handoff', {
        'message': '回复写好了，在草稿箱',
        'route': '/drafts',
        'calls': [
          {'key': 'draft.7', 'op': 'press'},
        ],
        'expiresAt': 1,
        'id': 'mine',
      });
      expect([ok.text, ok.isError], ['Handoff left: notification sent', false]);
      expect(left.single.toJson(), {
        ...good.toJson(),
        'expiresAt': left.single.expiresAt!.millisecondsSinceEpoch,
        'id': 'h1',
      });
      // (its expiry the agent side's, a day on by default)
      expect(
        left.single.expiresAt!.difference(before).inMinutes,
        greaterThanOrEqualTo(24 * 60 - 1),
      );

      final quiet = AffordAgent(send: kit.answer, onHandoff: (_) => null);
      expect(
        (await quiet.handle('ui_handoff', {'message': 'Done'})).text,
        'Handoff left: the user gets it when they come back.',
      );
    },
  );

  testWidgets(
    'runHandoff: goes to its route and presses a keyed node there, each step through onAct',
    (tester) async {
      final (:kit, :history, :opened) = await app(tester);
      final acts = <String>[];
      kit.onAct = (e) async => acts.add('${e.node.key} ${e.op}');
      final r = await drive(
        tester,
        kit.runHandoff(
          Handoff(
            message: good.message,
            route: good.route,
            calls: good.calls,
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
            id: 'h1',
          ),
        ),
      );
      expect([r.ok, r.ran, r.code], [true, 1, null]);
      expect([for (final x in r.results) x.ok], [true, true]);
      expect(history.last, '/drafts');
      expect(opened, ['draft.7']);
      expect(acts, ['draft.7 press']);
    },
  );

  testWidgets(
    'runHandoff: stops with not_found at a key that is not there, never runs a denied node',
    (tester) async {
      final (:kit, history: _, :opened) = await app(tester);
      final missing = await drive(
        tester,
        kit.runHandoff(
          const Handoff(
            message: 'x',
            route: '/drafts',
            calls: [
              HandoffCall('draft.6', 'press'),
              HandoffCall('draft.7', 'press'),
            ],
          ),
        ),
      );
      expect(
        [missing.ok, missing.ran, missing.stoppedAt, missing.code],
        [false, 0, 0, ErrorCode.notFound],
      );
      expect(opened, isEmpty);
      final denied = await drive(
        tester,
        kit.runHandoff(
          const Handoff(
            message: 'x',
            calls: [
              HandoffCall('draft.7', 'press'),
              HandoffCall('draft.8', 'press'),
            ],
          ),
        ),
      );
      expect(
        [denied.ok, denied.ran, denied.stoppedAt, denied.code],
        [false, 1, 1, ErrorCode.denied],
      );
      expect(opened, ['draft.7']);
    },
  );

  testWidgets(
    'runHandoff: asks before a confirm node (declined: stops), not run without a way to ask',
    (tester) async {
      final (:kit, history: _, :opened) = await app(tester);
      const h = Handoff(
        message: 'x',
        route: '/drafts',
        calls: [HandoffCall('draft.9', 'press')],
      );
      final none = await drive(tester, kit.runHandoff(h));
      expect(
        [none.ok, none.code, none.stoppedAt],
        [false, ErrorCode.needsConfirm, 0],
      );
      var asked = 0;
      final no = await drive(
        tester,
        kit.runHandoff(
          h,
          confirm: (call, {node, tool}) async {
            asked++;
            return false;
          },
        ),
      );
      expect(
        [no.ok, no.code, no.ran, asked],
        [false, ErrorCode.declined, 0, 1],
      );
      expect(opened, isEmpty);
      final yes = await drive(
        tester,
        kit.runHandoff(h, confirm: (call, {node, tool}) async => true),
      );
      expect([yes.ok, yes.ran], [true, 1]);
      expect(opened, ['draft.9']);
      // (the kit's own confirm, when the handoff gives none)
      kit.confirm = (call, {node, tool}) async => false;
      expect((await drive(tester, kit.runHandoff(h))).code, ErrorCode.declined);
    },
  );

  testWidgets(
    'runHandoff: refuses an expired one, and one that is not a handoff',
    (tester) async {
      final (:kit, :history, :opened) = await app(tester);
      final old = await drive(
        tester,
        kit.runHandoff(
          Handoff(
            message: good.message,
            route: good.route,
            calls: good.calls,
            expiresAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ),
      );
      expect(
        [old.ok, old.ran, old.stoppedAt, old.code, old.results],
        [false, 0, -1, ErrorCode.expired, isEmpty],
      );
      final ids = await drive(
        tester,
        kit.runHandoff(
          const Handoff(message: 'x', calls: [HandoffCall('w1', 'press')]),
        ),
      );
      expect([ids.ok, ids.code], [false, ErrorCode.badArgs]);
      final nowhere = await drive(
        tester,
        kit.runHandoff(const Handoff(message: 'x', route: '/nowhere')),
      );
      expect(
        [nowhere.ok, nowhere.code, nowhere.stoppedAt],
        [false, ErrorCode.notFound, -1],
      );
      expect(history, ['/mail/inbox']);
      expect(opened, isEmpty);
    },
  );
}
