// The agent's side of AffordKit, in Dart (the same as the TypeScript package's agent.ts / remote.ts / adapters.ts): the tools an
// agent gets, its calls run on the app — through a send function, over any transport, or straight on a kit (kit.agent()) — and
// each answer as text for the model: after an act, what it changed on screen rather than the whole tree again, with a code when it
// failed. It works on the protocol's JSON, so the app can be anywhere.
//
//   final ui = AffordKit.instance.agent();                          // or AffordAgent(send: (request) => socket.ask(request))
//   body['tools'] = anthropicTools(ui.tools());
//   final answer = await ui.handle(toolUse['name'], toolUse['input']);   // → the tool_result: answer.text, answer.isError
//
// When the user has left the app (present says so), the screen tools answer code away at once; with onHandoff the agent also gets
// ui_handoff, to leave the user a message and the calls that take them to what it did (see Handoff).

import 'dart:async';
import 'dart:convert';

import 'protocol.dart';

/// A JSON object.
typedef Json = Map<String, Object?>;

/// A tool the agent gets: its name, what it does, and its input's JSON schema.
class AgentTool {
  /// A tool named [name] that does what [description] says.
  const AgentTool(this.name, this.description, this.inputSchema);

  /// The tool's name, as the model calls it.
  final String name;

  /// What it does, for the model.
  final String description;

  /// A JSON Schema object for its input.
  final Json inputSchema;
}

/// The tools an agent gets for acting on the app's UI (the same as the TypeScript AGENT_TOOLS).
const agentTools = [
  AgentTool(
    'ui_look',
    "See what is on the user's screen now: the route, and the tree of controls (each with an id — and a key when the app gives one — what it is, what it shows, its state and the ops it allows). picture: true also gives a picture of the screen, for what the tree can't say (images, layout, colors) — when the app can take one.",
    {
      'type': 'object',
      'properties': {
        'picture': {
          'type': 'boolean',
          'description': 'Also a picture of the screen',
        },
      },
    },
  ),
  AgentTool(
    'ui_act',
    "Do an op on a control by its id or key: e.g. read a field or a page's text, write into a field, press a button, toggle a switch, pick an option. Ops marked deny are for the user only; confirm ones wait for their yes. "
        'A page or dialog node marked behind is under what shows (another page, a dialog): its controls still work, but the user does not see them act — when they are watching, go to that page first unless it is a small aside. '
        'A container (many of the same thing: a mail list, a thread\'s messages) shows only a preview of its entries, not their controls: fetch one with its op "item" (args: id, or index, or query) and the answer is that entry as a tree of its own, with ids and keys to act on next (e.g. item {id: "42"} on mail.list → mail.list[42].reply). "items" pages through all its entries\' keys and names. An entry\'s key — container key + [id], controls in it under that, mail.list[42].reply — can also be acted on straight away, even off screen: it is fetched (scrolled to) first. scroll_to / scroll move the container.',
    {
      'type': 'object',
      'properties': {
        'node': {
          'type': 'string',
          'description': "The control's id or key from the tree",
        },
        'op': {'type': 'string', 'description': 'One of its ops'},
        'args': {
          'type': 'object',
          'description': 'The op\'s arguments, e.g. { "text": "…" }',
        },
      },
      'required': ['node', 'op'],
    },
  ),
  AgentTool(
    "ui_tool",
    "Run one of the app's own tools (listed with the tree).",
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'args': {'type': 'object'},
      },
      'required': ['name'],
    },
  ),
  AgentTool(
    'ui_navigate',
    "Take the user to a route of the app (listed with the tree, filling in its :params), or \"back\". The answer is the new page's tree.",
    {
      'type': 'object',
      'properties': {
        'route': {
          'type': 'string',
          'description': 'e.g. /settings/ai, or back',
        },
      },
      'required': ['route'],
    },
  ),
  AgentTool(
    'ui_peek',
    "See another page's controls without taking the user there, to plan: what is on it and the keys to act on after navigating (e.g. peek /settings/ai, then navigate there and act by key). Says whether it is current or as last seen.",
    {
      'type': 'object',
      'properties': {
        'route': {'type': 'string', 'description': 'e.g. /settings/ai'},
      },
      'required': ['route'],
    },
  ),
  AgentTool(
    'ui_handoff',
    'Only when the user is away (the other ui_ tools answer code away): do what you can with your other tools, then leave the user a handoff for when they come back — a short message, and where to take them: route, the page to open first (one of the routes), then calls, ops to run there in order. The app usually shows it as a notification, and runs it when they tap. '
        'A call names a control by its key, never its id (ids don\'t last until then): e.g. {key: "drafts.list[42]", op: "press"} to open the draft you wrote. Keep it to bringing them to the result — open the page, the item; nothing that sends, pays, deletes or can\'t be undone: they see it happen, and ops that need their yes still ask. At most 20 calls; message at most 500 characters, in the user\'s language.',
    {
      'type': 'object',
      'properties': {
        'message': {
          'type': 'string',
          'description':
              'What you did and what is waiting for them, in a sentence or two',
        },
        'route': {
          'type': 'string',
          'description': 'The page to open first, e.g. /drafts',
        },
        'calls': {
          'type': 'array',
          'description': 'Then these, in order: { key, op, args? }',
          'items': {
            'type': 'object',
            'properties': {
              'key': {'type': 'string'},
              'op': {'type': 'string'},
              'args': {'type': 'object'},
            },
            'required': ['key', 'op'],
          },
        },
      },
      'required': ['message'],
    },
  ),
];

/// One of [agentTools] called by the agent → the call for the app, as JSON (null for ui_look: just the screen; ui_handoff is not one).
Json? toCall(String tool, Json args) {
  Json obj(Object? v) => v is Map ? v.cast<String, Object?>() : {};
  return switch (tool) {
    'ui_look' => null,
    'ui_act' => {
      'node': '${args['node'] ?? ''}',
      'op': '${args['op'] ?? ''}',
      'args': obj(args['args']),
    },
    'ui_tool' => {'tool': '${args['name'] ?? ''}', 'args': obj(args['args'])},
    'ui_navigate' => {'navigate': '${args['route'] ?? ''}'},
    'ui_peek' => {'peek': '${args['route'] ?? ''}'},
    'ui_handoff' => throw const AffordError(
      ErrorCode.badArgs,
      'ui_handoff is not a call to the app: it goes to the host (AffordAgent with onHandoff)',
    ),
    _ => throw AffordError(ErrorCode.badArgs, 'Not an AffordKit tool: $tool'),
  };
}

// ---------------- as text ----------------

List<Json> _list(Object? v) => [
  for (final x in (v as List? ?? const [])) (x as Map).cast<String, Object?>(),
];
Json? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;
String _q(Object? s) => jsonEncode(s ?? '');

List<String> _routeLines(Json route) {
  final params = _map(route['params']) ?? const {};
  final pattern = route['pattern'];
  final current = route['current'];
  final lines = [
    'Route: $current${pattern != null && pattern != current ? ' = $pattern${params.isNotEmpty ? ' (${params.entries.map((e) => '${e.key}=${e.value}').join(', ')})' : ''}' : ''}${route['canGoBack'] == true ? ' — can go back' : ''}',
  ];
  final routes = _list(route['routes']);
  if (routes.isNotEmpty) {
    lines.add('Routes:');
    for (final r in routes) {
      final ps = [
        for (final e in (_map(r['params']) ?? const {}).entries)
          if (_map(e.value) case final p?)
            ':${e.key}${p['values'] is List ? ' ∈ {${(p['values'] as List).join(', ')}}' : ''}${p['description'] != null ? ' (${p['description']})' : ''}',
      ];
      lines.add(
        '  ${r['path']} — ${r['description']}${ps.isNotEmpty ? '; ${ps.join('; ')}' : ''}',
      );
    }
  }
  return lines;
}

/// One node as a line (no children): [id key=…] role "name" (state) — description — ops.
String _nodeLine(Json n) {
  var list = '';
  var entries = (_map(n['state']) ?? const {}).entries.toList();
  if (n['role'] == 'container') {
    final s = _map(n['state']) ?? const {};
    final count = s['count'],
        first = s['first'],
        last = s['last'],
        kind = s['kind'];
    list =
        '${kind != null ? ' ($kind)' : ''}${count is num ? ' $count entr${count == 1 ? 'y' : 'ies'}' : ''}${first is num ? ', showing $first–$last' : ''}${n['key'] != null ? ' (entry keys: ${n['key']}[<id>])' : ''}';
    entries = [
      for (final e in entries)
        if (!const {'count', 'first', 'last', 'kind'}.contains(e.key)) e,
    ];
  }
  final state = entries.isNotEmpty
      ? ' (${entries.map((e) => e.value == true ? e.key : '${e.key}: ${e.value}').join(', ')})'
      : '';
  final ops = [
    for (final o in _list(n['ops']))
      (o['policy'] ?? 'allow') == 'allow'
          ? o['name']
          : '${o['name']}(${o['policy']})',
  ].join(', ');
  final id = n['key'] != null ? '${n['id']} key=${n['key']}' : '${n['id']}';
  final name = '${n['name'] ?? ''}';
  final description = n['description'];
  // (what it shows, when it isn't its name already)
  final value = n['value'] != null && n['value'] != name
      ? ' = ${_q(n['value'])}'
      : '';
  return '[$id] ${n['role']}${name.isNotEmpty ? ' "$name"' : ''}$value$list$state${description != null ? ' — $description' : ''}${ops.isNotEmpty ? ' — $ops' : ''}';
}

/// A container's entries on screen, in short (fetch one, op item, for its controls).
List<String> _previewLines(Json n, String pad) {
  final preview = _list(n['preview']);
  if (preview.isEmpty) return const [];
  final count = _map(n['state'])?['count'];
  final more = count is num ? count - preview.length : 0;
  return [
    for (final i in preview)
      '$pad· [${i['key'] ?? i['id']}]${i['index'] != null ? ' #${i['index']}' : ''} ${_q(i['name'])}${i['description'] != null ? ' — ${i['description']}' : ''}',
    "$pad· …${more > 0 ? ' $more more;' : ''} op item fetches an entry's controls, items pages through them",
  ];
}

List<String> _treeLines(Json root, int maxNodes) {
  final lines = <String>[];
  var count = 0;
  void walk(Json n, int depth) {
    if (count++ >= maxNodes) return;
    lines.add('  ' * depth + _nodeLine(n));
    for (final c in _list(n['children'])) {
      walk(c, depth + 1);
    }
    lines.addAll(_previewLines(n, '  ' * (depth + 1)));
  }

  walk(root, 0);
  if (count > maxNodes) lines.add('… ${count - maxNodes} more nodes');
  return lines;
}

/// The context (its JSON) as indented lines: the route, the routes, the app's tools, then the tree.
String describe(Json context, {int maxNodes = 400}) {
  final tools = _list(context['tools']);
  return [
    if (_map(context['route']) case final r?) ..._routeLines(r),
    if (tools.isNotEmpty)
      'Tools: ${tools.map((t) => '${t['name']}${(t['policy'] ?? 'allow') != 'allow' ? '(${t['policy']})' : ''} — ${t['description']}').join('; ')}',
    ..._treeLines(_map(context['root']) ?? const {}, maxNodes),
  ].join('\n');
}

/// What changed on screen between two contexts (their JSON), as text: the route if it changed, then the nodes that came (+), went
/// (-) or changed (~). When most of the screen changed, the whole new screen instead. Nodes are matched by key, else id.
String describeChange(
  Json before,
  Json after, {
  int maxNodes = 400,
  double wholeOver = 0.5,
}) {
  Map<String, (Json, String, Json?)> flat(Json root) {
    final out = <String, (Json, String, Json?)>{};
    void walk(Json n, Json? parent) {
      out['${n['key'] ?? n['id']}'] = (
        n,
        _nodeLine(n) + _previewLines(n, ' ').join(),
        parent,
      );
      for (final c in _list(n['children'])) {
        walk(c, n);
      }
    }

    walk(root, null);
    return out;
  }

  final was = flat(_map(before['root']) ?? const {});
  final now = flat(_map(after['root']) ?? const {});
  final came = [
    for (final e in now.entries)
      if (!was.containsKey(e.key)) e.value,
  ];
  final went = [
    for (final e in was.entries)
      if (!now.containsKey(e.key)) e.value,
  ];
  final changed = [
    for (final e in now.entries)
      if (was.containsKey(e.key) && was[e.key]!.$2 != e.value.$2) e.value,
  ];
  final lines = <String>[];
  final from = _map(before['route'])?['current'];
  final to = _map(after['route'])?['current'];
  if (to != null && to != from) {
    lines.add(
      'Now at $to${from != null ? ' (was $from)' : ''}${_map(after['route'])?['canGoBack'] == true ? ' — can go back' : ''}.',
    );
  }
  if (came.length + went.length >
      (now.length * wholeOver).clamp(4, double.infinity)) {
    return [
      ...lines,
      'The screen now:',
      describe(after, maxNodes: maxNodes),
    ].join('\n');
  }
  if (came.isEmpty && went.isEmpty && changed.isEmpty) {
    return [...lines, 'The screen did not change.'].join('\n');
  }
  // A page that went under what shows (a dialog opened, a page pushed) or came back from under it: its controls didn't change, say so
  int under(Json n) =>
      _list(n['children']).fold(0, (sum, c) => sum + 1 + under(c));
  String where(Json? p) => p != null && p['role'] != 'app'
      ? ' (in ${p['key'] ?? p['id']}${'${p['name'] ?? ''}'.isNotEmpty ? ' "${p['name']}"' : ''})'
      : '';
  for (final (n, _, p) in came.take(maxNodes)) {
    if (_map(n['state'])?['behind'] == true) {
      lines.add(
        '+ [${n['id']}] ${n['role']}${'${n['name'] ?? ''}'.isNotEmpty ? ' "${n['name']}"' : ''} (behind) — now under what shows: its ${under(n)} controls still work, unseen',
      );
      continue;
    }
    lines
      ..add('+ ${_nodeLine(n)}${where(p)}')
      ..addAll(_previewLines(n, '    '));
  }
  for (final (n, _, _) in went.take(maxNodes)) {
    final back =
        _map(n['state'])?['behind'] == true &&
        _list(n['children'])
            .any((c) => now.containsKey('${c['key'] ?? c['id']}'));
    lines.add(
      '- [${n['key'] ?? n['id']}] ${n['role']}${'${n['name'] ?? ''}'.isNotEmpty ? ' "${n['name']}"' : ''}${back ? ' — on top again: its controls show' : ''}',
    );
  }
  for (final (n, _, _) in changed.take(maxNodes)) {
    lines
      ..add('~ ${_nodeLine(n)}')
      ..addAll(_previewLines(n, '    '));
  }
  return ['The screen changed:', ...lines].join('\n');
}

/// A peeked page (its JSON) as text.
String describePage(Json view, {int maxNodes = 300}) {
  final source = view['source'];
  final how = switch (source) {
    'live' => 'showing now',
    'preview' => 'built off screen just now, as it would open',
    'seen' =>
      'as it was when it last showed${view['seenAt'] != null ? ' (${view['seenAt']})' : ''}',
    _ => 'never seen: only what the route says',
  };
  final route = view['route'], pattern = view['pattern'];
  final root = _map(view['root']);
  return [
    'Page $route${pattern != null && pattern != route ? ' = $pattern' : ''} — $how${view['description'] != null ? '. ${view['description']}' : ''}',
    if (root != null && source != 'live') '(Peek ids cannot be acted on: navigate there, then act by key, or look again for live ids.)',
    if (root != null) ..._treeLines(root, maxNodes),
  ].join('\n');
}

/// A fetched entry (its JSON) as text: what it is, then its tree.
String describeItem(Json item, {int maxNodes = 200}) => [
  'Entry ${item['key'] ?? item['id']}${item['index'] != null ? ' #${item['index']}' : ''}${item['source'] == 'preview' ? ' — built off screen: its ids cannot be acted on, act by key (that brings it in)' : ''}:',
  ..._treeLines(_map(item['root']) ?? const {}, maxNodes),
].join('\n');

/// A page of a container's entries (its JSON) as text.
String describeItems(Json page) {
  final items = _list(page['items']);
  final offset = (page['offset'] as num?)?.toInt() ?? 0;
  final count = page['count'];
  final head = items.isNotEmpty
      ? 'Items $offset–${offset + items.length - 1}${count != null ? ' of $count' : ''}:'
      : 'No items${offset > 0 ? ' from $offset' : ''}${count != null ? ' ($count in all)' : ''}.';
  return [
    head,
    for (final i in items)
      '  [${i['key'] ?? i['id']}]${i['index'] != null ? ' #${i['index']}' : ''} ${_q(i['name'])}${i['description'] != null ? ' — ${i['description']}' : ''}',
  ].join('\n');
}

/// A picture as text (the picture itself goes beside it, where the agent's stack can take one).
String describeImage(Json v) {
  final size = v['width'] != null && v['height'] != null
      ? '${v['width']}×${v['height']} '
      : '';
  return v['data'] != null
      ? '(A picture, $size${v['mime']}: attached.)'
      : '(A picture at ${v['url'] ?? 'an unknown place'}: it could not be read here.)';
}

/// A result (its JSON) as text for the agent.
String describeResult(Json r) {
  final call = _map(r['call']) ?? const {};
  if (r['ok'] != true) {
    return r['needsConfirm'] == true
        ? 'Waiting: ${r['error']}'
        : 'Failed${r['code'] != null ? ' (${r['code']})' : ''}: ${r['error']}';
  }
  final value = r['value'];
  if (call.containsKey('peek') && value is Map) {
    return describePage(value.cast());
  }
  if (call.containsKey('navigate')) {
    return 'Now at ${value ?? call['navigate']}.';
  }
  if (call['op'] == 'items' && value is Map && value['items'] is List) {
    return describeItems(value.cast());
  }
  if (call['op'] == 'item' && value is Map && value['root'] != null) {
    return describeItem(value.cast());
  }
  if (value is Map && value['type'] == 'image') {
    return describeImage(value.cast());
  }
  return value == null
      ? 'Done.'
      : (value is String ? value : jsonEncode(value));
}

// ---------------- the agent's side ----------------

/// A tool's answer: the text for the agent (its tool result), whether it failed and why, and the screen it left (JSON).
class ToolAnswer {
  /// An answer with [text] for the agent.
  const ToolAnswer(
    this.text, {
    this.isError = false,
    this.code,
    this.context,
    this.images = const [],
  });

  /// The tool result's text.
  final String text;

  /// Whether the tool failed.
  final bool isError;

  /// Why it failed.
  final ErrorCode? code;

  /// The screen it left, as the app's context JSON.
  final Json? context;

  /// Pictures that go with the text (a look with picture, an op view): to pass to the model where its stack takes images.
  final List<({String mime, String data})> images;
}

/// The agent's side: its tools, run on the app through [send] (the app answers with its kit's answer()).
class AffordAgent {
  /// An agent that reaches the app through [send].
  AffordAgent({
    required this.send,
    this.timeout = const Duration(seconds: 45),
    this.wholeScreen = false,
    this.only,
    this.maxNodes = 400,
    this.present,
    this.onHandoff,
    this.handoffTtl = const Duration(hours: 24),
  });

  /// Send a request ({look: true} or {calls: [...]}) to the app and complete with its answer (AffordKit.answer there).
  final Future<Json> Function(Json request) send;

  /// How long to wait for the app's answer: then the tool fails with code timeout.
  final Duration timeout;

  /// The whole tree after every act, instead of what changed.
  final bool wholeScreen;

  /// Which of [agentTools] to offer (default all — ui_tool once the app is seen to have tools of its own, ui_handoff with
  /// [onHandoff]).
  final List<String>? only;

  /// Most nodes of a tree written out for the model (the rest are counted).
  final int maxNodes;

  /// Whether the user is in the app now (the app's lifecycle: resumed, or as its channel last reported it). While it says no, every
  /// tool but ui_handoff answers code away at once, without asking the app (the app's own tools run in the app too). Null: always.
  final bool Function()? present;

  /// Where a handoff the agent leaves goes (ui_handoff, checked first): keep it and tell the user — a notification with its id,
  /// usually. What it completes with ("notification sent") is told the agent. Null: ui_handoff isn't offered.
  final FutureOr<String?> Function(Handoff handoff)? onHandoff;

  /// How long a handoff stays good: its expiresAt.
  final Duration handoffTtl;

  Json? _last;

  /// The screen as the agent was last shown it (e.g. sent along with the user's message): the next act answers with what changed since.
  void seen(Json? context) => _last = context;

  /// The screen as the agent last saw it (the app's context JSON).
  Json? get screen => _last;

  /// The tools to give the model now.
  List<AgentTool> tools() => [
    for (final t in agentTools)
      if ((t.name != 'ui_handoff' || onHandoff != null) &&
          (only != null
              ? only!.contains(t.name)
              : t.name != 'ui_tool' ||
                    _last == null ||
                    _list(_last!['tools']).isNotEmpty))
        t,
  ];

  /// Whether [tools] has the tool named [name].
  bool has(String name) => tools().any((t) => t.name == name);

  /// Run a tool the agent called. Never throws: a failure is an answer with isError and a code.
  Future<ToolAnswer> handle(String name, [Json? input]) async {
    if (name == 'ui_handoff') return _handoff(input ?? const {});
    // The user has left: nothing on the screen can be done now (and the app may not even answer)
    if (present?.call() == false && agentTools.any((t) => t.name == name)) {
      return _failed(
        ErrorCode.away,
        "The user is not in the app right now (it is in the background): the screen can't be looked at or worked. Use your other tools${onHandoff != null ? ', and leave a handoff (ui_handoff) for when they come back' : ''}.",
      );
    }
    final Json? call;
    try {
      call = toCall(name, input ?? const {});
    } on AffordError catch (e) {
      return _failed(e.code, e.message);
    }
    final answer = await _ask(
      call == null
          ? {'look': true, if (input?['picture'] == true) 'picture': true}
          : {
              'calls': [call],
            },
    );
    if (answer['error'] != null) {
      return _failed(
        ErrorCode.fromWire(answer['code']) ?? ErrorCode.unavailable,
        '${answer['error']}',
      );
    }
    final context = _map(answer['context']) ?? const {};
    final before = _last;
    _last = context;
    if (call == null) {
      final shot = _map(answer['picture']);
      final images = [
        if (shot?['data'] is String)
          (mime: '${shot!['mime']}', data: shot['data'] as String),
      ];
      final note = input?['picture'] == true
          ? (images.isNotEmpty
                ? '\n\n(A picture of the screen is attached.)'
                : "\n\n(No picture: this app can't take one.)")
          : '';
      return ToolAnswer(
        describe(context, maxNodes: maxNodes) + note,
        context: context,
        images: images,
      );
    }
    final results = _list(answer['results']);
    if (results.isEmpty) {
      return _failed(ErrorCode.unavailable, 'The app gave no result');
    }
    final r = results.first;
    final ok = r['ok'] == true;
    final said =
        ok && call.containsKey('navigate') && before != null && !wholeScreen
        ? ''
        : describeResult(r);
    final screen = call.containsKey('peek')
        ? ''
        : wholeScreen || before == null
        ? 'The screen now:\n${describe(context, maxNodes: maxNodes)}'
        : describeChange(before, context, maxNodes: maxNodes);
    final value = _map(r['value']);
    final images = [
      if (value?['type'] == 'image' && value?['data'] is String)
        (mime: '${value!['mime']}', data: value['data'] as String),
    ];
    return ToolAnswer(
      [said, screen].where((s) => s.isNotEmpty).join('\n\n'),
      isError: !ok,
      code: ErrorCode.fromWire(r['code']),
      context: context,
      images: images,
    );
  }

  /// ui_handoff: the agent's handoff checked (its route against the routes seen), with its expiry, and given to the host.
  Future<ToolAnswer> _handoff(Json input) async {
    final give = onHandoff;
    if (give == null) {
      return _failed(ErrorCode.notFound, 'This app takes no handoffs');
    }
    // (its id and expiry are the host's to say, not the agent's)
    final draft = {
      ...input,
      'v': Handoff.version,
      'expiresAt': DateTime.now().add(handoffTtl).millisecondsSinceEpoch,
    }..remove('id');
    final problem = handoffProblem(draft);
    final handoff = problem == null ? parseHandoff(draft) : null;
    if (handoff == null) {
      return _failed(ErrorCode.badArgs, problem ?? 'Not a handoff');
    }
    final routes = _list(_map(_last?['route'])?['routes']);
    final route = handoff.route;
    if (route != null &&
        routes.isNotEmpty &&
        !routes.any((r) => matchRoute('${r['path']}', route) != null)) {
      return _failed(
        ErrorCode.badArgs,
        'No route $route (the routes: ${routes.map((r) => r['path']).join(', ')})',
      );
    }
    try {
      final said = await give(handoff);
      return ToolAnswer(
        'Handoff left: ${said == null || said.isEmpty ? 'the user gets it when they come back.' : said}',
      );
    } catch (e) {
      return _failed(e is AffordError ? e.code : ErrorCode.failed, '$e');
    }
  }

  Future<Json> _ask(Json request) async {
    try {
      return await send(request).timeout(timeout);
    } on TimeoutException {
      return {
        'error': 'The app did not answer in time (it may be in the background): look again later, or do it another way',
        'code': ErrorCode.timeout.wire,
      };
    } catch (e) {
      return {
        'error': '$e',
        'code': (e is AffordError ? e.code : ErrorCode.unavailable).wire,
      };
    }
  }

  static ToolAnswer _failed(ErrorCode code, String error) =>
      ToolAnswer('Failed (${code.wire}): $error', isError: true, code: code);
}

// ---------------- the shapes the common agent stacks take ----------------

/// Anthropic Messages API tools.
List<Json> anthropicTools(List<AgentTool> tools) => [
  for (final t in tools)
    {
      'name': t.name,
      'description': t.description,
      'input_schema': t.inputSchema,
    },
];

/// A tool_use block run: its tool_result block.
Future<Json> anthropicResult(AffordAgent agent, Json block) async {
  final a = await agent.handle('${block['name']}', _map(block['input']));
  // (a picture goes in the result beside the text)
  final content = a.images.isEmpty
      ? a.text
      : [
          {'type': 'text', 'text': a.text},
          for (final i in a.images)
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': i.mime,
                'data': i.data,
              },
            },
        ];
  return {
    'type': 'tool_result',
    'tool_use_id': block['id'],
    'content': content,
    if (a.isError) 'is_error': true,
  };
}

/// OpenAI Chat Completions tools.
List<Json> openaiTools(List<AgentTool> tools) => [
  for (final t in tools)
    {
      'type': 'function',
      'function': {
        'name': t.name,
        'description': t.description,
        'parameters': t.inputSchema,
      },
    },
];

/// A Chat Completions tool call run: its tool message.
Future<Json> openaiResult(AffordAgent agent, Json call) async {
  final f = _map(call['function']) ?? const {};
  Json? args;
  try {
    args = _map(jsonDecode('${f['arguments'] ?? '{}'}'));
  } on FormatException {
    args = null;
  }
  final a = await agent.handle('${f['name']}', args);
  return {'role': 'tool', 'tool_call_id': call['id'], 'content': a.text};
}

/// MCP tools/list result.
Json mcpToolList(AffordAgent agent) => {
  'tools': [
    for (final t in agent.tools())
      {
        'name': t.name,
        'description': t.description,
        'inputSchema': t.inputSchema,
      },
  ],
};

/// MCP tools/call: its result.
Future<Json> mcpToolCall(
  AffordAgent agent,
  String name,
  Json? arguments,
) async {
  final a = await agent.handle(name, arguments);
  return {
    'content': [
      {'type': 'text', 'text': a.text},
      for (final i in a.images)
        {'type': 'image', 'data': i.data, 'mimeType': i.mime},
    ],
    if (a.isError) 'isError': true,
  };
}
