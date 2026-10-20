// A container that gives no items of its own: the kit finds its entries itself. With a list builder in it (ListView.builder,
// ListView, GridView, SliverList...) every entry is built off screen, a batch at a time, under the AffordPreviewHost and read (its
// id, its index, all its text); without one (or when an entry won't build off screen), it scrolls through the container, a page at a
// time, reading each entry as it gets built. Reaching an entry not built: a jump to where it should be, from the entries built.

part of 'afford.dart';

/// A container's entries, all of them, read off screen from its list builder (kept while the builder is the same).
class _Scan {
  _Scan(this.delegate, this.entries, this.texts);
  final SliverChildDelegate delegate;
  final List<ItemSummary> entries;
  final Map<String, String> texts;
  late final Map<String, int> indexOf = {
    for (final e in entries) e.id: e.index!,
  };
}

/// The index of the row a widget was built for (off screen).
class _EntryAt extends InheritedWidget {
  const _EntryAt({required this.index, required super.child});
  final int index;
  @override
  bool updateShouldNotify(_EntryAt oldWidget) => index != oldWidget.index;
}

/// Whether an entry is what [query] asks for: each of its words in its name, description or text (any case).
bool _matches(String query, String hay) {
  final h = hay.toLowerCase();
  return query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .every(h.contains);
}

extension on AffordKit {
  /// The list builder inside a container (the outermost one), and where it sits.
  (SliverChildDelegate, Element)? _delegateOf(_AffordState box) {
    (SliverChildDelegate, Element)? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is SliverMultiBoxAdaptorWidget) {
        found = (w.delegate, e);
        return;
      }
      e.visitChildren(visit);
    }

    if (box.mounted) visit(box.context as Element);
    return found;
  }

  /// All a container's entries, built off screen from its list builder (null: no builder, no host, an endless one, or an entry that
  /// would not build there — then it is scrolled through instead).
  Future<_Scan?> _scanOffScreen(_AffordState box) async {
    final source = _delegateOf(box);
    final host = _previewHost;
    if (source == null || host == null || !host.mounted) return null;
    final (delegate, at) = source;
    final kept = _scans[box];
    if (kept != null && identical(kept.delegate, delegate)) return kept;
    final count = delegate.estimatedChildCount;
    if (count == null) return null;
    final width = box.box?.size.width;
    final entries = <ItemSummary>[];
    final texts = <String, String>{};
    final errors = <FlutterErrorDetails>[];
    final reportError = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      const batch = 40;
      for (var from = 0; from < count && errors.isEmpty; from += batch) {
        final kit = AffordKit();
        // The rows as the list builds them (its own wrappers and all), in a list of their own tall enough to build every one
        final rows = CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(1e7),
          physics: const NeverScrollableScrollPhysics(),
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _EntryAt(
                  index: from + i,
                  child:
                      delegate.build(at, from + i) ?? const SizedBox.shrink(),
                ),
                childCount: math.min(batch, count - from),
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                addSemanticIndexes: false,
              ),
            ),
          ],
        );
        final sheet = Material(
          type: MaterialType.transparency,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: rows),
          ),
        );
        // (a new subtree each batch: its entries go into this batch's kit)
        host.show((
          Afford(
            key: ValueKey(from),
            name: '',
            affordKey: box.fullKey,
            role: Role.container,
            container: box.widget.container,
            child: sheet,
          ),
          kit,
        ));
        await _frames();
        final got = [
          for (final e in kit._entries)
            if (e.mounted && e.isEntry && e.owningContainer?.parent == null)
              (
                e,
                e.context.getInheritedWidgetOfExactType<_EntryAt>()?.index ??
                    -1,
              ),
        ]..sort((a, b) => a.$2.compareTo(b.$2));
        for (final (e, _) in got) {
          final id = e.widget.itemId!;
          if (texts.containsKey(id)) continue;
          texts[id] = [e.label, e.widget.description ?? '', e.text].join('\n');
          entries.add(
            ItemSummary(
              id: id,
              index: entries.length,
              name: e.label,
              description: e.widget.description,
            ),
          );
        }
      }
    } finally {
      FlutterError.onError = reportError;
      host.show(null);
    }
    if (errors.isNotEmpty || (count > 0 && entries.isEmpty)) return null;
    return _scans[box] = _Scan(delegate, entries, texts);
  }

  /// Scrolls through a container from the top, a page at a time, reading each entry as it is built, until [limit] entries [want]ed
  /// are found; then back where it was (or, [stay], left at the last one found — built, for the caller to bring into view).
  Future<List<ItemSummary>> _scrollScan(
    _AffordState box,
    bool Function(_AffordState e) want, {
    int limit = 1 << 30,
    bool stay = false,
  }) async {
    final position = box.scrollable?.position;
    final start = position?.pixels;
    final seen = <String>{};
    final found = <ItemSummary>[];
    void look() {
      final built =
          _entries
              .where((e) => e.mounted && e.isEntry && e.owningContainer == box)
              .toList()
            ..sort((a, b) {
              final pa = a.position, pb = b.position;
              return (pa.dy - pb.dy).abs() > 4
                  ? pa.dy.compareTo(pb.dy)
                  : pa.dx.compareTo(pb.dx);
            });
      for (final e in built) {
        final order = seen.length;
        if (!seen.add(e.widget.itemId!)) continue;
        if (found.length < limit && want(e)) {
          found.add(
            ItemSummary(
              id: e.widget.itemId!,
              index: e.entryIndex ?? order,
              name: e.label,
              description: e.widget.description,
            ),
          );
        }
      }
    }

    if (position == null) {
      look();
      return found;
    }
    position.jumpTo(position.minScrollExtent);
    await _frames();
    for (var i = 0; i < 1000; i++) {
      look();
      if (found.length >= limit ||
          position.pixels >= position.maxScrollExtent - 0.5) {
        break;
      }
      position.jumpTo(
        math.min(
          position.pixels + position.viewportDimension * 0.9,
          position.maxScrollExtent,
        ),
      );
      await _frames();
    }
    if (!stay || found.isEmpty) {
      position.jumpTo(
        start!.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      await _frames();
    }
    return found;
  }

  /// A page of a container's entries (those [query] asks for), found by the kit (the container gives no items).
  Future<ItemsPage> _findItems(
    _AffordState box, {
    required int offset,
    required int limit,
    String? query,
    bool stay = false,
  }) async {
    final scan = await _scanOffScreen(box);
    if (scan != null) {
      final all = query == null
          ? scan.entries
          : [
              for (final e in scan.entries)
                if (_matches(query, scan.texts[e.id]!)) e,
            ];
      return ItemsPage(
        count: all.length,
        offset: offset,
        items: all.skip(offset).take(limit).toList(),
      );
    }
    // Looking for something: scrolled through (it may be anywhere); else the entries built now
    if (query != null) {
      final found = await _scrollScan(
        box,
        (e) => _matches(
          query,
          [e.label, e.widget.description ?? '', e.text].join('\n'),
        ),
        limit: offset + limit,
        stay: stay,
      );
      return ItemsPage(offset: offset, items: found.skip(offset).toList());
    }
    final all = [
      for (final e
          in _entries
              .where((x) => x.mounted && x.isEntry && x.owningContainer == box)
              .toList()
            ..sort((a, b) => a.position.dy.compareTo(b.position.dy)))
        ItemSummary(
          id: e.widget.itemId!,
          index: e.entryIndex,
          name: e.label,
          description: e.widget.description,
        ),
    ];
    return ItemsPage(
      count: all.length,
      offset: offset,
      items: [
        for (final (k, i) in all.skip(offset).take(limit).indexed)
          i.index == null
              ? ItemSummary(
                  id: i.id,
                  index: offset + k,
                  name: i.name,
                  description: i.description,
                )
              : i,
      ],
    );
  }

  /// Brings an entry not built into view, the container giving no way there: by its index (known from the container, or an off
  /// screen read) a jump to where the entries built say it is, a few times over; else scrolled through until it is built.
  Future<_AffordState?> _seek(_AffordState box, ScrollTarget target) async {
    final spec = box.widget.container;
    final scrollable = box.scrollable;
    final position = scrollable?.position;
    if (position == null) return null;
    final index =
        target.index ??
        (target.id == null
            ? null
            : spec?.indexOf?.call(target.id!) ??
                  (await _scanOffScreen(box))?.indexOf[target.id!]);
    if (index != null) {
      final vertical =
          axisDirectionToAxis(scrollable!.axisDirection) == Axis.vertical;
      double along(Offset o) => vertical ? o.dy : o.dx;
      for (var round = 0; round < 12; round++) {
        final hit = _builtEntry(box, ScrollTarget(index: index));
        if (hit != null) return hit;
        final built = [
          for (final e in _entries)
            if (e.mounted &&
                e.isEntry &&
                e.owningContainer == box &&
                e.entryIndex != null &&
                e.box != null)
              e,
        ]..sort((a, b) => a.entryIndex!.compareTo(b.entryIndex!));
        if (built.isEmpty || !scrollable.mounted) break;
        // How far apart entries sit (a grid: several to a row), and the built one nearest it
        final first = built.first, last = built.last;
        final span = last.entryIndex! > first.entryIndex!
            ? (along(last.position) - along(first.position)) /
                  (last.entryIndex! - first.entryIndex!)
            : 0.0;
        final each = span > 0
            ? span
            : (vertical ? first.box!.size.height : first.box!.size.width);
        final near = built.reduce(
          (a, b) =>
              (a.entryIndex! - index).abs() <= (b.entryIndex! - index).abs()
              ? a
              : b,
        );
        final viewport = (scrollable.context.findRenderObject()! as RenderBox)
            .localToGlobal(Offset.zero);
        final to =
            (position.pixels +
                    along(near.position) -
                    along(viewport) +
                    (index - near.entryIndex!) * each)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        if ((to - position.pixels).abs() < 1) break;
        position.jumpTo(to);
        await _frames();
      }
      final hit = _builtEntry(box, ScrollTarget(index: index));
      if (hit != null || target.id == null) return hit;
    }
    if (target.id == null) return null;
    await _scrollScan(
      box,
      (e) => e.widget.itemId == target.id,
      limit: 1,
      stay: true,
    );
    return _builtEntry(box, target);
  }
}
