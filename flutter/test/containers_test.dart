import 'dart:convert';

import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<AffordNode> all(AffordNode n) => [n, for (final c in n.children) ...all(c)];
AffordNode? byKey(AffordNode root, String key) => all(root).where((n) => n.key == key).firstOrNull;

/// Runs [f] while pumping frames (scrolling and taps rebuild), and gives its result.
Future<T> drive<T>(WidgetTester tester, Future<T> f, {int frames = 200}) async {
  T? value;
  var done = false;
  f.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < frames && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done, true, reason: 'did not finish');
  return value as T;
}

/// A mail row: opens on tap, with a star and a reply button.
Widget row(int i, List<String> opened, List<String> starred, List<String> replied) => ListTile(
  title: Text('Mail $i'),
  onTap: () => opened.add('m$i'),
  trailing: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(icon: const Icon(Icons.star_border), onPressed: () => starred.add('m$i')).afford('Star', key: 'star'),
      IconButton(icon: const Icon(Icons.reply), onPressed: () => replied.add('m$i')).afford('Reply', key: 'reply'),
    ],
  ),
).affordItem('m$i', index: i);

void main() {
  testWidgets('a ListView.builder is one container node; fetching an entry gives its tree, acted on next round', (tester) async {
    final kit = AffordKit();
    final opened = <String>[], starred = <String>[], replied = <String>[];
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AffordScope(kit: kit, child: AffordPreviewHost(kit: kit, child: child!)),
      home: Scaffold(
        body: ListView.builder(
          itemCount: 1000,
          itemExtent: 50,
          itemBuilder: (context, i) => row(i, opened, starred, replied),
        ).affordContainer(
          'Inbox',
          key: 'mail.list',
          kind: 'list',
          count: () => 1000,
          items: (offset, limit, query) => [
            for (var i = 0; i < 1000; i++)
              if (query == null || 'Mail $i'.contains(query)) ItemSummary(id: 'm$i', name: 'Mail $i'),
          ].skip(offset).take(limit).toList(),
          indexOf: (id) => int.tryParse(id.substring(1)),
          itemExtent: 50,
          build: (target) => target.id == 'm999' ? row(999, opened, starred, replied) : null,
        ),
      ),
    ));

    final ctx = kit.context();
    final list = byKey(ctx.root, 'mail.list')!;
    expect(list.role, Role.container);
    expect(list.state, {'kind': 'list', 'count': 1000, 'first': 0, 'last': 11}); // (600 px high, 50 px rows: 12 show)
    // Not the rows' controls: a preview of them
    expect(list.children, isEmpty);
    expect(byKey(ctx.root, 'mail.list[m3].reply'), isNull);
    expect(list.preview, hasLength(10));
    expect(list.preview[3].toJson(), {'key': 'mail.list[m3]', 'id': 'm3', 'index': 3, 'name': 'Mail 3'});
    expect(jsonEncode(ctx.toJson()), contains('"preview"'));

    // Round 1: fetch entry 42 (not on screen: scrolled to) — a tree of its own
    final first = await drive(tester, kit.execute(const [NodeCall('mail.list', 'item', {'id': 'm42'})]));
    expect(first.results.single.error, isNull);
    final item = first.results.single.value as ItemTree;
    expect([item.key, item.id, item.index, item.source], ['mail.list[m42]', 'm42', 42, ItemSource.live]);
    expect(item.root.role, Role.listitem);
    expect([for (final n in all(item.root)) n.key], ['mail.list[m42]', 'mail.list[m42].star', 'mail.list[m42].reply']);
    final reply = byKey(item.root, 'mail.list[m42].reply')!;
    expect(first.results.single.toJson()['value'], containsPair('source', 'live'));
    expect(byKey(first.context.root, 'mail.list[m42].reply'), isNull); // (the next round's tree: still the container alone)

    // Round 2: press its reply by the id the fetch gave
    final second = await drive(tester, kit.execute([NodeCall(reply.id, 'press')]));
    expect(second.results.single.error, isNull);
    expect(replied, ['m42']);

    // By index, by query, keys acted on straight away (fetched first), paging, and errors
    final res = await drive(tester, kit.execute(const [
      NodeCall('mail.list', 'item', {'index': 7}),
      NodeCall('mail.list', 'item', {'query': 'Mail 123'}),
      NodeCall('mail.list[m500].star', 'press'),
      NodeCall('mail.list[m501]', 'press'),
      NodeCall('mail.list', 'items', {'offset': 995, 'limit': 20}),
      NodeCall('mail.list', 'item', {}),
    ]));
    expect([for (final r in res.results) r.error ?? 'ok'], ['ok', 'ok', 'ok', 'ok', 'ok', 'Say which entry: id, index or query']);
    expect((res.results[0].value as ItemTree).key, 'mail.list[m7]');
    expect((res.results[1].value as ItemTree).key, 'mail.list[m123]');
    expect(starred, ['m500']);
    expect(opened, ['m501']);
    final page = res.results[4].value as ItemsPage;
    expect([for (final i in page.items) i.key], [for (var i = 995; i < 1000; i++) 'mail.list[m$i]']);

    // Built off screen for a preview: ids not live, keys as they would be
    final peek = await drive(tester, kit.execute(const [NodeCall('mail.list', 'item', {'id': 'm999', 'preview': true})]));
    final p = peek.results.single.value as ItemTree;
    expect(p.source, ItemSource.preview);
    expect([for (final n in all(p.root)) n.key], ['mail.list[m999]', 'mail.list[m999].star', 'mail.list[m999].reply']);
    expect(all(p.root).every((n) => n.id.startsWith('peek:')), true);

    // Scrolling: to an index, and by pages
    await drive(tester, kit.execute(const [NodeCall('mail.list', 'scroll_to', {'index': 42})]));
    final before = byKey(kit.context().root, 'mail.list')!.state!['first'] as int;
    expect(before, lessThanOrEqualTo(42));
    await drive(tester, kit.execute(const [NodeCall('mail.list', 'scroll', {'by': 1})]));
    expect(byKey(kit.context().root, 'mail.list')!.state!['first'], before + 12);
  });

  testWidgets('a short container: its entries are what is built; a nested container in an entry; an entry not built and no way there is an error', (tester) async {
    final kit = AffordKit();
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: AffordScope(
        kit: kit,
        child: Scaffold(
          body: ListView(children: [
            TextButton(onPressed: () {}, child: const Text('Show older')).afford('Show older', key: 'older'),
            for (final f in ['Wang', 'Li'])
              Column(children: [
                Text('From $f'),
                Column(children: [
                  TextButton(onPressed: () => opened.add('$f/plan.pdf'), child: const Text('plan.pdf')).afford('Open', key: 'open').affordItem('plan'),
                ]).affordContainer('Files', key: 'files'),
              ]).affordItem(f.toLowerCase(), name: 'From $f'),
          ]).affordContainer('Thread', key: 'thread', kind: 'thread'),
        ),
      ),
    ));
    final thread = byKey(kit.context().root, 'thread')!;
    expect(thread.state, {'kind': 'thread', 'count': 2, 'first': 0, 'last': 1});
    expect([for (final n in thread.children) n.key], ['older']); // (what is in it besides its entries)
    expect([for (final p in thread.preview) p.key], ['thread[wang]', 'thread[li]']);

    final res = await drive(tester, kit.execute(const [
      NodeCall('thread', 'item', {'id': 'thread[li]'}),
      NodeCall('thread[li].files[plan].open', 'press'),
      NodeCall('thread', 'items', {'query': 'wan'}),
      NodeCall('thread[zhao]', 'press'),
    ]));
    expect([for (final r in res.results.take(3)) r.error ?? 'ok'], ['ok', 'ok', 'ok']);
    final li = (res.results[0].value as ItemTree).root;
    expect([for (final n in all(li)) [n.role, n.key]], [
      [Role.listitem, 'thread[li]'],
      [Role.container, 'thread[li].files'],
    ]);
    expect(byKey(li, 'thread[li].files')!.preview.single.key, 'thread[li].files[plan]');
    expect(opened, ['Li/plan.pdf']);
    expect([for (final i in (res.results[2].value as ItemsPage).items) i.toJson()], [
      {'key': 'thread[wang]', 'id': 'wang', 'index': 0, 'name': 'From Wang'},
    ]);
    expect(res.results.last.ok, false);
  });

  // A plain container: no count, items, scrollTo or itemExtent — the kit finds its entries itself
  Future<(AffordKit, List<String>)> plain(WidgetTester tester, {required bool host}) async {
    final kit = AffordKit();
    final opened = <String>[];
    const senders = ['Wang', 'Li', 'Zhao', 'Chen'];
    Widget page() => Scaffold(
      body: ListView.builder(
        itemCount: 200,
        // (rows of different heights: no fixed extent to jump by)
        itemBuilder: (context, i) => ListTile(
          title: Text('Mail $i'),
          subtitle: Text('From ${senders[i % 4]}${i % 3 == 0 ? ', about the trip' : ''}'),
          isThreeLine: i % 3 == 0,
          onTap: () => opened.add('m$i'),
        ).affordItem('m$i'),
      ).affordContainer('Inbox', key: 'mail.list'),
    );
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AffordScope(kit: kit, child: host ? AffordPreviewHost(kit: kit, child: child!) : child!),
      home: page(),
    ));
    return (kit, opened);
  }

  for (final host in [true, false]) {
    testWidgets('a plain ListView.builder container: searched and reached by the kit (${host ? 'built off screen' : 'scrolled through'})', (tester) async {
      final (kit, opened) = await plain(tester, host: host);
      final res = await drive(frames: 3000, tester, kit.execute(const [
        NodeCall('mail.list', 'items', {'query': 'mail 187'}),
        NodeCall('mail.list', 'items', {'query': 'zhao trip', 'limit': 3}),
        NodeCall('mail.list', 'item', {'query': 'Mail 150'}),
        NodeCall('mail.list[m120]', 'press'),
        NodeCall('mail.list', 'item', {'query': 'nobody'}),
      ]));
      expect([for (final r in res.results) r.error ?? 'ok'], ['ok', 'ok', 'ok', 'ok', 'No entry has "nobody"']);
      expect([for (final i in (res.results[0].value as ItemsPage).items) [i.key, i.index]], [
        ['mail.list[m187]', 187],
      ]);
      // Text anywhere in the entry, every word: Zhao is i % 4 == 2, the trip i % 3 == 0
      expect([for (final i in (res.results[1].value as ItemsPage).items) i.id], ['m6', 'm18', 'm30']);
      final item = res.results[2].value as ItemTree;
      expect([item.key, item.source], ['mail.list[m150]', ItemSource.live]);
      expect(opened, ['m120']);
      if (host) {
        // Read off screen: it knows how many there are
        expect((res.results[0].value as ItemsPage).count, 1);
        expect(byKey(kit.context().root, 'mail.list')!.state!['count'], 200);
      }
    });
  }
}
