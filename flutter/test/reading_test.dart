import 'dart:convert';

import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs [f] while pumping frames (and real time, for pictures), and gives its result.
Future<T> drive<T>(WidgetTester tester, Future<T> f) async {
  T? value;
  var done = false;
  f.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done, true, reason: 'did not finish');
  return value as T;
}

void main() {
  testWidgets('texts show their words, a field only its length; a dialog over the page is said in a line; pictures of a part and of the screen', (tester) async {
    final kit = AffordKit();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: (context, child) => AffordScope(kit: kit, child: AffordPreviewHost(kit: kit, child: child!)),
      home: Scaffold(
        body: Column(children: [
          const Text('3 new mails from Wang about the trip').afford('Summary', role: Role.text),
          Container(width: 40, height: 30, color: Colors.red).afford('Logo', key: 'logo', role: Role.image),
          TextField(controller: TextEditingController(text: 'secret draft')).afford('Body', key: 'body'),
          ElevatedButton(onPressed: () {}, child: const Text('Archive')).afford('Archive', key: 'archive'),
        ]),
      ),
    ));
    final ui = kit.agent();
    final look = await drive(tester, ui.handle('ui_look', {'picture': true}));
    expect(look.text, contains('text "Summary" = "3 new mails from Wang about the trip"'));
    expect(look.text, contains('textbox "Body" (length: 12)'));
    expect(look.text, isNot(contains('secret draft')));
    expect(look.text, contains('(A picture of the screen is attached.)'));
    expect(look.images.single.mime, 'image/png');
    expect(base64Decode(look.images.single.data).sublist(1, 4), utf8.encode('PNG'));

    final logo = await drive(tester, ui.handle('ui_act', {'node': 'logo', 'op': 'view'}));
    expect(logo.isError, false);
    expect(logo.text, startsWith('(A picture, 120×90 image/png: attached.)')); // (40×30 at the test's 3x)
    expect(logo.images, hasLength(1));

    showDialog<void>(context: nav.currentContext!, builder: (_) => AlertDialog(content: TextButton(onPressed: () {}, child: const Text('Sure?')).afford('Sure?', key: 'sure')));
    final opened = await drive(tester, ui.handle('ui_act', {'node': 'body', 'op': 'read'}));
    expect(opened.text, contains('key=sure] button "Sure?"'));
    expect(opened.text, contains('(behind) — now under what shows: its 4 controls still work, unseen'));
    expect(opened.text, isNot(contains('"Archive"')));
    // Under the dialog, a picture of it would be of the dialog: refused
    final hidden = await drive(tester, ui.handle('ui_act', {'node': 'logo', 'op': 'view'}));
    expect(hidden.code, ErrorCode.unreachable);
  });
}
