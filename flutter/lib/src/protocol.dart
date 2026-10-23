// The AffordKit protocol in Dart — the same JSON as the TypeScript package (affordkit/js/src/protocol.ts): keep the two in step.
// An app's controls as a tree for an AI agent; the agent's calls; their results.

/// The version of the JSON protocol, sent with every context.
const protocolVersion = 1;

/// What a node is (the same names as on the web).
enum Role {
  /// The whole app.
  app,

  /// A page (a route, or a Scaffold).
  page,

  /// A group of controls kept together.
  region,

  /// A dialog over the page.
  dialog,

  /// Something pressed.
  button,

  /// Something followed to another place.
  link,

  /// A text field.
  textbox,

  /// A checkbox.
  checkbox,

  /// A switch (`switch` on the wire).
  switch_,

  /// One of a group of choices.
  radio,

  /// A dropdown: shows a choice and opens the options.
  select,

  /// A tab.
  tab,

  /// Many of the same thing (a long list): a preview of its entries, fetched one at a time.
  container,

  /// A short list, all in the tree.
  list,

  /// An entry of a list.
  listitem,

  /// A heading.
  heading,

  /// Text to read.
  text,

  /// A picture.
  image,

  /// Anything else.
  other,
}

/// A role's name in the JSON.
extension RoleName on Role {
  /// The name on the wire (`switch` for [Role.switch_]).
  String get wire => this == Role.switch_ ? 'switch' : name;
}

/// Whether the agent may do an op or run a tool.
enum Policy {
  /// Just do it.
  allow,

  /// Only after the user says yes.
  confirm,

  /// The agent sees it, never does it: the user's own act.
  deny,
}

/// An op a node offers: its name, what it does, its arguments and its policy.
class OpSpec {
  /// An op named [name] (`press`, `write`, or one of the app's own).
  const OpSpec(
    this.name, {
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

  /// Whether the agent may do it.
  final Policy policy;

  /// The same op with policy [p].
  OpSpec withPolicy(Policy p) =>
      OpSpec(name, description: description, params: params, policy: p);

  /// The op as JSON.
  Map<String, Object?> toJson() => {
    'name': name,
    'description': ?description,
    'params': ?params,
    'policy': policy.name,
  };
}

/// The AffordTree: the screen's controls as a tree (a context's root).
typedef AffordTree = AffordNode;

/// A control (or a group of them) in the tree the agent reads.
class AffordNode {
  /// A node; the kit builds these from afforded widgets.
  AffordNode({
    required this.id,
    required this.role,
    required this.name,
    this.key,
    this.description,
    this.state,
    this.ops = const [],
    this.children = const [],
    this.preview = const [],
    this.value,
  });

  /// The node's id in this tree (it may change from one look to the next: [key] does not).
  final String id;

  /// A name the app gives it that stays the same across pages and visits: calls may use it instead of the id.
  final String? key;

  /// What it is.
  final Role role;

  /// What the user sees it called.
  final String name;

  /// More about it, for the agent.
  final String? description;

  /// What it says of itself: `checked`, `disabled`, `selected`, `behind`...
  final Map<String, Object>? state;

  /// What the agent can do to it.
  final List<OpSpec> ops;

  /// The nodes inside it.
  List<AffordNode> children;

  /// A container: its entries on screen, in short (capped) — an entry's tree is fetched with its `item` op.
  List<ItemSummary> preview;

  /// What a text, a heading or a part with no controls in it shows, to read without an op (when it isn't its name) — cut short
  /// (ending in …) when long: read gives it all. A field's content isn't here: read it.
  String? value;

  /// The same tree with every id prefixed (a peek's ids, which can't be acted on).
  AffordNode prefixed(String prefix) => AffordNode(
    id: '$prefix$id',
    role: role,
    name: name,
    key: key,
    description: description,
    state: state,
    ops: ops,
    children: [for (final c in children) c.prefixed(prefix)],
    preview: preview,
    value: value,
  );

  /// The node and everything under it as JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'key': ?key,
    'role': role.wire,
    'name': name,
    'description': ?description,
    if (state != null && state!.isNotEmpty) 'state': state,
    'ops': ops.map((o) => o.toJson()).toList(),
    if (children.isNotEmpty)
      'children': children.map((c) => c.toJson()).toList(),
    if (preview.isNotEmpty) 'preview': preview.map((i) => i.toJson()).toList(),
    'value': ?value,
  };
}

/// One entry of a container, as its preview and its `items` op give it (whether or not it is on screen).
class ItemSummary {
  /// An entry with the app's [id] for it and the [name] it shows.
  const ItemSummary({
    required this.id,
    required this.name,
    this.key,
    this.index,
    this.description,
  });

  /// The entry's id within its container (the app's own id, such as a mail's).
  final String id;

  /// What the entry shows, in short.
  final String name;

  /// The entry's key (`<container key>[<id>]`), to fetch it or act on it — when the container has a key.
  final String? key;

  /// Its place in the container, when known.
  final int? index;

  /// More about it, for the agent.
  final String? description;

  /// The same entry with [key], and [index] if it had none.
  ItemSummary withKey(String? key, int? index) => ItemSummary(
    id: id,
    name: name,
    key: key,
    index: this.index ?? index,
    description: description,
  );

  /// The entry as JSON.
  Map<String, Object?> toJson() => {
    'key': ?key,
    'id': id,
    'index': ?index,
    'name': name,
    'description': ?description,
  };
}

/// A page of a container's entries: the `items` op's answer ([count]: all of them, when known).
class ItemsPage {
  /// The entries from [offset] on.
  const ItemsPage({required this.offset, required this.items, this.count});

  /// How many entries there are in all, when known.
  final int? count;

  /// The index of the first entry in [items].
  final int offset;

  /// The entries on this page.
  final List<ItemSummary> items;

  /// The page as JSON.
  Map<String, Object?> toJson() => {
    'count': ?count,
    'offset': offset,
    'items': items.map((i) => i.toJson()).toList(),
  };
}

/// Where an entry's tree came from.
enum ItemSource {
  /// On screen: its ids can be acted on.
  live,

  /// Built off screen: act by key, which brings it in.
  preview,
}

/// One entry of a container, fetched (the `item` op's answer): a tree of its own, rooted at the entry.
class ItemTree {
  /// The tree of entry [id], from [source].
  const ItemTree({
    required this.id,
    required this.source,
    required this.root,
    this.key,
    this.index,
  });

  /// The entry's id within its container.
  final String id;

  /// The entry's key (`<container key>[<id>]`), when the container has a key.
  final String? key;

  /// Its place in the container, when known.
  final int? index;

  /// Whether the tree is on screen or built off screen.
  final ItemSource source;

  /// The entry and its controls.
  final AffordNode root;

  /// The entry's tree as JSON.
  Map<String, Object?> toJson() => {
    'key': ?key,
    'id': id,
    'index': ?index,
    'source': source.name,
    'root': root.toJson(),
  };
}

/// An entry's key: the container's key and the entry's id (mail.list + 42 → mail.list[42]).
String itemKey(String containerKey, String id) => '$containerKey[$id]';

/// The innermost entry a key names: mail.list[42].star → (list: mail.list — the container's key, id: 42, rest: .star); null when it names none.
({String list, String id, String rest})? parseItemKey(String key) {
  final m = RegExp(r'^(.+)\[([^[\]]+)\](.*)$').firstMatch(key);
  return m == null
      ? null
      : (list: m.group(1)!, id: m.group(2)!, rest: m.group(3)!);
}

/// One of the app's own tools as the agent sees it (what needs no screen, such as set_theme).
class ToolSpec {
  /// A tool named [name] that does what [description] says.
  const ToolSpec(
    this.name,
    this.description, {
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

  /// The tool as JSON.
  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': ?inputSchema,
    'policy': policy.name,
  };
}

/// What a route's :param can be.
class RouteParam {
  /// A param, with what it means and the [values] it can take.
  const RouteParam({this.description, this.values});

  /// What it stands for.
  final String? description;

  /// The values it can take, when there are few.
  final List<String>? values;

  /// The param as JSON.
  Map<String, Object?> toJson() => {
    'description': ?description,
    'values': ?values,
  };
}

/// A place in the app the agent can go to: a pattern such as /settings/:tab.
class RouteSpec {
  /// The route [path] (with :params, or a trailing `*`) and what is there.
  const RouteSpec(this.path, this.description, {this.params = const {}});

  /// The pattern, such as /message/:id.
  final String path;

  /// What is on the page, for the agent.
  final String description;

  /// What each :param in [path] can be.
  final Map<String, RouteParam> params;

  /// The route as JSON.
  Map<String, Object?> toJson() => {
    'path': path,
    'description': description,
    if (params.isNotEmpty)
      'params': {for (final e in params.entries) e.key: e.value.toJson()},
  };
}

/// Where the user is (the pattern it is, its params), whether back goes somewhere, and where the agent can go.
class RouteState {
  /// The user is at [current].
  const RouteState({
    required this.current,
    this.pattern,
    this.params = const {},
    this.canGoBack,
    this.routes = const [],
  });

  /// The route showing now, such as /message/42.
  final String current;

  /// The declared route [current] matches, such as /message/:id.
  final String? pattern;

  /// The :params of [pattern] in [current].
  final Map<String, String> params;

  /// Whether back goes somewhere (null: the app does not say).
  final bool? canGoBack;

  /// The routes the agent can go to.
  final List<RouteSpec> routes;

  /// The state as JSON.
  Map<String, Object?> toJson() => {
    'current': current,
    'pattern': ?pattern,
    if (pattern != null) 'params': params,
    'canGoBack': ?canGoBack,
    'routes': routes.map((r) => r.toJson()).toList(),
  };
}

/// What the agent sees of the app: the tree, the app's tools, and where the user is.
class AffordContext {
  /// The screen as a tree under [root].
  AffordContext({required this.root, this.tools = const [], this.route});

  /// The top of the tree.
  final AffordNode root;

  /// The app's own tools.
  final List<ToolSpec> tools;

  /// Where the user is and where the agent can go, when the app declares routes.
  final RouteState? route;

  /// The route showing now, if known.
  String? get currentRoute => route?.current;

  /// The context as JSON (with [protocolVersion]).
  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    if (route != null) 'route': route!.toJson(),
    'root': root.toJson(),
    'tools': tools.map((t) => t.toJson()).toList(),
  };
}

/// Where a peek's tree came from.
enum PageSource {
  /// The page showing now.
  live,

  /// Built off screen just now.
  preview,

  /// As it last showed (see [PagePeek.seenAt]).
  seen,

  /// Never seen: only its declared route, no tree.
  declared,
}

/// Another page's tree, peeked at without going there (its ids can't be acted on: navigate, then act by key).
class PagePeek {
  /// A peek at [route], from [source].
  const PagePeek({
    required this.route,
    required this.source,
    this.pattern,
    this.description,
    this.seenAt,
    this.root,
  });

  /// The route peeked at.
  final String route;

  /// Where the tree came from.
  final PageSource source;

  /// The declared route it matches.
  final String? pattern;

  /// The declared route's description.
  final String? description;

  /// When it was last seen, for [PageSource.seen].
  final DateTime? seenAt;

  /// The page's tree (null for [PageSource.declared]).
  final AffordNode? root;

  /// The peek as JSON.
  Map<String, Object?> toJson() => {
    'route': route,
    'pattern': ?pattern,
    'source': source.name,
    if (seenAt != null) 'seenAt': seenAt!.millisecondsSinceEpoch,
    'description': ?description,
    if (root != null) 'root': root!.toJson(),
  };
}

/// A route's params if it is this pattern (/settings/:tab against /settings/ai → {tab: ai}), else null.
Map<String, String>? matchRoute(String pattern, String route) {
  List<String> split(String p) => p
      .split(RegExp('[?#]'))
      .first
      .split('/')
      .where((x) => x.isNotEmpty)
      .toList();
  final want = split(pattern), got = split(route);
  final tail = want.isNotEmpty && want.last == '*';
  if (tail ? got.length < want.length - 1 : got.length != want.length) {
    return null;
  }
  final params = <String, String>{};
  for (var i = 0; i < want.length; i++) {
    final w = want[i];
    if (w == '*') break;
    if (w.startsWith(':')) {
      params[w.substring(1)] = Uri.decodeComponent(got[i]);
    } else if (w != got[i]) {
      return null;
    }
  }
  return params;
}

/// The pattern a route is (the most specific: fewest params), and its params.
(RouteSpec, Map<String, String>)? findRoute(
  List<RouteSpec> routes,
  String route,
) {
  (RouteSpec, Map<String, String>)? best;
  for (final spec in routes) {
    final params = matchRoute(spec.path, route);
    if (params != null && (best == null || params.length < best.$2.length)) {
      best = (spec, params);
    }
  }
  return best;
}

/// One thing the agent asks for: an op on a node, an app-wide tool, or going to a route.
sealed class Call {
  /// For the subclasses.
  const Call();

  /// The call as the agent's JSON.
  Map<String, Object?> toJson();

  /// From the agent's JSON: { node, op, args } | { tool, args } | { navigate } | { peek }.
  static Call fromJson(Map<String, Object?> j) {
    final args = (j['args'] as Map?)?.cast<String, Object?>() ?? const {};
    if (j['navigate'] is String) return NavigateCall(j['navigate'] as String);
    if (j['peek'] is String) return PeekCall(j['peek'] as String);
    if (j['tool'] is String) return ToolCall(j['tool'] as String, args);
    return NodeCall('${j['node']}', '${j['op']}', args);
  }
}

/// An op on a node.
class NodeCall extends Call {
  /// Do [op] on [node] with [args].
  const NodeCall(this.node, this.op, [this.args = const {}]);

  /// The node's id or key (an entry's key, such as mail.list[42].reply, works even off screen).
  final String node;

  /// The op's name.
  final String op;

  /// The op's arguments.
  final Map<String, Object?> args;

  @override
  Map<String, Object?> toJson() => {
    'node': node,
    'op': op,
    if (args.isNotEmpty) 'args': args,
  };
}

/// One of the app's own tools.
class ToolCall extends Call {
  /// Run [tool] with [args].
  const ToolCall(this.tool, [this.args = const {}]);

  /// The tool's name.
  final String tool;

  /// The tool's arguments.
  final Map<String, Object?> args;

  @override
  Map<String, Object?> toJson() => {
    'tool': tool,
    if (args.isNotEmpty) 'args': args,
  };
}

/// Go to a route, or "back".
class NavigateCall extends Call {
  /// Go to [route].
  const NavigateCall(this.route);

  /// The route, or "back".
  final String route;

  @override
  Map<String, Object?> toJson() => {'navigate': route};
}

/// Another page's tree, without going there (the value: a PagePeek).
class PeekCall extends Call {
  /// Peek at [route].
  const PeekCall(this.route);

  /// The route to peek at.
  final String route;

  @override
  Map<String, Object?> toJson() => {'peek': route};
}

/// Why a call failed, for the agent's loop to act on (the error says it in words).
enum ErrorCode {
  /// No such node (it went), route, tool or entry.
  notFound('not_found'),

  /// The node has no such op.
  noOp('no_op'),

  /// The op's arguments are missing or wrong.
  badArgs('bad_args'),

  /// Policy deny: the user does this themselves.
  denied('denied'),

  /// Policy confirm, and the app gave no way to ask: nothing was done.
  needsConfirm('needs_confirm'),

  /// The user was asked and said no.
  declined('declined'),

  /// The control is disabled (or read-only).
  disabled('disabled'),

  /// Something is over it (a dialog, another page) and it can't be worked from there.
  unreachable('unreachable'),

  /// The app did not answer in time.
  timeout('timeout'),

  /// There is no app to work, or it could not answer.
  unavailable('unavailable'),

  /// The user is not in the app now (it is in the background): its screen can't be looked at or worked.
  away('away'),

  /// A handoff past its expiresAt: not run.
  expired('expired'),

  /// Anything else that went wrong doing it.
  failed('failed');

  const ErrorCode(this.wire);

  /// The code in the JSON, such as `not_found`.
  final String wire;

  /// The code for [wire], or null if there is none.
  static ErrorCode? fromWire(Object? wire) =>
      values.where((c) => c.wire == wire).firstOrNull;
}

/// An error with its code (thrown by the kit, and by an app's own ops when it wants to say which).
class AffordError implements Exception {
  /// An error with [code], and [message] for the agent.
  const AffordError(this.code, this.message);

  /// Why it failed.
  final ErrorCode code;

  /// Why it failed, in words.
  final String message;

  @override
  String toString() => message;
}

/// What came of one call.
class CallResult {
  /// The result of [call].
  const CallResult(
    this.call, {
    required this.ok,
    this.value,
    this.error,
    this.needsConfirm = false,
    this.code,
  });

  /// The call this answers.
  final Call call;

  /// Whether it was done.
  final bool ok;

  /// What it gave back: a read's text, an op's or tool's answer, a [PagePeek], [ItemsPage] or [ItemTree].
  final Object? value;

  /// Why it failed, in words.
  final String? error;

  /// The op needs the user's yes and the app gave no way to ask: nothing was done.
  final bool needsConfirm;

  /// Why it failed.
  final ErrorCode? code;

  /// The result as JSON.
  Map<String, Object?> toJson() => {
    'call': call.toJson(),
    'ok': ok,
    'value': ?switch (value) {
      PagePeek v => v.toJson(),
      ItemsPage v => v.toJson(),
      ItemTree v => v.toJson(),
      _ => value,
    },
    'error': ?error,
    'code': ?code?.wire,
    if (needsConfirm) 'needsConfirm': true,
  };
}

/// The results, and the context as it is afterwards (the agent's next round).
class ExecuteResult {
  /// The [results] of the calls, in order, and the [context] after them.
  const ExecuteResult(this.results, this.context);

  /// One result per call, in order.
  final List<CallResult> results;

  /// The tree after the calls.
  final AffordContext context;

  /// The results and context as JSON.
  Map<String, Object?> toJson() => {
    'results': results.map((r) => r.toJson()).toList(),
    'context': context.toJson(),
  };
}

/// Something the user did themselves while the agent was working their screen (the kit's own calls are never these), noted while
/// the app has the kit watching (AffordKit.watchUser). An answer carries them as `userActions`, oldest first, with the AffordTree (the
/// context's root) as it is after them. Named the way the agent would have called it, so it reads the same: press, write, toggle,
/// select on a node; navigate (to [route]) or back.
class UserAction {
  /// The user did [op] (on [node]) at [at].
  const UserAction({
    required this.at,
    required this.op,
    this.node,
    this.value,
    this.route,
  });

  /// When, in ms since the epoch.
  final int at;

  /// What, named as the agent's op would be.
  final String op;

  /// The node, as the tree had it then (its key when it has one: ids may have gone since). None for navigate and back.
  final UserActionNode? node;

  /// What they typed or picked, cut short (never what goes into a password field).
  final String? value;

  /// The route after it.
  final String? route;

  /// The same, with another [at], [value] or [route].
  UserAction copyWith({int? at, String? value, String? route}) => UserAction(
    at: at ?? this.at,
    op: op,
    node: node,
    value: value ?? this.value,
    route: route ?? this.route,
  );

  /// The action as JSON.
  Map<String, Object?> toJson() => {
    'at': at,
    'op': op,
    'node': ?node?.toJson(),
    'value': ?value,
    'route': ?route,
  };

  /// An action from its JSON.
  factory UserAction.fromJson(Map<String, Object?> j) {
    final node = j['node'];
    return UserAction(
      at: (j['at'] as num?)?.toInt() ?? 0,
      op: '${j['op'] ?? ''}',
      node: node is Map
          ? UserActionNode.fromJson(node.cast<String, Object?>())
          : null,
      value: j['value'] as String?,
      route: j['route'] as String?,
    );
  }
}

/// The node a [UserAction] was on: its id, key, role and name as the tree had them.
class UserActionNode {
  /// The node [id] (and [key]): a [role] called [name].
  const UserActionNode({
    required this.id,
    this.key,
    required this.role,
    required this.name,
  });

  /// Its id in the tree then.
  final String id;

  /// Its key, when it has one.
  final String? key;

  /// What it is.
  final Role role;

  /// What the user sees it called.
  final String name;

  /// The node as JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'key': ?key,
    'role': role.wire,
    'name': name,
  };

  /// A node from its JSON.
  factory UserActionNode.fromJson(Map<String, Object?> j) => UserActionNode(
    id: '${j['id']}',
    key: j['key'] as String?,
    role: Role.values.firstWhere(
      (r) => r.wire == j['role'],
      orElse: () => Role.other,
    ),
    name: '${j['name'] ?? ''}',
  );
}

/// One step of a handoff: an op on a control by its key (a handoff runs later, when ids from a look have long gone).
class HandoffCall {
  /// Do [op] on the control with [key], with [args].
  const HandoffCall(this.key, this.op, [this.args = const {}]);

  /// The control's key (an entry's key, such as drafts.list[42], works even off screen).
  final String key;

  /// The op's name.
  final String op;

  /// The op's arguments.
  final Map<String, Object?> args;

  /// The call the app runs for it.
  NodeCall toCall() => NodeCall(key, op, args);

  /// The step as JSON.
  Map<String, Object?> toJson() => {
    'key': key,
    'op': op,
    if (args.isNotEmpty) 'args': args,
  };
}

/// Most calls in a handoff.
const handoffMaxCalls = 20;

/// Longest message of a handoff.
const handoffMaxMessage = 500;

/// What an agent leaves for a user who is away (the app in the background): a short message, and the calls that take them to what
/// it did when they come back — the page first ([route]), then ops there by key. The host keeps it and tells the user (a
/// notification, usually); when they tap it, the app runs it (AffordKit.runHandoff). One-shot, and it expires.
class Handoff {
  /// A handoff saying [message].
  const Handoff({
    required this.message,
    this.calls = const [],
    this.route,
    this.expiresAt,
    this.id,
  });

  /// The version of the handoff's JSON (`v`).
  static const version = 1;

  /// What the agent did and what is waiting, for the user (at most [handoffMaxMessage] characters).
  final String message;

  /// Where to go first: a route of the app (one of the context's routes, filled in).
  final String? route;

  /// Then these, in order (at most [handoffMaxCalls]).
  final List<HandoffCall> calls;

  /// When it stops being good (ms since the epoch on the wire).
  final DateTime? expiresAt;

  /// The host's id for it, set when it stores it.
  final String? id;

  /// Whether its time is up (at [now], default now).
  bool isExpired([DateTime? now]) =>
      expiresAt != null && !expiresAt!.isAfter(now ?? DateTime.now());

  /// The same handoff with the host's [id] for it.
  Handoff withId(String id) => Handoff(
    message: message,
    calls: calls,
    route: route,
    expiresAt: expiresAt,
    id: id,
  );

  /// The handoff as JSON.
  Map<String, Object?> toJson() => {
    'v': version,
    'message': message,
    'route': ?route,
    'calls': calls.map((c) => c.toJson()).toList(),
    if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
    'id': ?id,
  };
}

/// Whether a node ref is an id from a look (the kit's: n12, w4, p3, app, behind-2, peek:…) rather than a key the app gave.
bool _isLookId(String ref) =>
    ref.startsWith('peek:') ||
    RegExp(r'^(?:[nwp]\d+|app|behind-\d+)$').hasMatch(ref);

/// What is wrong with something given as a handoff (its JSON: its shape, not whether it expired), or null when it is one.
String? handoffProblem(Object? input) {
  if (input is! Map) {
    return 'A handoff is an object: { message, route?, calls? }';
  }
  final v = input['v'];
  if (v != null && v != Handoff.version) return 'Unknown handoff version $v';
  final m = input['message'];
  final message = m is String ? m.trim() : '';
  if (message.isEmpty) return 'Say what you did in message: the user reads it';
  if (message.length > handoffMaxMessage) {
    return 'message is too long (${message.length} characters, at most $handoffMaxMessage)';
  }
  final route = input['route'];
  if (input.containsKey('route') &&
      (route is! String || route.trim().isEmpty || route.trim() == 'back')) {
    return 'route is a route of the app (e.g. /drafts), or left out';
  }
  final expiresAt = input['expiresAt'];
  if (input.containsKey('expiresAt') &&
      (expiresAt is! num || !expiresAt.isFinite)) {
    return 'expiresAt is a time in ms';
  }
  if (input.containsKey('id') && input['id'] is! String) {
    return 'id is a string';
  }
  final calls = input['calls'] ?? const [];
  if (calls is! List) return 'calls is a list of { key, op, args? }';
  if (calls.length > handoffMaxCalls) {
    return 'Too many calls (${calls.length}, at most $handoffMaxCalls): take the user to the result, no more';
  }
  for (final (i, c) in calls.indexed) {
    // (a key, as ui_act's node or as key)
    final key = c is Map ? (c['key'] ?? c['node']) : null;
    if (c is! Map ||
        key is! String ||
        key.isEmpty ||
        c['op'] is! String ||
        (c['op'] as String).isEmpty) {
      return 'calls[$i] is not { key, op, args? }';
    }
    if (_isLookId(key)) {
      return "calls[$i]: $key is an id from a look, gone by the time the user comes back: use the control's key";
    }
    if (c.containsKey('args') && c['args'] is! Map) {
      return 'calls[$i].args is an object';
    }
  }
  return null;
}

/// Something given as a handoff (the agent's input, what the host stored: its JSON), checked; null when it isn't one or it expired
/// (at [now], default now).
Handoff? parseHandoff(Object? input, {DateTime? now}) {
  if (handoffProblem(input) != null) return null;
  final j = (input as Map).cast<String, Object?>();
  final at = j['expiresAt'] as num?;
  final h = Handoff(
    message: (j['message'] as String).trim(),
    route: (j['route'] as String?)?.trim(),
    calls: [
      for (final c in (j['calls'] as List? ?? const []).cast<Map>())
        HandoffCall(
          (c['key'] ?? c['node']) as String,
          c['op'] as String,
          (c['args'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
    ],
    expiresAt: at == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(at.toInt()),
    id: j['id'] as String?,
  );
  return h.isExpired(now) ? null : h;
}

Map<String, Object?> _text(String description) => {
  'type': 'object',
  'properties': {
    'text': {'type': 'string', 'description': description},
  },
  'required': ['text'],
};
const _on = {
  'type': 'object',
  'properties': {
    'on': {'type': 'boolean'},
  },
  'required': ['on'],
};

const _view = OpSpec(
  'view',
  description: 'See it as it looks on screen: a picture',
);

/// What each kind of control can do, unless the app says otherwise (the same as on the web).
final Map<Role, List<OpSpec>> standardOps = {
  Role.app: const [OpSpec('read', description: 'All the text on screen')],
  Role.page: const [
    OpSpec('read', description: 'All the text of this page'),
    _view,
  ],
  Role.region: const [OpSpec('read', description: 'All the text in it'), _view],
  Role.dialog: const [OpSpec('read', description: 'All the text in it'), _view],
  Role.button: const [OpSpec('press')],
  Role.link: const [OpSpec('press', description: 'Follow the link')],
  Role.textbox: [
    const OpSpec('read', description: 'What is written in it'),
    OpSpec(
      'write',
      description: 'Replace what is written',
      params: _text('The new text'),
    ),
    OpSpec(
      'append',
      description: 'Add to the end',
      params: _text('The text to add'),
    ),
    const OpSpec('clear'),
  ],
  Role.checkbox: const [OpSpec('toggle'), OpSpec('set', params: _on)],
  Role.switch_: const [OpSpec('toggle'), OpSpec('set', params: _on)],
  Role.radio: const [OpSpec('select')],
  Role.select: const [
    OpSpec('read', description: 'The choice and the options'),
    OpSpec('press', description: 'Open the choices'),
  ],
  Role.tab: const [OpSpec('select')],
  Role.container: const [
    OpSpec('read', description: 'The text of the entries on screen'),
    OpSpec(
      'item',
      description: 'Fetch one entry as a tree of its own (its controls, with ids and keys to act on): by id (or key), index, or the first whose name has query; brought into view first if it is not. preview: true builds it off screen instead, when the app can',
      params: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': "The entry's id or key"},
          'index': {'type': 'number'},
          'query': {'type': 'string'},
          'preview': {'type': 'boolean'},
        },
      },
    ),
    OpSpec(
      'items',
      description: 'Page through all its entries (also those not on screen): their keys and names',
      params: {
        'type': 'object',
        'properties': {
          'offset': {'type': 'number', 'description': 'From (default 0)'},
          'limit': {'type': 'number', 'description': 'How many (default 20)'},
          'query': {
            'type': 'string',
            'description': 'Only items whose name has this',
          },
        },
      },
    ),
    OpSpec(
      'scroll_to',
      description: 'Bring an entry into view, by its index or its key / id',
      params: {
        'type': 'object',
        'properties': {
          'index': {'type': 'number'},
          'item': {'type': 'string', 'description': "The entry's key or id"},
        },
      },
    ),
    OpSpec(
      'scroll',
      description: 'Scroll it by pages (negative: back up)',
      params: {
        'type': 'object',
        'properties': {
          'by': {'type': 'number', 'description': 'Pages, e.g. 1 or -1'},
        },
      },
    ),
  ],
  Role.list: const [OpSpec('read', description: 'The text of its items')],
  Role.listitem: const [
    OpSpec('read'),
    OpSpec('press', description: 'Open it'),
  ],
  Role.heading: const [],
  Role.text: const [OpSpec('read')],
  Role.image: const [OpSpec('view', description: 'See it: the picture itself')],
  Role.other: const [OpSpec('read')],
};

/// A node's ops: the standard ones for its role with the app's policies applied, plus its own.
List<OpSpec> opsFor(
  Role role, {
  Policy? policy,
  Map<String, Policy> policies = const {},
  List<OpSpec> own = const [],
}) {
  Policy pick(OpSpec op) => policies[op.name] ?? policy ?? op.policy;
  final ownNames = own.map((o) => o.name).toSet();
  return [
    for (final op in standardOps[role]!)
      if (!ownNames.contains(op.name)) op.withPolicy(pick(op)),
    for (final op in own) op.withPolicy(pick(op)),
  ];
}
