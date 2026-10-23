// AffordKit for Flutter: widgets put into the tree with .afford(), the tree built on demand (where each sits, what it is, what it can
// do), and the agent's calls run on the widgets — a tap where the user would tap, text typed as if by the keyboard.
//
//   ElevatedButton(onPressed: send, child: Text('Send')).afford('Send', policy: Policy.deny);
//   TextField(controller: body).afford('Body', key: 'compose.body');
//   AffordKit.instance.routes = AffordRoutes(current: ..., routes: [...], navigate: ..., preview: ...);
//   final ctx = AffordKit.instance.context();                 // → the agent
//   final next = await AffordKit.instance.execute(calls);     // the agent's answer → its next round
//
// Pages: the agent can go to a route (or back), and peek at another page's tree first — built off screen (preview: the page's widget,
// mounted under an AffordPreviewHost), or as it last showed (the kit keeps each page's last tree; snapshots() / loadSnapshots()).
//
// Every afforded widget built goes in the tree, on screen or not: a page under the one on top (another page pushed over it, a dialog
// open) is a node of its own, behind, its controls still working — a tap where a finger can't reach is the control's own callback
// instead (onPressed, onTap, onChanged).
//
// Containers: many of the same thing (a mail list, a thread's messages) are one node — how many, which show, a short preview — and
// the agent fetches the entry it wants as a tree of its own (op item: mail.list[m42], mail.list[m42].reply ...), then acts on it; an
// entry's key can also be acted on straight away (fetched — scrolled to — first):
//
//   ListView.builder(itemBuilder: (_, i) => MailRow(mails[i]).affordItem(mails[i].id, index: i), ...)
//       .affordContainer('Inbox', key: 'mail.list', kind: 'list', count: () => mails.length, items: (offset, limit, query) => ...);
//
// Handoffs: what an agent left for a user who was away (see Handoff), run when they come back — they tapped its notification and
// the app fetched it by id from its own server: `await AffordKit.instance.runHandoff(handoff)` goes to its route and runs its calls.
//
// The user meanwhile: while the agent works the screen the app has the kit watch the user (watchUser), and what they do themselves —
// a tap, typing, another page; never the kit's own calls — goes with the next answer (userActions), so the agent sees why it moved.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, ScrollCacheExtent;

import 'agent.dart';
import 'protocol.dart';

part 'scan.dart';

/// An operation the app adds to a widget.
class CustomOp {
  /// An op named [name] that [run]s (one named like a standard op, such as `press`, replaces it).
  const CustomOp(
    this.name, {
    required this.run,
    this.description,
    this.params,
    this.policy = Policy.allow,
  });

  /// The op's name, as the agent calls it.
  final String name;

  /// What it does, for the agent.
  final String? description;

  /// A JSON Schema object for the arguments.
  final Map<String, Object?>? params;

  /// Whether the agent may do it (the widget's `policies` win over this).
  final Policy policy;

  /// Does it; what it returns goes back to the agent. Throw an [AffordError] to say why it failed.
  final Future<Object?> Function(Map<String, Object?> args) run;
}

/// An app-wide operation (the same shape as a WebMCP tool on the web).
class AffordTool {
  /// A tool named [name] that does what [description] says, by [execute].
  const AffordTool(
    this.name,
    this.description, {
    required this.execute,
    this.inputSchema,
    this.policy = Policy.allow,
  });

  /// The tool's name, as the agent calls it.
  final String name;

  /// What it does, for the agent.
  final String description;

  /// A JSON Schema object for the arguments.
  final Map<String, Object?>? inputSchema;

  /// Whether the agent may run it.
  final Policy policy;

  /// Runs it; what it returns goes back to the agent.
  final Future<Object?> Function(Map<String, Object?> args) execute;
}

/// The app's routes: where the user is, where the agent can take them, and how to show it a page it isn't on.
class AffordRoutes {
  /// The app's [routes], with how to read the [current] one and [navigate] to one.
  const AffordRoutes({
    required this.current,
    required this.routes,
    required this.navigate,
    this.back,
    this.canGoBack,
    this.settle,
    this.preview,
  });

  /// The route showing now, such as /message/42.
  final String Function() current;

  /// The routes the agent can go to.
  final List<RouteSpec> routes;

  /// Takes the user to a route (filled in: /message/42).
  final Future<void> Function(String route) navigate;

  /// Back where the user was (navigate "back"); [canGoBack] says whether there is somewhere.
  final Future<void> Function()? back;

  /// Whether [back] goes somewhere.
  final bool Function()? canGoBack;

  /// Resolves once a page navigated to has shown (default: a frame or two).
  final Future<void> Function()? settle;

  /// The page's widget for a route, for a peek: built off screen under the [AffordPreviewHost] (null: no preview for this one).
  final Widget? Function(String route)? preview;
}

/// Where a container scrolls to: an entry by its id, or by its index.
class ScrollTarget {
  /// The entry with [id], or at [index].
  const ScrollTarget({this.id, this.index});

  /// The entry's id within its container.
  final String? id;

  /// The entry's index among all.
  final int? index;
}

/// What a container tells the kit about its entries (see [AffordWidget.affordContainer]). All optional: without them its entries
/// are those built now. Give [count], [items] and [scrollTo] for a ListView.builder, so the agent can page through and reach all.
class AffordContainerSpec {
  /// What a container says about its entries; every part is optional.
  const AffordContainerSpec({
    this.kind,
    this.count,
    this.items,
    this.scrollTo,
    this.scroll,
    this.settle,
    this.indexOf,
    this.itemExtent,
    this.build,
    this.previewItems = 10,
  });

  /// What its entries are, in a word (list, grid, thread, tabs...).
  final String? kind;

  /// How many entries there are in all.
  final int Function()? count;

  /// A page of all the entries, built or not (for the items op); their keys are made from the container's.
  final FutureOr<List<ItemSummary>> Function(
    int offset,
    int limit,
    String? query,
  )?
  items;

  /// Bring an entry into view (built). Default: ensureVisible on it if built, else (with [indexOf] and [itemExtent]) a jump there.
  final Future<void> Function(ScrollTarget target)? scrollTo;

  /// Scroll by pages (negative: up). Default: its scroll position by its height.
  final Future<void> Function(double pages)? scroll;

  /// Resolves once a scroll has shown its entries (default: a frame or two).
  final Future<void> Function()? settle;

  /// An entry's index from its id (for the default scrollTo, and the entries' indexes).
  final int? Function(String id)? indexOf;

  /// Every entry's height, when they are all the same (for the default scrollTo to one not built).
  final double? itemExtent;

  /// An entry's widget (wrapped in .affordItem), built off screen under the [AffordPreviewHost]: for op item with preview, or an entry
  /// that can't be scrolled to.
  final Widget? Function(ScrollTarget target)? build;

  /// Most entries in its preview.
  final int previewItems;
}

/// The same as [AffordContainerSpec] (a list is a container of kind list).
typedef AffordListSpec = AffordContainerSpec;

/// Puts widgets into the agent's tree: `.afford()`, `.affordContainer()`, `.affordItem()`.
extension AffordWidget on Widget {
  /// Put this widget into the agent's tree, under [name] (and [description]); what it is and what it can do come from the widget
  /// itself (a button is pressed, a text field read and written...). [policy] for all its ops, or [policies] per op. [key]: a name
  /// that stays the same across pages and visits, for calls (also on a page the agent only peeked at). [state]: what a widget of
  /// the app's own says of itself ({disabled: true}, {checked: false}, {selected: true}...), over what the kit finds.
  Widget afford(
    String name, {
    String? key,
    String? description,
    Role? role,
    Policy? policy,
    Map<String, Policy> policies = const {},
    List<CustomOp> ops = const [],
    Map<String, Object>? state,
    AffordKit? kit,
  }) => Afford(
    name: name,
    affordKey: key,
    description: description,
    role: role,
    policy: policy,
    policies: policies,
    ops: ops,
    state: state,
    kit: kit,
    child: this,
  );

  /// This widget (a ListView, a column of messages...) as a container: one node in the tree — how many entries, which show, a short
  /// preview — and its entries (.affordItem under it) fetched one at a time as trees of their own, keyed from [key] (`mail.list[42]`).
  Widget affordContainer(
    String name, {
    String? key,
    String? kind,
    String? description,
    Policy? policy,
    Map<String, Policy> policies = const {},
    int Function()? count,
    FutureOr<List<ItemSummary>> Function(int offset, int limit, String? query)?
    items,
    Future<void> Function(ScrollTarget target)? scrollTo,
    Future<void> Function(double pages)? scroll,
    Future<void> Function()? settle,
    int? Function(String id)? indexOf,
    double? itemExtent,
    Widget? Function(ScrollTarget target)? build,
    int previewItems = 10,
    AffordKit? kit,
  }) => Afford(
    name: name,
    affordKey: key,
    description: description,
    role: Role.container,
    policy: policy,
    policies: policies,
    kit: kit,
    container: AffordContainerSpec(
      kind: kind,
      count: count,
      items: items,
      scrollTo: scrollTo,
      scroll: scroll,
      settle: settle,
      indexOf: indexOf,
      itemExtent: itemExtent,
      build: build,
      previewItems: previewItems,
    ),
    child: this,
  );

  /// [affordContainer], of kind list.
  Widget affordList(
    String name, {
    String? key,
    String? description,
    Policy? policy,
    Map<String, Policy> policies = const {},
    int Function()? count,
    FutureOr<List<ItemSummary>> Function(int offset, int limit, String? query)?
    items,
    Future<void> Function(ScrollTarget target)? scrollTo,
    Future<void> Function(double pages)? scroll,
    Future<void> Function()? settle,
    int? Function(String id)? indexOf,
    double? itemExtent,
    Widget? Function(ScrollTarget target)? build,
    int previewItems = 10,
    AffordKit? kit,
  }) => affordContainer(
    name,
    key: key,
    kind: 'list',
    description: description,
    policy: policy,
    policies: policies,
    count: count,
    items: items,
    scrollTo: scrollTo,
    scroll: scroll,
    settle: settle,
    indexOf: indexOf,
    itemExtent: itemExtent,
    build: build,
    previewItems: previewItems,
    kit: kit,
  );

  /// This widget as one of its container's entries, [id] (its key: the container's key + [id]; afforded widgets in it get keys under
  /// that, e.g. `mail.list[42].star`). [name]: default, the text in it.
  Widget affordItem(
    String id, {
    String name = '',
    int? index,
    String? description,
    Role? role,
    Policy? policy,
    Map<String, Policy> policies = const {},
    List<CustomOp> ops = const [],
    AffordKit? kit,
  }) => Afford(
    name: name,
    description: description,
    role: role ?? Role.listitem,
    policy: policy,
    policies: policies,
    ops: ops,
    kit: kit,
    itemId: id,
    itemIndex: index,
    child: this,
  );
}

/// A widget in the agent's tree; what `.afford()`, `.affordContainer()` and `.affordItem()` wrap their widget in.
class Afford extends StatefulWidget {
  /// Puts [child] into the tree under [name]; see [AffordWidget.afford] for the rest.
  const Afford({
    super.key,
    required this.name,
    required this.child,
    this.affordKey,
    this.description,
    this.role,
    this.policy,
    this.policies = const {},
    this.ops = const [],
    this.kit,
    this.container,
    this.itemId,
    this.itemIndex,
    this.state,
  });

  /// What the user sees it called.
  final String name;

  /// Its key: a name that stays the same across pages and visits, for calls.
  final String? affordKey;

  /// More about it, for the agent.
  final String? description;

  /// What it is (default: guessed from [child]).
  final Role? role;

  /// The policy for all its ops.
  final Policy? policy;

  /// Policies per op, over [policy].
  final Map<String, Policy> policies;

  /// Ops of the app's own (one named like a standard op replaces it).
  final List<CustomOp> ops;

  /// What a widget of the app's own says of itself ({disabled: true}...), over what the kit finds.
  final Map<String, Object>? state;

  /// A container: what it says about its entries.
  final AffordContainerSpec? container;

  /// One of a container's entries: its id (and index among all, when known).
  final String? itemId;

  /// The entry's index among all its container's entries, when known.
  final int? itemIndex;

  /// The kit it goes into (default: the nearest [AffordScope]'s, else [AffordKit.instance]).
  final AffordKit? kit;

  /// The widget put into the tree.
  final Widget child;

  @override
  State<Afford> createState() => _AffordState();
}

/// The kit for the widgets under it (e.g. a page built for a peek has its own).
class AffordScope extends InheritedWidget {
  /// Afforded widgets under [child] go into [kit].
  const AffordScope({super.key, required this.kit, required super.child});

  /// The kit for the widgets under it.
  final AffordKit kit;

  /// The kit of the nearest [AffordScope] above [context], if any.
  static AffordKit? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AffordScope>()?.kit;

  @override
  bool updateShouldNotify(AffordScope oldWidget) => kit != oldWidget.kit;
}

class _AffordState extends State<Afford> {
  AffordKit? kit;
  late String id;
  _AffordState? parent;

  /// The page (route) it is on, if any.
  ModalRoute<Object?>? route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final k = widget.kit ?? AffordScope.maybeOf(context) ?? AffordKit.instance;
    if (k != kit) {
      kit?._entries.remove(this);
      kit = k;
      id = k._nextId();
      k._entries.add(this);
    }
    // Where it sits: under the nearest afforded ancestor (layout in between doesn't count)
    parent = context.findAncestorStateOfType<_AffordState>();
    route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    kit?._entries.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  Role get role => widget.role ?? _roleOf(widget.child);

  bool get isContainer => role == Role.container;

  /// One of a container's entries (an .affordItem with no container above it is just a node).
  bool get isEntry => widget.itemId != null && owningContainer != null;

  /// The container it is an entry of; the entry it is in.
  _AffordState? get owningContainer {
    for (var p = parent; p != null; p = p.parent) {
      if (p.isContainer) return p;
    }
    return null;
  }

  _AffordState? get owningEntry {
    for (var p = parent; p != null; p = p.parent) {
      if (p.isEntry) return p;
    }
    return null;
  }

  /// Its key: an entry's from its container's (mail.list[42]); a key inside an entry, under the entry's (mail.list[42].star).
  String? get fullKey {
    if (isEntry) {
      final box = owningContainer?.fullKey;
      return box == null ? null : itemKey(box, widget.itemId!);
    }
    final k = widget.affordKey;
    if (k == null) return null;
    final entry = owningEntry?.fullKey;
    return entry == null ? k : '$entry.$k';
  }

  Rect? get rect {
    final b = box;
    return b == null ? null : b.localToGlobal(Offset.zero) & b.size;
  }

  /// An entry: whether it shows in its container's box (built ahead, off the edge, it doesn't).
  bool get inContainerView {
    final r = rect, l = owningContainer?.rect;
    return r == null || l == null || r.overlaps(l);
  }

  /// An entry: its index among all, when known.
  int? get entryIndex {
    final box = owningContainer;
    if (box == null) return widget.itemIndex;
    return widget.itemIndex ??
        box.widget.container?.indexOf?.call(widget.itemId!) ??
        kit?._scans[box]?.indexOf[widget.itemId!];
  }

  /// What it is called: its name, else (an entry) the first line of its text.
  String get label => widget.name.isEmpty && widget.itemId != null
      ? _firstLine(text)
      : widget.name;

  /// The scrolling state inside (a container's ListView).
  ScrollableState? get scrollable {
    ScrollableState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        found = e.state as ScrollableState;
        return;
      }
      e.visitChildren(visit);
    }

    if (mounted) visit(context as Element);
    return found;
  }

  RenderBox? get box {
    final r = mounted ? context.findRenderObject() : null;
    return r is RenderBox && r.attached && r.hasSize ? r : null;
  }

  bool get onScreen {
    final b = box;
    if (b == null || b.size.isEmpty) return false;
    final view = View.maybeOf(context);
    if (view == null) return true;
    final size = view.physicalSize / view.devicePixelRatio;
    final rect = b.localToGlobal(Offset.zero) & b.size;
    return rect.overlaps(Offset.zero & size);
  }

  Offset get position => box?.localToGlobal(Offset.zero) ?? Offset.zero;

  /// The text field inside, if any.
  EditableTextState? get editable {
    EditableTextState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    if (mounted) visit(context as Element);
    return found;
  }

  /// All the text shown inside.
  String get text {
    final out = <String>[];
    void visit(Element e) {
      final w = e.widget;
      if (w is Text) {
        out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
        return;
      }
      if (w is RichText) {
        out.add(w.text.toPlainText());
        return;
      }
      if (w is EditableText) {
        out.add(w.controller.text);
        return;
      }
      e.visitChildren(visit);
    }

    if (mounted) visit(context as Element);
    return out.where((t) => t.trim().isNotEmpty).join('\n');
  }

  Map<String, Object> get state {
    final s = <String, Object>{};
    final child = widget.child;
    final disabled = switch (child) {
      ButtonStyleButton b => b.onPressed == null,
      IconButton b => b.onPressed == null,
      FloatingActionButton b => b.onPressed == null,
      ListTile t => t.enabled == false,
      _ => false,
    };
    if (disabled) s['disabled'] = true;
    final checked = switch (child) {
      Checkbox c => c.value,
      CheckboxListTile c => c.value,
      Switch c => c.value,
      SwitchListTile c => c.value,
      _ => null,
    };
    if (checked != null) s['checked'] = checked;
    if (role == Role.textbox) {
      final e = editable;
      if (e != null) {
        s['length'] = e.textEditingValue.text.length;
        if (e.widget.obscureText) s['secret'] = true;
        if (e.widget.focusNode.hasFocus) s['focused'] = true;
      }
    }
    // (what the app says over what the kit found)
    if (widget.state case final own?) s.addAll(own);
    return s;
  }
}

/// What a widget is, from its type (when the app doesn't say).
Role _roleOf(Widget w) => switch (w) {
  ButtonStyleButton() ||
  IconButton() ||
  FloatingActionButton() ||
  InkWell() ||
  GestureDetector() => Role.button,
  TextField() || TextFormField() || EditableText() => Role.textbox,
  Checkbox() || CheckboxListTile() => Role.checkbox,
  Switch() || SwitchListTile() => Role.switch_,
  ListTile() => Role.listitem,
  Tab() => Role.tab,
  ListView() || Column() => Role.list, // (a long list: .affordContainer)
  AlertDialog() || Dialog() => Role.dialog,
  Scaffold() => Role.page,
  Text() || RichText() => Role.text,
  _ => Role.region,
};

/// Where pages are built off screen for peeks: put it around the app (e.g. MaterialApp.builder), under the app's theme and providers.
class AffordPreviewHost extends StatefulWidget {
  /// Hosts peeks around [child] (the app).
  const AffordPreviewHost({super.key, required this.child, this.kit});

  /// The app.
  final Widget child;

  /// The kit whose peeks it serves (default: [AffordKit.instance]).
  final AffordKit? kit;

  @override
  State<AffordPreviewHost> createState() => _AffordPreviewHostState();
}

class _AffordPreviewHostState extends State<AffordPreviewHost> {
  (Widget, AffordKit)? _page;
  final _shot = GlobalKey();
  AffordKit get _kit => widget.kit ?? AffordKit.instance;

  @override
  void initState() {
    super.initState();
    _kit._previewHost = this;
  }

  @override
  void dispose() {
    if (_kit._previewHost == this) _kit._previewHost = null;
    super.dispose();
  }

  void show((Widget, AffordKit)? page) {
    if (mounted) setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        // (what the user sees: what a picture of the screen is taken of)
        Positioned.fill(
          child: RepaintBoundary(key: _shot, child: widget.child),
        ),
        // Laid out at the screen's size, never painted or touched, no animations running
        if (page != null)
          Positioned.fill(
            child: Offstage(
              child: TickerMode(
                enabled: false,
                child: AffordScope(kit: page.$2, child: page.$1),
              ),
            ),
          ),
      ],
    );
  }
}

/// A frame or two for what changed to build (not forever: no frames come while the app is in the background).
Future<void> _frames() async {
  for (var i = 0; i < 2; i++) {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {},
    );
  }
}

/// An op about to run on a widget (for [AffordKit.onAct]): what, on which node, and where it is on screen.
class ActEvent {
  /// [op] with [args] is about to run on [node].
  const ActEvent({
    required this.node,
    required this.op,
    required this.args,
    this.rect,
    this.behind = false,
  });

  /// The node acted on.
  final AffordNode node;

  /// The op's name.
  final String op;

  /// The op's arguments.
  final Map<String, Object?> args;

  /// The widget on screen (global coordinates), when a finger can reach it.
  final Rect? rect;

  /// A finger can't reach it (a page under the one on top, a dialog over it): the op runs without a tap the user sees.
  final bool behind;
}

/// What came of running a handoff ([AffordKit.runHandoff]): whether it all ran, how many of its calls did, and where and why it
/// stopped.
class HandoffResult {
  /// The handoff ran [ran] calls, all of them when [ok].
  const HandoffResult({
    required this.ok,
    required this.ran,
    this.results = const [],
    this.stoppedAt,
    this.code,
    this.error,
  });

  /// Whether it all ran.
  final bool ok;

  /// How many of its calls ran (its route not counted).
  final int ran;

  /// Each step's result: the route's first, when it has one.
  final List<CallResult> results;

  /// The call it stopped at (its index), or -1 before any: invalid, expired, or its route could not be gone to.
  final int? stoppedAt;

  /// Why it stopped.
  final ErrorCode? code;

  /// Why it stopped, in words.
  final String? error;
}

/// The tree of afforded widgets on screen, and the agent's calls run on them.
class AffordKit {
  /// A kit of its own; most apps use [instance].
  AffordKit({this.confirm, this.onAct, this.typeDelay, this.onUserAction});

  /// Called before an op runs on a widget (allowed by its policy): e.g. to show the user where the agent is about to tap, and wait a
  /// moment so they see it happen. The op runs when it completes.
  Future<void> Function(ActEvent event)? onAct;

  /// write / append type the text in, a few characters every [typeDelay] (the whole text in at most about a second and a half), as
  /// if someone were typing; null puts it in at once.
  Duration? typeDelay;

  /// After the agent's calls, once their frame has built: resolves when what they set off has settled — a list or page loading its data
  /// (a search, a mailbox, a message fetched) — so the screen the agent gets back shows the result, not a spinner. Null: the frame only.
  /// The app bounds its own wait (no frames come while it is in the background).
  Future<void> Function()? settle;

  /// The one most apps use (.afford() puts widgets here unless given another, or under another [AffordScope]).
  static final AffordKit instance = AffordKit();

  /// Asked before an op or tool with policy confirm runs; without it those come back needsConfirm.
  Future<bool> Function(Call call, {AffordNode? node, ToolSpec? tool})? confirm;

  final _entries = <_AffordState>{};
  final _tools = <String, AffordTool>{};

  /// The app's routes, so the agent can go to pages and peek at them (null: it can't).
  AffordRoutes? routes;
  _AffordPreviewHostState? _previewHost;
  int _counter = 0;
  int _pointer = 9000;
  Map<String, (_AffordState, AffordNode)> _last = {};

  /// The nodes of entries fetched (op item, or an entry's key acted on): their ids stay live while the entry is built.
  final _fetched = <String, (_AffordState, AffordNode)>{};

  /// Each page's tree the last time it showed (by route), for peeks.
  final _seen = <String, (AffordNode, DateTime)>{};

  /// Containers that give no items: all their entries, as last read off screen (scan.dart).
  final _scans = Expando<_Scan>();

  /// Each page's route (AffordRoutes.current) as it was when it was first on top, and when that was.
  final _routeNames = Expando<String>();
  final _routeOrder = Expando<int>();

  String _nextId() => 'w${++_counter}';

  /// Adds one of the app's own tools (replacing one of the same name).
  void registerTool(AffordTool tool) => _tools[tool.name] = tool;

  /// Removes the app's tool named [name].
  void unregisterTool(String name) => _tools.remove(name);

  RouteState? _routeState() {
    final r = routes;
    if (r == null) return null;
    final current = r.current();
    final hit = findRoute(r.routes, current);
    return RouteState(
      current: current,
      pattern: hit?.$1.path,
      params: hit?.$2 ?? const {},
      canGoBack: r.canGoBack?.call(),
      routes: r.routes,
    );
  }

  /// The tree of the widgets built now (pages under the one on top too, as nodes of their own).
  AffordContext context() {
    final (root, last) = _tree(laidOut: false);
    _last = last;
    final route = _routeState();
    // (kept for peeks: this page's alone, not those under it)
    if (route != null) {
      _seen[route.current] = (
        AffordNode(
          id: root.id,
          role: root.role,
          name: root.name,
          ops: root.ops,
          children: [
            for (final c in root.children)
              if (c.state?['behind'] != true) c,
          ],
        ),
        DateTime.now(),
      );
    }
    return AffordContext(
      root: root,
      tools: [
        for (final t in _tools.values)
          ToolSpec(
            t.name,
            t.description,
            inputSchema: t.inputSchema,
            policy: t.policy,
          ),
      ],
      route: route,
    );
  }

  /// Another page's tree without going there (see [PagePeek]).
  Future<PagePeek> peek(String route) async {
    final r = routes;
    if (r == null) {
      throw AffordError(ErrorCode.notFound, 'This app has no routes');
    }
    final hit = findRoute(r.routes, route);
    PagePeek view(PageSource source, {AffordNode? root, DateTime? seenAt}) =>
        PagePeek(
          route: route,
          source: source,
          pattern: hit?.$1.path,
          description: hit?.$1.description,
          root: root,
          seenAt: seenAt,
        );
    if (route == r.current()) {
      return view(PageSource.live, root: context().root);
    }
    final page = r.preview?.call(route);
    final host = _previewHost;
    if (page != null && host != null && host.mounted) {
      // Built off screen with a kit of its own, read, and taken down
      final kit = AffordKit();
      host.show((page, kit));
      try {
        await _frames();
        return view(PageSource.preview, root: kit._tree().$1.prefixed('peek:'));
      } finally {
        host.show(null);
      }
    }
    // As it last showed: this very route, else another of the same pattern (/mail/folder/2 for /mail/folder/7)
    final seen =
        _seen[route] ??
        (hit == null
            ? null
            : _seen.entries
                  .where((e) => findRoute([hit.$1], e.key) != null)
                  .firstOrNull
                  ?.value);
    if (seen != null) {
      return view(
        PageSource.seen,
        root: seen.$1.prefixed('peek:'),
        seenAt: seen.$2,
      );
    }
    return view(PageSource.declared);
  }

  /// The pages' last trees as JSON, to keep and give back with [loadSnapshots] next run (peeks then know pages not seen yet).
  Map<String, Object?> snapshots() => {
    for (final e in _seen.entries)
      e.key: {
        'at': e.value.$2.millisecondsSinceEpoch,
        'root': e.value.$1.toJson(),
      },
  };

  /// Gives back what [snapshots] returned on an earlier run (pages seen this run are kept as they are).
  void loadSnapshots(Map<String, Object?> snapshots) {
    for (final e in snapshots.entries) {
      final v = e.value;
      if (_seen.containsKey(e.key) || v is! Map) continue;
      final root = v['root'];
      if (root is Map) {
        _seen[e.key] = (
          _nodeFromJson(root.cast<String, Object?>()),
          DateTime.fromMillisecondsSinceEpoch((v['at'] as num?)?.toInt() ?? 0),
        );
      }
    }
  }

  /// The tree of what is on screen ([within]: one entry's own tree, rooted at it, built whether on screen or not). A container's
  /// entries are not in the tree it is in: it notes which show (a preview), and each is a tree of its own.
  (AffordNode, Map<String, (_AffordState, AffordNode)>) _tree({
    bool laidOut = true,
    _AffordState? within,
  }) {
    bool shown(_AffordState e) => e.mounted && (!laidOut || e.box != null);
    // In this tree: not in an entry (or, for an entry's tree, in that one) and not an entry itself
    bool here(_AffordState e) =>
        e == within || (!e.isEntry && e.owningEntry == within);

    final live = _entries.where((e) => here(e) && shown(e)).toList();
    final nodes = <_AffordState, AffordNode>{};
    final last = <String, (_AffordState, AffordNode)>{};
    for (final e in live) {
      final secret =
          e.role == Role.textbox && e.editable?.widget.obscureText == true;
      var ops = opsFor(
        e.role,
        policy: e.widget.policy,
        policies: e.widget.policies,
        own: [
          for (final o in e.widget.ops)
            OpSpec(
              o.name,
              description: o.description,
              params: o.params,
              policy: o.policy,
            ),
        ],
      );
      // Passwords: the agent sees the field exists, never reads or types it
      if (secret) ops = [for (final o in ops) o.withPolicy(Policy.deny)];
      final node = AffordNode(
        id: e.id,
        key: e.fullKey,
        role: e.role,
        name: e.label,
        description: e.widget.description,
        state: e.state,
        ops: ops,
        children: [],
      );
      nodes[e] = node;
      last[e.id] = (e, node);
    }
    // Each under its nearest afforded ancestor in the tree; in reading order (top to bottom, left to right)
    _AffordState? up(_AffordState e) {
      var p = e.parent;
      while (p != null && !nodes.containsKey(p)) {
        p = p.parent;
      }
      return p;
    }

    int order(_AffordState a, _AffordState b) {
      final pa = a.position, pb = b.position;
      return (pa.dy - pb.dy).abs() > 4
          ? pa.dy.compareTo(pb.dy)
          : pa.dx.compareTo(pb.dx);
    }

    final top = <_AffordState>[];
    final kids = <_AffordState, List<_AffordState>>{};
    for (final e in live) {
      final p = up(e);
      if (p == null) {
        top.add(e);
      } else {
        (kids[p] ??= []).add(e);
      }
    }

    AffordNode build(_AffordState e) {
      final node = nodes[e]!;
      final children = (kids[e] ?? <_AffordState>[])..sort(order);
      // A container: how many entries in all, which show (on screen, in its box: entries are built ahead, off its edge), a preview
      final spec = e.widget.container;
      if (e.isContainer) {
        final entries =
            _entries
                .where(
                  (x) =>
                      x.mounted &&
                      x.isEntry &&
                      x.owningContainer == e &&
                      x.onScreen &&
                      x.inContainerView,
                )
                .toList()
              ..sort(order);
        final indexes = [
          for (final (i, k) in entries.indexed)
            if ((k.entryIndex ?? (spec?.count == null ? i : null))
                case final int n)
              n,
        ];
        final state = node.state!;
        if (spec?.kind != null) state['kind'] = spec!.kind!;
        state['count'] =
            spec?.count?.call() ?? _scans[e]?.entries.length ?? entries.length;
        if (indexes.isNotEmpty) {
          state['first'] = indexes.reduce((a, b) => a < b ? a : b);
          state['last'] = indexes.reduce((a, b) => a > b ? a : b);
        }
        node.preview = [
          for (final (i, k) in entries.take(spec?.previewItems ?? 10).indexed)
            ItemSummary(
              id: k.widget.itemId!,
              key: k.fullKey,
              index: k.entryIndex ?? (spec?.count == null ? i : null),
              name: k.label,
              description: k.widget.description,
            ),
        ];
      }
      node.children = [for (final k in children) build(k)];
      // What a text, a heading or a part with no controls in it shows, to read without an op
      if (const {Role.text, Role.heading}.contains(node.role) ||
          (node.children.isEmpty &&
              const {
                Role.region,
                Role.other,
                Role.listitem,
                Role.dialog,
              }.contains(node.role))) {
        final words = _clip(e.text);
        if (words.isNotEmpty && words != node.name) node.value = words;
      }
      return node;
    }

    if (within != null) {
      final node = nodes[within];
      if (node == null) {
        throw AffordError(
          ErrorCode.notFound,
          'Entry ${within.fullKey ?? within.widget.itemId} is not built',
        );
      }
      return (build(within), last);
    }
    // Pages under the one on top: theirs under a node for the page (its route as it was when on top), the latest first
    final current = routes?.current();
    final front = <_AffordState>[];
    final behind = <ModalRoute<Object?>, List<_AffordState>>{};
    for (final e in top) {
      final r = e.route;
      if (r == null || r.isCurrent) {
        if (r != null && _routeOrder[r] == null) {
          _routeNames[r] = current;
          _routeOrder[r] = ++_counter;
        }
        front.add(e);
      } else {
        (behind[r] ??= []).add(e);
      }
    }
    final pages = behind.keys.toList()
      ..sort((a, b) => (_routeOrder[b] ?? 0).compareTo(_routeOrder[a] ?? 0));
    final root = AffordNode(
      id: 'app',
      role: Role.app,
      name: '',
      ops: opsFor(Role.app),
      children: [
        for (final e in front..sort(order)) build(e),
        for (final r in pages)
          AffordNode(
            id: 'behind-${_routeOrder[r] ?? identityHashCode(r)}',
            role: r is PopupRoute ? Role.dialog : Role.page,
            name: _routeNames[r] ?? r.settings.name ?? '',
            description: 'Under what is on top: its controls still work, but the user does not see them act',
            state: {'behind': true},
            ops: const [],
            children: [for (final e in behind[r]!..sort(order)) build(e)],
          ),
      ],
    );
    return (root, last);
  }

  /// A node by its id or key (looking again if it isn't in the last tree: the screen may have changed since). In an entry of a
  /// container (or the entry itself): the entry is fetched — scrolled to — first (the container found the same way: it may be in an
  /// entry itself).
  Future<(_AffordState, AffordNode)?> _resolve(
    String ref, [
    int depth = 0,
  ]) async {
    (_AffordState, AffordNode)? find() {
      for (final nodes in [_last, _fetched]) {
        final hit =
            nodes[ref] ??
            nodes.values
                .where((v) => v.$2.key == ref && v.$1.mounted)
                .firstOrNull;
        if (hit != null && hit.$1.mounted) return hit;
      }
      return null;
    }

    final hit = find();
    if (hit != null) return hit;
    context();
    final again = find();
    if (again != null) return again;
    final item = parseItemKey(ref);
    if (item == null || depth > 8) return null;
    final box = await _resolve(item.list, depth + 1);
    if (box == null || !box.$1.isContainer) return null;
    await _fetchItem(box.$1, box.$2.key, ScrollTarget(id: item.id));
    return find();
  }

  /// A container's entry built now, by id or index.
  _AffordState? _builtEntry(_AffordState box, ScrollTarget target) => _entries
      .where(
        (e) =>
            e.mounted &&
            e.isEntry &&
            e.owningContainer == box &&
            (target.id != null
                ? e.widget.itemId == target.id
                : e.entryIndex == target.index),
      )
      .firstOrNull;

  /// Bring a container's entry into view (by id or index), and wait for it to show.
  Future<void> _reveal(_AffordState box, ScrollTarget target) async {
    final spec = box.widget.container;
    final custom = spec?.scrollTo;
    if (custom != null) {
      await custom(target);
    } else {
      var item = _builtEntry(box, target);
      final index =
          target.index ??
          (target.id == null ? null : spec?.indexOf?.call(target.id!));
      final position = box.scrollable?.position;
      if (item == null &&
          index != null &&
          spec?.itemExtent != null &&
          position != null) {
        // Not built: jump to where it would be, then it is
        position.jumpTo(
          (index * spec!.itemExtent!).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
        await _frames();
        item = _builtEntry(box, target);
      }
      // No way there given: found by the kit (scan.dart)
      if (item == null && (spec?.itemExtent == null || index == null)) {
        item = await _seek(box, target);
      }
      if (item == null || !item.mounted) {
        throw AffordError(
          ErrorCode.notFound,
          'Entry ${target.id ?? '#${target.index}'} is not built, and the container gives no way to scroll to it (scrollTo)',
        );
      }
      await Scrollable.ensureVisible(item.context);
    }
    await (spec?.settle?.call() ?? _frames());
  }

  /// One entry as a tree of its own: brought into view first when it isn't (a tap lands where it shows), or built off screen (preview,
  /// or when it can only be built). Its nodes' ids stay live while it is built.
  Future<ItemTree> _fetchItem(
    _AffordState box,
    String? boxKey,
    ScrollTarget target, {
    bool preview = false,
  }) async {
    final spec = box.widget.container;
    _AffordState? item;
    if (!preview) {
      item = _builtEntry(box, target);
      if (item == null || !item.onScreen || !item.inContainerView) {
        try {
          await _reveal(box, target);
        } on StateError {
          if (spec?.build == null) rethrow;
        }
        item = _builtEntry(box, target);
      }
    }
    if (item == null) {
      final widget = spec?.build?.call(target);
      final host = _previewHost;
      if (widget == null || host == null || !host.mounted) {
        throw AffordError(
          ErrorCode.notFound,
          'No entry ${target.id ?? '#${target.index}'} here${preview ? ' to preview' : ''}',
        );
      }
      // Built off screen with a kit of its own, under a container like this one (so its keys come out the same), read, taken down
      final kit = AffordKit();
      // (on a sheet of Material at the top, as a row in a list sits: list tiles and ink need one above them)
      final sheet = Material(
        type: MaterialType.transparency,
        child: Align(alignment: Alignment.topLeft, child: widget),
      );
      host.show((
        Afford(
          name: '',
          affordKey: boxKey,
          role: Role.container,
          container: spec,
          child: sheet,
        ),
        kit,
      ));
      try {
        await _frames();
        final entry = kit._entries
            .where((e) => e.mounted && e.isEntry)
            .firstOrNull;
        if (entry == null) {
          throw StateError(
            'The entry built for ${target.id ?? '#${target.index}'} has no .affordItem',
          );
        }
        final root = kit._tree(within: entry).$1.prefixed('peek:');
        return ItemTree(
          id: entry.widget.itemId!,
          key: entry.fullKey,
          index: entry.entryIndex ?? target.index,
          source: ItemSource.preview,
          root: root,
        );
      } finally {
        host.show(null);
      }
    }
    final (root, nodes) = _tree(within: item);
    _fetched.addAll(nodes);
    return ItemTree(
      id: item.widget.itemId!,
      key: item.fullKey,
      index: item.entryIndex,
      source: ItemSource.live,
      root: root,
    );
  }

  /// A container's ops of its own: one entry's tree, a page of its entries, scrolling to one, scrolling by pages.
  Future<Object?> _containerOp(
    _AffordState e,
    AffordNode n,
    String op,
    Map<String, Object?> args,
  ) async {
    final spec = e.widget.container;
    // (an entry's key: the id in it)
    String idOf(Object? v) {
      final id = '$v';
      return n.key != null && id.startsWith('${n.key}[') && id.endsWith(']')
          ? id.substring(n.key!.length + 1, id.length - 1)
          : id;
    }

    switch (op) {
      case 'item':
        final ScrollTarget target;
        final query = args['query'];
        if (args['id'] != null && args['id'] != '') {
          target = ScrollTarget(id: idOf(args['id']));
        } else if (args['index'] is num) {
          target = ScrollTarget(index: (args['index'] as num).toInt());
        } else if (query is String && query.isNotEmpty) {
          // (found by the kit, scrolled through: left there, built)
          final page = spec?.items != null
              ? await _containerOp(e, n, 'items', {'query': query, 'limit': 1})
                    as ItemsPage
              : await _findItems(
                  e,
                  offset: 0,
                  limit: 1,
                  query: query,
                  stay: true,
                );
          if (page.items.isEmpty) {
            throw AffordError(ErrorCode.notFound, 'No entry has "$query"');
          }
          target = ScrollTarget(id: page.items.first.id);
        } else {
          throw AffordError(
            ErrorCode.badArgs,
            'Say which entry: id, index or query',
          );
        }
        return _fetchItem(e, n.key, target, preview: args['preview'] == true);
      case 'items':
        final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(
          0,
          1 << 30,
        );
        final limit = ((args['limit'] as num?)?.toInt() ?? 20).clamp(1, 200);
        final query =
            args['query'] is String && (args['query'] as String).isNotEmpty
            ? args['query'] as String
            : null;
        ItemSummary keyed(ItemSummary i, int index) =>
            i.withKey(n.key == null ? null : itemKey(n.key!, i.id), index);
        final source = spec?.items;
        if (source != null) {
          final got = await source(offset, limit, query);
          return ItemsPage(
            count: spec?.count?.call(),
            offset: offset,
            items: [for (final (k, i) in got.indexed) keyed(i, offset + k)],
          );
        }
        // Found by the kit (scan.dart)
        final page = await _findItems(
          e,
          offset: offset,
          limit: limit,
          query: query,
        );
        return ItemsPage(
          count: page.count,
          offset: offset,
          items: [
            for (final (k, i) in page.items.indexed)
              keyed(i, i.index ?? offset + k),
          ],
        );
      case 'scroll_to':
        final id = args['item'] == null ? null : idOf(args['item']);
        final index = (args['index'] as num?)?.toInt();
        if (id == null && index == null) {
          throw AffordError(
            ErrorCode.badArgs,
            'Say which entry: index or item',
          );
        }
        await _reveal(
          e,
          ScrollTarget(id: id, index: id == null ? index : null),
        );
        return null;
      case 'scroll':
        final pages = (args['by'] as num?)?.toDouble() ?? 1;
        final custom = spec?.scroll;
        if (custom != null) {
          await custom(pages);
        } else {
          final p = e.scrollable?.position;
          if (p == null) {
            throw AffordError(ErrorCode.noOp, '"${n.name}" does not scroll');
          }
          p.jumpTo(
            (p.pixels + pages * p.viewportDimension).clamp(
              p.minScrollExtent,
              p.maxScrollExtent,
            ),
          );
        }
        await (spec?.settle?.call() ?? _frames());
        return null;
    }
    throw AffordError(ErrorCode.noOp, 'No way to $op a container');
  }

  // ---------------- what the user does themselves meanwhile (watchUser) ----------------

  /// Told each thing the user does themselves while watched ([watchUser]), as it is noted (typing: each time the burst grows).
  void Function(UserAction action)? onUserAction;

  bool _watching = false;
  final _userActions = <UserAction>[];

  /// Most kept (the latest).
  static const _maxUserActions = 30;

  /// What the last one noted came from: a field (the next edit of it goes into the same entry), or a tap (a page it opens goes with it).
  Object? _lastFrom;
  static final _aTap = Object();

  /// Running the agent's calls (or a handoff), and a moment after: what an op sets off — a tap's events, a page opening, a field's
  /// listeners — can land after it returns. Nothing is noted then.
  int _busy = 0;
  int _quietUntil = 0;
  bool get _own => _busy > 0 || _now() < _quietUntil;

  void _calmDown() {
    _busy--;
    _quietUntil = _now() + 300;
  }

  /// Whether the kit notes what the user does themselves on afforded widgets: an app turns it on while its agent works the screen, and
  /// off when it is done (off forgets what wasn't taken). The next [answer] carries what it noted as userActions ([takeUserActions]):
  /// taps (press, toggle, select), typing (write: one per field per burst, never a password's text), going to another page (navigate,
  /// back). Never the kit's own calls; scrolling isn't noted.
  void watchUser(bool on) {
    if (on == _watching) return;
    _watching = on;
    final pointers = GestureBinding.instance.pointerRouter;
    if (on) {
      pointers.addGlobalRoute(_onPointer);
      FocusManager.instance.addListener(_onFocus);
      if (!_framesHooked) {
        _framesHooked = true;
        WidgetsBinding.instance.addPersistentFrameCallback(_onFrame);
      }
      _trail = [?routes?.current()];
      _onFocus();
    } else {
      pointers.removeGlobalRoute(_onPointer);
      FocusManager.instance.removeListener(_onFocus);
      _follow(null);
      _downs.clear();
      _userActions.clear();
      _lastFrom = null;
    }
  }

  /// Whether [watchUser] is on.
  bool get watchingUser => _watching;

  /// What the user did since it was last taken (oldest first), taken: [answer] puts it in its answer — an app that answers its own
  /// way does the same, before it reads the screen (the screen it sends is then the one after it all).
  List<UserAction> takeUserActions() {
    final out = List.of(_userActions);
    _userActions.clear();
    _lastFrom = null;
    return out;
  }

  void _note(UserAction action, {Object? from, bool merge = false}) {
    if (merge && from != null && identical(from, _lastFrom)) {
      _userActions.last = action;
    } else {
      _userActions.add(action);
      if (_userActions.length > _maxUserActions) _userActions.removeAt(0);
    }
    _lastFrom = from;
    onUserAction?.call(action);
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  UserActionNode _nodeOf(_AffordState e) =>
      UserActionNode(id: e.id, key: e.fullKey, role: e.role, name: e.label);

  /// Where each finger went down (a tap is one that comes up about there).
  final _downs = <int, Offset>{};

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (!_own) _downs[event.pointer] = event.position;
    } else if (event is PointerUpEvent) {
      final from = _downs.remove(event.pointer);
      // (a tap: not a drag, a scroll, nor one of the kit's own)
      if (from == null ||
          _own ||
          (event.position - from).distance > kTouchSlop) {
        return;
      }
      _tapped(event.position, event.viewId);
    } else if (event is PointerCancelEvent) {
      _downs.remove(event.pointer);
    }
  }

  /// A tap of the user's (it hasn't done anything yet: the gesture is won after this): on the nearest afforded widget under the finger
  /// that a tap does something to.
  void _tapped(Offset at, int viewId) {
    final hit = HitTestResult();
    GestureBinding.instance.hitTestInView(hit, at, viewId);
    final byBox = <RenderObject, _AffordState>{};
    for (final e in _entries) {
      final b = e.mounted ? e.box : null;
      if (b == null) continue;
      // (two afforded around the same widget: the inner one)
      final had = byBox[b];
      if (had == null || e.parent == had) byBox[b] = e;
    }
    for (final h in hit.path) {
      final e = byBox[h.target];
      if (e == null) continue;
      // (into a field: what they type there is what counts)
      if (e.role == Role.textbox) return;
      final ops = {
        for (final o in standardOps[e.role] ?? const <OpSpec>[]) o.name,
        for (final o in e.widget.ops) o.name,
      };
      final op = ops.contains('toggle')
          ? 'toggle'
          : ops.contains('select')
          ? 'select'
          : ops.contains('press')
          ? 'press'
          : null;
      if (op == null) continue;
      final state = e.state;
      if (state['disabled'] == true) return;
      _note(
        UserAction(
          at: _now(),
          op: op,
          node: _nodeOf(e),
          value: switch (op) {
            // (what it is about to be)
            'toggle' => state['checked'] == true ? 'off' : 'on',
            'select' => _clip(e.label, 80),
            _ => null,
          },
          route: routes?.current(),
        ),
        from: _aTap,
      );
      return;
    }
  }

  /// The field the user is in, its controller (listened to), and its text as last seen (an edit is when it changes: not the caret).
  EditableTextState? _field;
  TextEditingController? _fieldController;
  String _fieldText = '';

  void _onFocus() {
    final focus = FocusManager.instance.primaryFocus?.context;
    final field = focus?.findAncestorStateOfType<EditableTextState>();
    _follow(field != null && field.mounted ? field : null);
  }

  void _follow(EditableTextState? field) {
    final c = field?.widget.controller;
    _field = field;
    if (identical(c, _fieldController)) return;
    try {
      _fieldController?.removeListener(_onTyped);
    } catch (_) {
      // (the field has gone, and its controller with it)
    }
    _fieldController = c;
    _fieldText = c?.text ?? '';
    c?.addListener(_onTyped);
  }

  void _onTyped() {
    final field = _field, c = _fieldController;
    if (field == null || c == null) return;
    final text = c.text;
    if (text == _fieldText) return;
    _fieldText = text;
    if (!_watching || _own || !field.mounted) return;
    final owner = field.context.findAncestorStateOfType<_AffordState>();
    if (owner == null || owner.kit != this) return;
    _note(
      UserAction(
        at: _now(),
        op: 'write',
        node: _nodeOf(owner),
        // (a password's text never leaves the field)
        value: field.widget.obscureText ? null : _clip(text, 80),
        route: routes?.current(),
      ),
      from: owner,
      merge: true,
    );
  }

  bool _framesHooked = false;

  /// The routes the user has been through while watched (going to the one before is back).
  List<String> _trail = [];

  /// After each frame: whether the page changed (the kit's own going there is followed, not noted).
  void _onFrame(Duration _) {
    if (!_watching) return;
    final now = routes?.current();
    if (now == null || _trail.lastOrNull == now) return;
    final back = _trail.length > 1 && _trail[_trail.length - 2] == now;
    if (back) {
      _trail.removeLast();
    } else {
      _trail.add(now);
      if (_trail.length > 20) _trail.removeAt(0);
    }
    if (_own) return;
    // A tap that opened it (a mail in the list, a page's button): the tap says where it led, rather than another of its own
    final last = _userActions.lastOrNull;
    if (last != null &&
        identical(_lastFrom, _aTap) &&
        _now() - last.at < 1500) {
      _note(last.copyWith(route: now), from: _aTap, merge: true);
      _lastFrom = null;
      return;
    }
    _note(UserAction(at: _now(), op: back ? 'back' : 'navigate', route: now));
  }

  /// An agent's request (from its side — AffordAgent — over the app's own transport, JSON both ways) answered: {look: true} → the
  /// screen (with picture: true, a picture of it too); {calls: [...]} → the calls run, and the screen after.
  Future<Map<String, Object?>> answer(Map<String, Object?> request) async {
    try {
      final calls = request['calls'];
      if (calls is List) {
        final done = await execute([
          for (final c in calls)
            Call.fromJson((c as Map).cast<String, Object?>()),
        ]);
        // (what the user did before the calls: nothing is noted while they run, so the screen after them is after it all)
        final meanwhile = takeUserActions();
        return {
          ...done.toJson(),
          if (meanwhile.isNotEmpty)
            'userActions': [for (final a in meanwhile) a.toJson()],
        };
      }
      final shot = request['picture'] == true ? await picture() : null;
      final meanwhile = takeUserActions();
      return {
        'context': context().toJson(),
        'picture': ?shot,
        if (meanwhile.isNotEmpty)
          'userActions': [for (final a in meanwhile) a.toJson()],
      };
    } catch (error) {
      return {
        'error': '$error',
        'code': (error is AffordError ? error.code : ErrorCode.failed).wire,
      };
    }
  }

  /// A picture of the screen as the user sees it (the app under the [AffordPreviewHost]), or of a part of it ([rect], global
  /// coordinates): PNG, at most [maxSide] pixels a side, as {type: image, mime, data (base64), width, height}. Null without a host.
  Future<Map<String, Object?>?> picture({
    Rect? rect,
    int maxSide = 1024,
  }) async {
    final host = _previewHost;
    final boundary = host?._shot.currentContext?.findRenderObject();
    if (host == null ||
        boundary is! RenderRepaintBoundary ||
        !boundary.hasSize) {
      return null;
    }
    final origin = boundary.localToGlobal(Offset.zero);
    final whole = origin & boundary.size;
    final area = (rect ?? whole).intersect(whole);
    if (area.isEmpty) return null;
    final ratio = math.min(
      View.of(host.context).devicePixelRatio,
      maxSide / math.max(area.width, area.height),
    );
    final image = await boundary.toImage(pixelRatio: ratio);
    var out = image;
    if (rect != null) {
      // (the part asked for, cut out of the whole)
      final src = Rect.fromLTWH(
        (area.left - origin.dx) * ratio,
        (area.top - origin.dy) * ratio,
        area.width * ratio,
        area.height * ratio,
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
          .drawImageRect(image, src, Offset.zero & src.size, Paint());
      out = await recorder.endRecording().toImage(
        math.max(1, src.width.round()),
        math.max(1, src.height.round()),
      );
    }
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    return {
      'type': 'image',
      'mime': 'image/png',
      'data': base64Encode(bytes.buffer.asUint8List()),
      'width': out.width,
      'height': out.height,
    };
  }

  /// An agent in the app itself: its tools on this kit, straight (no transport). [present] says whether the user is in the app
  /// (default: the app's lifecycle — not paused, hidden or detached); [onHandoff] takes the handoffs it leaves when they are not.
  AffordAgent agent({
    Duration timeout = const Duration(seconds: 45),
    bool wholeScreen = false,
    bool Function()? present,
    FutureOr<String?> Function(Handoff handoff)? onHandoff,
    Duration handoffTtl = const Duration(hours: 24),
  }) => AffordAgent(
    send: answer,
    timeout: timeout,
    wholeScreen: wholeScreen,
    present: present ?? _inForeground,
    onHandoff: onHandoff,
    handoffTtl: handoffTtl,
  );

  /// Whether the app is in the foreground (frames are drawn): not paused, hidden or detached.
  static bool _inForeground() => !const {
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.detached,
  }.contains(WidgetsBinding.instance.lifecycleState);

  /// A handoff an agent left (see [Handoff]), run when the user is back — they tapped its notification: its route first (shown
  /// before going on), then its calls in order, as the agent's calls run (policies and all, each step through [onAct]: deny is never
  /// run, confirm asks — [confirm] here, else the kit's; without either it stops there, not done). Stops at the first that fails.
  /// An expired one is not run.
  ///
  /// Only run one your app got over its own authenticated channel (fetched by the id in the notification, never taken from the
  /// notification or a link itself), and only once.
  Future<HandoffResult> runHandoff(
    Handoff handoff, {
    Future<bool> Function(Call call, {AffordNode? node, ToolSpec? tool})?
    confirm,
    DateTime? now,
  }) async {
    _busy++;
    try {
      return await _runHandoff(handoff, confirm: confirm, now: now);
    } finally {
      _calmDown();
    }
  }

  Future<HandoffResult> _runHandoff(
    Handoff handoff, {
    Future<bool> Function(Call call, {AffordNode? node, ToolSpec? tool})?
    confirm,
    DateTime? now,
  }) async {
    final results = <CallResult>[];
    HandoffResult stop(int at, ErrorCode code, String error) => HandoffResult(
      ok: false,
      ran: math.max(0, at),
      stoppedAt: at,
      code: code,
      error: error,
      results: results,
    );
    final problem = handoffProblem(handoff.toJson());
    if (problem != null) return stop(-1, ErrorCode.badArgs, problem);
    if (handoff.isExpired(now)) {
      return stop(
        -1,
        ErrorCode.expired,
        'This handoff has expired: it was not run',
      );
    }
    if (_last.isEmpty) context();
    _fetched.removeWhere((_, v) => !v.$1.mounted);
    final route = handoff.route;
    if (route != null) {
      final r = await _run(NavigateCall(route));
      results.add(r);
      if (!r.ok) {
        return stop(
          -1,
          r.code ?? ErrorCode.failed,
          r.error ?? 'Could not go there',
        );
      }
    }
    for (final (i, c) in handoff.calls.indexed) {
      final r = await _run(c.toCall(), confirm: confirm);
      results.add(r);
      if (!r.ok) {
        return stop(i, r.code ?? ErrorCode.failed, r.error ?? 'It failed');
      }
      // (what it changed shows before the next: a press that opens what the next one works on)
      await _frames();
    }
    return HandoffResult(ok: true, ran: handoff.calls.length, results: results);
  }

  /// Run the agent's calls in order; the results, and the context afterwards (its next round).
  Future<ExecuteResult> execute(List<Call> calls) async {
    _busy++;
    try {
      return await _execute(calls);
    } finally {
      _calmDown();
    }
  }

  Future<ExecuteResult> _execute(List<Call> calls) async {
    if (_last.isEmpty) context();
    // Entries fetched before that are gone since: their nodes go
    _fetched.removeWhere((_, v) => !v.$1.mounted);
    final results = <CallResult>[];
    for (final call in calls) {
      results.add(await _run(call));
    }
    // Let what the calls changed build before looking again (not forever: no frames come while the app is in the background)
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
    if (settle case final s?) await s();
    return ExecuteResult(results, context());
  }

  Future<CallResult?> _allowed(
    Policy policy,
    Call call, {
    AffordNode? node,
    ToolSpec? tool,
    Future<bool> Function(Call call, {AffordNode? node, ToolSpec? tool})? ask,
  }) async {
    if (policy == Policy.allow) return null;
    if (policy == Policy.deny) {
      return CallResult(
        call,
        ok: false,
        code: ErrorCode.denied,
        error: 'Not allowed: the user does this themselves',
      );
    }
    ask ??= confirm;
    if (ask == null) {
      return CallResult(
        call,
        ok: false,
        needsConfirm: true,
        code: ErrorCode.needsConfirm,
        error: 'Needs the user to confirm first',
      );
    }
    return await ask(call, node: node, tool: tool)
        ? null
        : CallResult(
            call,
            ok: false,
            code: ErrorCode.declined,
            error: 'The user said no',
          );
  }

  /// One call run ([confirm]: who is asked before a confirm op, over the kit's own).
  Future<CallResult> _run(
    Call call, {
    Future<bool> Function(Call call, {AffordNode? node, ToolSpec? tool})?
    confirm,
  }) async {
    try {
      switch (call) {
        case NavigateCall(:final route):
          final r = routes;
          if (r == null) {
            return CallResult(
              call,
              ok: false,
              code: ErrorCode.notFound,
              error: 'This app has no routes',
            );
          }
          if (route == 'back') {
            if (r.back == null || r.canGoBack?.call() == false) {
              return CallResult(
                call,
                ok: false,
                code: ErrorCode.notFound,
                error: 'Nowhere to go back to',
              );
            }
            await r.back!();
          } else {
            if (findRoute(r.routes, route) == null) {
              return CallResult(
                call,
                ok: false,
                code: ErrorCode.notFound,
                error:
                    'No route $route (the routes: ${r.routes.map((x) => x.path).join(', ')})',
              );
            }
            await r.navigate(route);
          }
          // The new page shows before the next call (which may act on it by key)
          await (r.settle?.call() ?? _frames());
          context();
          return CallResult(call, ok: true, value: r.current());
        case PeekCall(:final route):
          return CallResult(call, ok: true, value: await peek(route));
        case ToolCall(:final tool, :final args):
          final t = _tools[tool];
          if (t == null) {
            return CallResult(
              call,
              ok: false,
              code: ErrorCode.notFound,
              error: 'No tool $tool',
            );
          }
          final spec = ToolSpec(t.name, t.description, policy: t.policy);
          final blocked = await _allowed(
            t.policy,
            call,
            tool: spec,
            ask: confirm,
          );
          if (blocked != null) return blocked;
          return CallResult(call, ok: true, value: await t.execute(args));
        case NodeCall(:final node, :final op, :final args):
          if (node.startsWith('peek:')) {
            return CallResult(
              call,
              ok: false,
              code: ErrorCode.notFound,
              error: 'That id is from a peek: navigate to the page first, then use the key (or look again)',
            );
          }
          final hit = await _resolve(node);
          if (hit == null) {
            return CallResult(
              call,
              ok: false,
              code: ErrorCode.notFound,
              error:
                  'No node $node on screen (it may have gone: look at the tree again)',
            );
          }
          final (e, n) = hit;
          final spec = n.ops.where((o) => o.name == op).firstOrNull;
          if (spec == null) {
            return CallResult(
              call,
              ok: false,
              code: ErrorCode.noOp,
              error:
                  '${n.role.wire} "${n.name}" has no op $op (it has: ${n.ops.map((o) => o.name).join(', ')})',
            );
          }
          final blocked = await _allowed(
            spec.policy,
            call,
            node: n,
            ask: confirm,
          );
          if (blocked != null) return blocked;
          final custom = e.widget.ops.where((o) => o.name == op).firstOrNull;
          final containerOp =
              custom == null &&
              e.isContainer &&
              const {'item', 'items', 'scroll_to', 'scroll'}.contains(op);
          // (shown for what changes something on screen: not reads, nor the container fetching its entries)
          // (whether a finger reaches it: worked out for this one widget, now)
          final reach =
              custom != null || containerOp || op == 'read' || _reachable(e);
          if (op != 'read' && !containerOp) {
            await onAct?.call(
              ActEvent(
                node: n,
                op: op,
                args: args,
                rect: reach ? e.rect : null,
                behind: !reach,
              ),
            );
          }
          if (custom != null) {
            return CallResult(call, ok: true, value: await custom.run(args));
          }
          if (containerOp) {
            return CallResult(
              call,
              ok: true,
              value: await _containerOp(e, n, op, args),
            );
          }
          if (!e.mounted) {
            return CallResult(
              call,
              ok: false,
              code: ErrorCode.notFound,
              error: '"${n.name}" went away',
            );
          }
          return CallResult(
            call,
            ok: true,
            value: await _standard(e, n, op, args, reach: reach),
          );
      }
    } catch (error) {
      return CallResult(
        call,
        ok: false,
        code: error is AffordError ? error.code : ErrorCode.failed,
        error: '$error',
      );
    }
  }

  Future<Object?> _standard(
    _AffordState e,
    AffordNode n,
    String op,
    Map<String, Object?> args, {
    bool reach = true,
  }) async {
    String text(Object? v) => v is String ? v : '${v ?? ''}';
    switch (op) {
      case 'press':
      case 'select':
      case 'toggle':
        if (n.state?['disabled'] == true) {
          throw AffordError(ErrorCode.disabled, '"${n.name}" is disabled');
        }
        _press(e, n, reach);
        return null;
      case 'set':
        if ((n.state?['checked'] == true) != (args['on'] == true)) {
          _press(e, n, reach);
        }
        return null;
      case 'read':
        return e.role == Role.textbox
            ? (e.editable?.textEditingValue.text ?? '')
            : e.text;
      case 'view':
        // (what is over it would be in the picture instead)
        if (!reach) {
          throw AffordError(
            ErrorCode.unreachable,
            e.onScreen
                ? '"${n.name}" has something over it: close that first'
                : '"${n.name}" is not on screen: bring it in first',
          );
        }
        final shot = await picture(rect: e.rect);
        if (shot == null) {
          throw const AffordError(
            ErrorCode.unavailable,
            'No picture can be taken here (the app has no AffordPreviewHost)',
          );
        }
        return shot;
      case 'write':
      case 'append':
      case 'clear':
        final field = e.editable;
        if (field == null) {
          throw AffordError(ErrorCode.noOp, 'No text field in "${n.name}"');
        }
        final base = op == 'append' ? field.textEditingValue.text : '';
        final next = op == 'clear' ? '' : base + text(args['text']);
        if (field.widget.readOnly) {
          throw AffordError(ErrorCode.disabled, '"${n.name}" is read-only');
        }
        // As if typed: the field's controller and its onChanged see it (a few characters at a time, with typeDelay)
        void put(String v) {
          field.widget.controller.value = TextEditingValue(
            text: v,
            selection: TextSelection.collapsed(offset: v.length),
          );
          field.widget.onChanged?.call(v);
        }

        final delay = typeDelay;
        final added = next.length - base.length;
        if (delay != null && op != 'clear' && added > 0) {
          final steps = (1500 ~/ math.max(1, delay.inMilliseconds)).clamp(
            1,
            added,
          );
          final chunk = (added / steps).ceil();
          for (var i = base.length + chunk; i < next.length; i += chunk) {
            put(next.substring(0, i));
            await Future<void>.delayed(delay);
            if (!e.mounted) return null;
          }
        }
        put(next);
        return null;
    }
    throw AffordError(ErrorCode.noOp, 'No way to $op a ${n.role.wire}');
  }

  /// Whether a finger in the middle of the widget reaches it (nothing over it: another page, a dialog's barrier).
  bool _reachable(_AffordState e) {
    final b = e.box;
    if (b == null || !e.onScreen) return false;
    final view = View.maybeOf(e.context);
    if (view == null) return true;
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(
      result,
      b.localToGlobal(b.size.center(Offset.zero)),
      view.viewId,
    );
    return result.path.any((h) => identical(h.target, b));
  }

  /// A press: a tap where a finger reaches it, else the control's own callback.
  void _press(_AffordState e, AffordNode n, bool reach) {
    if (reach) return _tap(e);
    final callback = _callbackOf(e);
    if (callback == null) {
      throw AffordError(
        ErrorCode.unreachable,
        '"${n.name}" can\'t be reached (something is over it) and has no callback to call: go to its page first',
      );
    }
    callback();
  }

  /// The tap of the control in the widget, as a callback: a button's onPressed, an InkWell's or a ListTile's onTap, a switch's or
  /// a checkbox's onChanged (the other way).
  VoidCallback? _callbackOf(_AffordState e) {
    VoidCallback? found;
    var stop = false;
    void visit(Element el) {
      if (stop) return;
      final VoidCallback? tap = switch (el.widget) {
        ButtonStyleButton(:final onPressed) => onPressed,
        IconButton(:final onPressed) => onPressed,
        FloatingActionButton(:final onPressed) => onPressed,
        SwitchListTile(:final onChanged?, :final value) => () => onChanged(
          !value,
        ),
        Switch(:final onChanged?, :final value) => () => onChanged(!value),
        CheckboxListTile(:final onChanged?, :final value) => () => onChanged(
          !(value ?? false),
        ),
        Checkbox(:final onChanged?, :final value) => () => onChanged(
          !(value ?? false),
        ),
        ListTile(:final onTap) => onTap,
        InkResponse(:final onTap) => onTap,
        GestureDetector(:final onTap) => onTap,
        _ => null,
      };
      if (tap != null) {
        found = tap;
        stop = true;
        return;
      }
      el.visitChildren(visit);
    }

    if (e.mounted) visit(e.context as Element);
    return found;
  }

  /// A tap in the middle of the widget, as a finger would (it reaches whatever is on top there, like a real one).
  void _tap(_AffordState e) {
    final b = e.box;
    if (b == null) throw AffordError(ErrorCode.unreachable, 'Not on screen');
    final at = b.localToGlobal(b.size.center(Offset.zero));
    final pointer = ++_pointer;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: pointer, position: at),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: at),
    );
  }
}

/// Long text cut short for the tree (read gives it all).
String _clip(String text, [int max = 200]) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > max ? '${t.substring(0, max - 1)}…' : t;
}

String _firstLine(String text) {
  final line = text
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
      .trim();
  return line.length > 80 ? line.substring(0, 80) : line;
}

AffordNode _nodeFromJson(Map<String, Object?> j) {
  final role = Role.values.firstWhere(
    (r) => r.wire == j['role'],
    orElse: () => Role.other,
  );
  return AffordNode(
    id: '${j['id']}',
    key: j['key'] as String?,
    role: role,
    name: '${j['name'] ?? ''}',
    value: j['value'] as String?,
    description: j['description'] as String?,
    state: (j['state'] as Map?)?.cast<String, Object>(),
    ops: [
      for (final o in (j['ops'] as List? ?? const []).cast<Map>())
        OpSpec(
          '${o['name']}',
          description: o['description'] as String?,
          params: (o['params'] as Map?)?.cast<String, Object?>(),
          policy: Policy.values.byName('${o['policy'] ?? 'allow'}'),
        ),
    ],
    children: [
      for (final c in (j['children'] as List? ?? const []).cast<Map>())
        _nodeFromJson(c.cast<String, Object?>()),
    ],
    preview: [
      for (final p in (j['preview'] as List? ?? const []).cast<Map>())
        ItemSummary(
          id: '${p['id']}',
          name: '${p['name'] ?? ''}',
          key: p['key'] as String?,
          index: (p['index'] as num?)?.toInt(),
          description: p['description'] as String?,
        ),
    ],
  );
}
