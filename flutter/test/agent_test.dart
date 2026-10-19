import 'dart:async';
import 'dart:convert';

import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  testWidgets('the agent side: looks, acts, answers with what changed (not the whole tree), errors with a code; the stacks\' shapes', (tester) async {
    final kit = AffordKit();
    var replying = false;
    var sent = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Column(children: [
            TextButton(onPressed: () => setState(() => replying = true), child: const Text('Reply')).afford('Reply', key: 'reply', kit: kit),
            ElevatedButton(onPressed: () => sent++, child: const Text('Send')).afford('Send', key: 'send', policy: Policy.deny, kit: kit),
            if (replying) const TextField().afford('Body', key: 'body', kit: kit),
          ]),
        ),
      ),
    ));
    // (over a "transport": JSON both ways)
    final requests = <Map<String, Object?>>[];
    final ui = AffordAgent(send: (r) async {
      requests.add(r);
      return (jsonDecode(jsonEncode(await kit.answer(jsonDecode(jsonEncode(r)) as Map<String, Object?>))) as Map).cast<String, Object?>();
    });
    expect(ui.tools().map((t) => t.name), ['ui_look', 'ui_act', 'ui_tool', 'ui_navigate', 'ui_peek']);

    final look = await drive(tester, ui.handle('ui_look'));
    expect(look.isError, false);
    expect(look.text, contains('key=reply] button "Reply" — press'));
    expect(ui.has('ui_tool'), false); // (the app has no tools of its own)

    final reply = await drive(tester, ui.handle('ui_act', {'node': 'reply', 'op': 'press'}));
    expect(reply.isError, false);
    expect(reply.text, matches(RegExp(r'^Done\.\n\nThe screen changed:\n\+ \[\S+ key=body\] textbox "Body"')));
    expect(reply.text, isNot(contains('"Send"')));
    final typed = await drive(tester, ui.handle('ui_act', {'node': 'body', 'op': 'write', 'args': {'text': 'Hi'}}));
    expect(typed.text, contains('~ ['));

    final send = await drive(tester, ui.handle('ui_act', {'node': 'send', 'op': 'press'}));
    expect([send.isError, send.code], [true, ErrorCode.denied]);
    expect(send.text, startsWith('Failed (denied)'));
    expect(sent, 0);
    expect((await drive(tester, ui.handle('ui_act', {'node': 'nope', 'op': 'press'}))).code, ErrorCode.notFound);
    expect((await drive(tester, ui.handle('ui_act', {'node': 'reply', 'op': 'fly'}))).code, ErrorCode.noOp);
    expect((await ui.handle('ui_fly')).code, ErrorCode.badArgs);
    expect(requests, hasLength(6));

    // Straight on the kit; the whole screen when asked; a send that never answers
    final local = kit.agent(wholeScreen: true);
    expect((await drive(tester, local.handle('ui_act', {'node': 'reply', 'op': 'read'}))).text, contains('The screen now:'));
    final slow = AffordAgent(send: (_) => Completer<Map<String, Object?>>().future, timeout: const Duration(milliseconds: 100));
    expect((await drive(tester, slow.handle('ui_look'))).code, ErrorCode.timeout);

    // Each stack's shape
    expect(anthropicTools(ui.tools()).first, {'name': 'ui_look', 'description': agentTools.first.description, 'input_schema': agentTools.first.inputSchema});
    expect((openaiTools(ui.tools())[1]['function'] as Map)['name'], 'ui_act');
    final block = await drive(tester, anthropicResult(ui, {'id': 'tu1', 'name': 'ui_act', 'input': {'node': 'send', 'op': 'press'}}));
    expect([block['type'], block['tool_use_id'], block['is_error']], ['tool_result', 'tu1', true]);
    final msg = await drive(tester, openaiResult(ui, {'id': 'c1', 'function': {'name': 'ui_look', 'arguments': '{}'}}));
    expect(msg['content'], contains('Reply'));
    expect((mcpToolList(ui)['tools'] as List).length, 4);
    final called = await drive(tester, mcpToolCall(ui, 'ui_act', {'node': 'nope', 'op': 'press'}));
    expect(called['isError'], true);
  });
}
