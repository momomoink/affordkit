// The AffordKit protocol in Dart — the same JSON as the TypeScript package (affordkit/js/src/protocol.ts): keep the two in step.
// An app's controls as a tree for an AI agent; the agent's calls; their results.

const protocolVersion = 1;

/// What a node is (the same names as on the web).
enum Role { app, page, region, dialog, button, link, textbox, checkbox, switch_, radio, select, tab, container, list, listitem, heading, text, image, other }

extension RoleName on Role {
  String get wire => this == Role.switch_ ? 'switch' : name;
}

/// allow: just do it. confirm: only after the user says yes. deny: the agent sees it, never does it.
enum Policy { allow, confirm, deny }

class OpSpec {
  const OpSpec(this.name, {this.description, this.params, this.policy = Policy.allow});
  final String name;
  final String? description;

  /// A JSON Schema object for the arguments.
  final Map<String, Object?>? params;
  final Policy policy;

  OpSpec withPolicy(Policy p) => OpSpec(name, description: description, params: params, policy: p);

  Map<String, Object?> toJson() => {'name': name, 'description': ?description, 'params': ?params, 'policy': policy.name};
}

class AffordNode {
  AffordNode({required this.id, required this.role, required this.name, this.key, this.description, this.state, this.ops = const [], this.children = const [], this.preview = const [], this.value});
  final String id;

  /// A name the app gives it that stays the same across pages and visits: calls may use it instead of the id.
  final String? key;
  final Role role;
  final String name;
  final String? description;
  final Map<String, Object>? state;
  final List<OpSpec> ops;
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

  Map<String, Object?> toJson() => {
    'id': id,
    'key': ?key,
    'role': role.wire,
    'name': name,
    'description': ?description,
    if (state != null && state!.isNotEmpty) 'state': state,
    'ops': ops.map((o) => o.toJson()).toList(),
    if (children.isNotEmpty) 'children': children.map((c) => c.toJson()).toList(),
    if (preview.isNotEmpty) 'preview': preview.map((i) => i.toJson()).toList(),
    'value': ?value,
  };
}

/// One entry of a container, as its preview and its `items` op give it (whether or not it is on screen).
class ItemSummary {
  const ItemSummary({required this.id, required this.name, this.key, this.index, this.description});
  final String id, name;

  /// The entry's key (`<container key>[<id>]`), to fetch it or act on it — when the container has a key.
  final String? key;
  final int? index;
  final String? description;

  ItemSummary withKey(String? key, int? index) => ItemSummary(id: id, name: name, key: key, index: this.index ?? index, description: description);

  Map<String, Object?> toJson() => {'key': ?key, 'id': id, 'index': ?index, 'name': name, 'description': ?description};
}

/// A page of a container's entries: the `items` op's answer ([count]: all of them, when known).
class ItemsPage {
  const ItemsPage({required this.offset, required this.items, this.count});
  final int? count;
  final int offset;
  final List<ItemSummary> items;
  Map<String, Object?> toJson() => {'count': ?count, 'offset': offset, 'items': items.map((i) => i.toJson()).toList()};
}

/// Where an entry's tree came from: on screen (its ids can be acted on), or built off screen (act by key: that brings it in).
enum ItemSource { live, preview }

/// One entry of a container, fetched (the `item` op's answer): a tree of its own, rooted at the entry.
class ItemTree {
  const ItemTree({required this.id, required this.source, required this.root, this.key, this.index});
  final String id;
  final String? key;
  final int? index;
  final ItemSource source;
  final AffordNode root;
  Map<String, Object?> toJson() => {'key': ?key, 'id': id, 'index': ?index, 'source': source.name, 'root': root.toJson()};
}

/// An entry's key: the container's key and the entry's id (mail.list + 42 → mail.list[42]).
String itemKey(String containerKey, String id) => '$containerKey[$id]';

/// The innermost entry a key names: mail.list[42].star → (list: mail.list — the container's key, id: 42, rest: .star); null when it names none.
({String list, String id, String rest})? parseItemKey(String key) {
  final m = RegExp(r'^(.+)\[([^[\]]+)\](.*)$').firstMatch(key);
  return m == null ? null : (list: m.group(1)!, id: m.group(2)!, rest: m.group(3)!);
}

class ToolSpec {
  const ToolSpec(this.name, this.description, {this.inputSchema, this.policy = Policy.allow});
  final String name, description;
  final Map<String, Object?>? inputSchema;
  final Policy policy;
  Map<String, Object?> toJson() => {'name': name, 'description': description, 'inputSchema': ?inputSchema, 'policy': policy.name};
}

/// What a route's :param can be.
class RouteParam {
  const RouteParam({this.description, this.values});
  final String? description;
  final List<String>? values;
  Map<String, Object?> toJson() => {'description': ?description, 'values': ?values};
}

/// A place in the app the agent can go to: a pattern such as /settings/:tab.
class RouteSpec {
  const RouteSpec(this.path, this.description, {this.params = const {}});
  final String path, description;
  final Map<String, RouteParam> params;
  Map<String, Object?> toJson() => {
    'path': path,
    'description': description,
    if (params.isNotEmpty) 'params': {for (final e in params.entries) e.key: e.value.toJson()},
  };
}

/// Where the user is (the pattern it is, its params), whether back goes somewhere, and where the agent can go.
class RouteState {
  const RouteState({required this.current, this.pattern, this.params = const {}, this.canGoBack, this.routes = const []});
  final String current;
  final String? pattern;
  final Map<String, String> params;
  final bool? canGoBack;
  final List<RouteSpec> routes;
  Map<String, Object?> toJson() => {
    'current': current,
    'pattern': ?pattern,
    if (pattern != null) 'params': params,
    'canGoBack': ?canGoBack,
    'routes': routes.map((r) => r.toJson()).toList(),
  };
}

class AffordContext {
  AffordContext({required this.root, this.tools = const [], this.route});
  final AffordNode root;
  final List<ToolSpec> tools;
  final RouteState? route;

  String? get currentRoute => route?.current;

  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    if (route != null) 'route': route!.toJson(),
    'root': root.toJson(),
    'tools': tools.map((t) => t.toJson()).toList(),
  };
}

/// Where a peek's tree came from: the page showing now, built off screen just now, as it last showed, or never seen (no tree).
enum PageSource { live, preview, seen, declared }

/// Another page's tree, peeked at without going there (its ids can't be acted on: navigate, then act by key).
class PagePeek {
  const PagePeek({required this.route, required this.source, this.pattern, this.description, this.seenAt, this.root});
  final String route;
  final PageSource source;
  final String? pattern, description;
  final DateTime? seenAt;
  final AffordNode? root;
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
  List<String> split(String p) => p.split(RegExp('[?#]')).first.split('/').where((x) => x.isNotEmpty).toList();
  final want = split(pattern), got = split(route);
  final tail = want.isNotEmpty && want.last == '*';
  if (tail ? got.length < want.length - 1 : got.length != want.length) return null;
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
(RouteSpec, Map<String, String>)? findRoute(List<RouteSpec> routes, String route) {
  (RouteSpec, Map<String, String>)? best;
  for (final spec in routes) {
    final params = matchRoute(spec.path, route);
    if (params != null && (best == null || params.length < best.$2.length)) best = (spec, params);
  }
  return best;
}

/// One thing the agent asks for: an op on a node, an app-wide tool, or going to a route.
sealed class Call {
  const Call();
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

class NodeCall extends Call {
  const NodeCall(this.node, this.op, [this.args = const {}]);
  final String node, op;
  final Map<String, Object?> args;
  @override
  Map<String, Object?> toJson() => {'node': node, 'op': op, if (args.isNotEmpty) 'args': args};
}

class ToolCall extends Call {
  const ToolCall(this.tool, [this.args = const {}]);
  final String tool;
  final Map<String, Object?> args;
  @override
  Map<String, Object?> toJson() => {'tool': tool, if (args.isNotEmpty) 'args': args};
}

/// Go to a route, or "back".
class NavigateCall extends Call {
  const NavigateCall(this.route);
  final String route;
  @override
  Map<String, Object?> toJson() => {'navigate': route};
}

/// Another page's tree, without going there (the value: a PagePeek).
class PeekCall extends Call {
  const PeekCall(this.route);
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

  /// Anything else that went wrong doing it.
  failed('failed');

  const ErrorCode(this.wire);
  final String wire;

  static ErrorCode? fromWire(Object? wire) => values.where((c) => c.wire == wire).firstOrNull;
}

/// An error with its code (thrown by the kit, and by an app's own ops when it wants to say which).
class AffordError implements Exception {
  const AffordError(this.code, this.message);
  final ErrorCode code;
  final String message;

  @override
  String toString() => message;
}

class CallResult {
  const CallResult(this.call, {required this.ok, this.value, this.error, this.needsConfirm = false, this.code});
  final Call call;
  final bool ok;
  final Object? value;
  final String? error;
  final bool needsConfirm;

  /// Why it failed.
  final ErrorCode? code;
  Map<String, Object?> toJson() => {'call': call.toJson(), 'ok': ok, 'value': ?switch (value) {
      PagePeek v => v.toJson(),
      ItemsPage v => v.toJson(),
      ItemTree v => v.toJson(),
      _ => value,
    }, 'error': ?error, 'code': ?code?.wire, if (needsConfirm) 'needsConfirm': true};
}

/// The results, and the context as it is afterwards (the agent's next round).
class ExecuteResult {
  const ExecuteResult(this.results, this.context);
  final List<CallResult> results;
  final AffordContext context;
  Map<String, Object?> toJson() => {'results': results.map((r) => r.toJson()).toList(), 'context': context.toJson()};
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

/// What each kind of control can do, unless the app says otherwise (the same as on the web).
const _view = OpSpec('view', description: 'See it as it looks on screen: a picture');

final Map<Role, List<OpSpec>> standardOps = {
  Role.app: const [OpSpec('read', description: 'All the text on screen')],
  Role.page: const [OpSpec('read', description: 'All the text of this page'), _view],
  Role.region: const [OpSpec('read', description: 'All the text in it'), _view],
  Role.dialog: const [OpSpec('read', description: 'All the text in it'), _view],
  Role.button: const [OpSpec('press')],
  Role.link: const [OpSpec('press', description: 'Follow the link')],
  Role.textbox: [
    const OpSpec('read', description: 'What is written in it'),
    OpSpec('write', description: 'Replace what is written', params: _text('The new text')),
    OpSpec('append', description: 'Add to the end', params: _text('The text to add')),
    const OpSpec('clear'),
  ],
  Role.checkbox: const [OpSpec('toggle'), OpSpec('set', params: _on)],
  Role.switch_: const [OpSpec('toggle'), OpSpec('set', params: _on)],
  Role.radio: const [OpSpec('select')],
  Role.select: const [OpSpec('read', description: 'The choice and the options'), OpSpec('press', description: 'Open the choices')],
  Role.tab: const [OpSpec('select')],
  Role.container: const [
    OpSpec('read', description: 'The text of the entries on screen'),
    OpSpec(
      'item',
      description:
          'Fetch one entry as a tree of its own (its controls, with ids and keys to act on): by id (or key), index, or the first whose name has query; brought into view first if it is not. preview: true builds it off screen instead, when the app can',
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
          'query': {'type': 'string', 'description': 'Only items whose name has this'},
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
  Role.listitem: const [OpSpec('read'), OpSpec('press', description: 'Open it')],
  Role.heading: const [],
  Role.text: const [OpSpec('read')],
  Role.image: const [OpSpec('view', description: 'See it: the picture itself')],
  Role.other: const [OpSpec('read')],
};

/// A node's ops: the standard ones for its role with the app's policies applied, plus its own.
List<OpSpec> opsFor(Role role, {Policy? policy, Map<String, Policy> policies = const {}, List<OpSpec> own = const []}) {
  Policy pick(OpSpec op) => policies[op.name] ?? policy ?? op.policy;
  final ownNames = own.map((o) => o.name).toSet();
  return [
    for (final op in standardOps[role]!)
      if (!ownNames.contains(op.name)) op.withPolicy(pick(op)),
    for (final op in own) op.withPolicy(pick(op)),
  ];
}
