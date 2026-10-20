/**
 * The agent's side of AffordKit, for whatever runs the model (no DOM here): the context as compact text for a prompt, and the tools
 * an agent uses to act on the app — each turned into a Call for the app's execute.
 */

import { isImage, type AffordContext, type AffordNode, type Call, type CallResult, type ItemsPage, type ItemTree, type PagePeek, type ParamsSchema, type RouteState } from './protocol.js';

function routeLines(route: RouteState): string[] {
  const params = route.params && Object.keys(route.params).length ? ` (${Object.entries(route.params).map(([k, v]) => `${k}=${v}`).join(', ')})` : '';
  const lines = [`Route: ${route.current}${route.pattern && route.pattern !== route.current ? ` = ${route.pattern}${params}` : ''}${route.canGoBack ? ' — can go back' : ''}`];
  if (route.routes.length) {
    lines.push('Routes:');
    for (const r of route.routes) {
      const ps = Object.entries(r.params ?? {}).map(([k, p]) => `:${k}${p.values ? ` ∈ {${p.values.join(', ')}}` : ''}${p.description ? ` (${p.description})` : ''}`);
      lines.push(`  ${r.path} — ${r.description}${ps.length ? `; ${ps.join('; ')}` : ''}`);
    }
  }
  return lines;
}

/** One node as a line (no children): [id key=…] role "name" (state) — description — ops. */
function nodeLine(n: AffordNode): string {
  // A container: what of, how many, which show, and how its entries' keys go — then only the other state
  let list = '';
  let entries = Object.entries(n.state ?? {});
  if (n.role === 'container') {
    const { count, first, last, kind } = n.state ?? {};
    list = `${kind ? ` (${kind})` : ''}${typeof count === 'number' ? ` ${count} entr${count === 1 ? 'y' : 'ies'}` : ''}${typeof first === 'number' ? `, showing ${first}–${last}` : ''}${n.key ? ` (entry keys: ${n.key}[<id>])` : ''}`;
    entries = entries.filter(([k]) => k !== 'count' && k !== 'first' && k !== 'last' && k !== 'kind');
  }
  const state = entries.length ? ` (${entries.map(([k, v]) => (v === true ? k : `${k}: ${v}`)).join(', ')})` : '';
  const ops = n.ops.map((o) => (o.policy === 'allow' ? o.name : `${o.name}(${o.policy})`)).join(', ');
  const id = n.key ? `${n.id} key=${n.key}` : n.id;
  // (what it shows, when it isn't its name already)
  const value = n.value !== undefined && n.value !== n.name ? ` = ${JSON.stringify(n.value)}` : '';
  return `[${id}] ${n.role}${n.name ? ` "${n.name}"` : ''}${value}${list}${state}${n.description ? ` — ${n.description}` : ''}${ops ? ` — ${ops}` : ''}`;
}

/** A container's entries on screen, in short (fetch one, op item, for its controls). */
function previewLines(n: AffordNode, pad: string): string[] {
  if (!n.preview?.length) return [];
  const lines = n.preview.map((i) => `${pad}· [${i.key ?? i.id}]${i.index !== undefined ? ` #${i.index}` : ''} ${JSON.stringify(i.name)}${i.description ? ` — ${i.description}` : ''}`);
  const more = typeof n.state?.count === 'number' ? n.state.count - n.preview.length : 0;
  lines.push(`${pad}· …${more > 0 ? ` ${more} more;` : ''} op item fetches an entry's controls, items pages through them`);
  return lines;
}

function treeLines(root: AffordNode, maxNodes: number): string[] {
  const lines: string[] = [];
  let count = 0;
  const walk = (n: AffordNode, depth: number) => {
    if (count++ >= maxNodes) return;
    lines.push('  '.repeat(depth) + nodeLine(n));
    for (const c of n.children ?? []) walk(c, depth + 1);
    lines.push(...previewLines(n, '  '.repeat(depth + 1)));
  };
  walk(root, 0);
  if (count > maxNodes) lines.push(`… ${count - maxNodes} more nodes`);
  return lines;
}

/**
 * The context as indented lines: the route, the routes, the tools, then the tree — `[n12 key=compose.send] button "Send" — press(deny)`,
 * a container as `[n3 key=mail.list] container "Inbox" (list) 312 entries, showing 0–14 (entry keys: mail.list[<id>]) — read, item,
 * items, scroll_to, scroll` with its preview under it (`· [mail.list[42]] #3 "Lunch?"`).
 */
export function describe(ctx: AffordContext, { maxNodes = 400 }: { maxNodes?: number } = {}): string {
  const lines: string[] = [];
  if (ctx.route) lines.push(...routeLines(ctx.route));
  if (ctx.tools.length) lines.push(`Tools: ${ctx.tools.map((t) => `${t.name}${t.policy !== 'allow' ? `(${t.policy})` : ''} — ${t.description}`).join('; ')}`);
  lines.push(...treeLines(ctx.root, maxNodes));
  return lines.join('\n');
}

/**
 * What changed on screen between two contexts, as text — what the agent gets after an act instead of the whole tree again: the
 * route if it changed, then the nodes that came (+, under the node they are in), went (-) or changed (~). When most of the screen
 * changed (another page), the whole new screen instead. Nodes are matched by key, else id (ids stay with their widget).
 */
export function describeChange(before: AffordContext, after: AffordContext, { maxNodes = 400, wholeOver = 0.5 }: { maxNodes?: number; wholeOver?: number } = {}): string {
  type Seen = { node: AffordNode; line: string; parent?: AffordNode };
  const flat = (root: AffordNode) => {
    const out = new Map<string, Seen>();
    const walk = (n: AffordNode, parent?: AffordNode) => {
      out.set(n.key ?? n.id, { node: n, line: nodeLine(n) + previewLines(n, ' ').join(''), ...(parent ? { parent } : {}) });
      for (const c of n.children ?? []) walk(c, n);
    };
    walk(root);
    return out;
  };
  const was = flat(before.root);
  const now = flat(after.root);
  const came = [...now].filter(([k]) => !was.has(k));
  const went = [...was].filter(([k]) => !now.has(k));
  const changed = [...now].filter(([k, v]) => was.has(k) && was.get(k)!.line !== v.line);
  const lines: string[] = [];
  const from = before.route?.current;
  const to = after.route?.current;
  if (to && to !== from) lines.push(`Now at ${to}${from ? ` (was ${from})` : ''}${after.route?.canGoBack ? ' — can go back' : ''}.`);
  if (came.length + went.length > Math.max(4, now.size * wholeOver)) {
    lines.push('The screen now:', describe(after, { maxNodes }));
    return lines.join('\n');
  }
  if (!came.length && !went.length && !changed.length) {
    lines.push('The screen did not change.');
    return lines.join('\n');
  }
  // A page that went under what is on top (a dialog opened, a page pushed) or came back from under it: its controls didn't change, say so
  const under = (s: Seen) => {
    let n = 0;
    const count = (x: AffordNode) => (x.children ?? []).forEach((c) => (n++, count(c)));
    count(s.node);
    return n;
  };
  const where = (s: Seen) => (s.parent && s.parent.role !== 'app' ? ` (in ${s.parent.key ?? s.parent.id}${s.parent.name ? ` "${s.parent.name}"` : ''})` : '');
  for (const [, s] of came.slice(0, maxNodes)) {
    if (s.node.state?.behind) lines.push(`+ [${s.node.id}] ${s.node.role}${s.node.name ? ` "${s.node.name}"` : ''} (behind) — now under what shows: its ${under(s)} controls still work, unseen`);
    else lines.push(`+ ${nodeLine(s.node)}${where(s)}`, ...previewLines(s.node, '    '));
  }
  for (const [, s] of went.slice(0, maxNodes)) {
    const back = s.node.state?.behind && (s.node.children ?? []).some((c) => now.has(c.key ?? c.id));
    lines.push(`- [${s.node.key ?? s.node.id}] ${s.node.role}${s.node.name ? ` "${s.node.name}"` : ''}${back ? ' — on top again: its controls show' : ''}`);
  }
  for (const [, s] of changed.slice(0, maxNodes)) lines.push(`~ ${nodeLine(s.node)}`, ...previewLines(s.node, '    '));
  return ['The screen changed:', ...lines].join('\n');
}

/** A peeked page as text. */
export function describePage(view: PagePeek, { maxNodes = 300 }: { maxNodes?: number } = {}): string {
  const how = {
    live: 'showing now',
    preview: 'built off screen just now, as it would open',
    seen: `as it was when it last showed${view.seenAt ? ` (${new Date(view.seenAt).toISOString()})` : ''}`,
    declared: 'never seen: only what the route says',
  }[view.source];
  const lines = [`Page ${view.route}${view.pattern && view.pattern !== view.route ? ` = ${view.pattern}` : ''} — ${how}${view.description ? `. ${view.description}` : ''}`];
  if (view.root) {
    if (view.source !== 'live') lines.push('(Peek ids cannot be acted on: navigate there, then act by key, or look again for live ids.)');
    lines.push(...treeLines(view.root, maxNodes));
  }
  return lines.join('\n');
}

export interface AgentTool {
  name: string;
  description: string;
  inputSchema: ParamsSchema;
}

/** The tools an agent gets for acting on the app's UI. */
export const AGENT_TOOLS: AgentTool[] = [
  {
    name: 'ui_look',
    description:
      'See what is on the user\'s screen now: the route, and the tree of controls (each with an id — and a key when the app gives one — what it is, what it shows, its state and the ops it allows). picture: true also gives a picture of the screen, for what the tree can\'t say (images, layout, colors) — when the app can take one.',
    inputSchema: { type: 'object', properties: { picture: { type: 'boolean', description: 'Also a picture of the screen' } } },
  },
  {
    name: 'ui_act',
    description:
      'Do an op on a control by its id or key: e.g. read a field or a page\'s text, write into a field, press a button, toggle a switch, pick an option. Ops marked deny are for the user only; confirm ones wait for their yes. ' +
      'A page or dialog node marked behind is under what shows (another page, a dialog): its controls still work, but the user does not see them act — when they are watching, go to that page first unless it is a small aside. ' +
      'A container (many of the same thing: a mail list, a thread\'s messages) shows only a preview of its entries, not their controls: fetch one with its op "item" (args: id, or index, or query) and the answer is that entry as a tree of its own, with ids and keys to act on next (e.g. item {id: "42"} on mail.list → mail.list[42].reply). "items" pages through all its entries\' keys and names. An entry\'s key — container key + [id], controls in it under that, mail.list[42].reply — can also be acted on straight away, even off screen: it is fetched (scrolled to) first. scroll_to / scroll move the container.',
    inputSchema: {
      type: 'object',
      properties: { node: { type: 'string', description: 'The control\'s id or key from the tree' }, op: { type: 'string', description: 'One of its ops' }, args: { type: 'object', description: 'The op\'s arguments, e.g. { "text": "…" }' } },
      required: ['node', 'op'],
    },
  },
  {
    name: 'ui_tool',
    description: 'Run one of the app\'s own tools (listed with the tree).',
    inputSchema: { type: 'object', properties: { name: { type: 'string' }, args: { type: 'object' } }, required: ['name'] },
  },
  {
    name: 'ui_navigate',
    description: 'Take the user to a route of the app (listed with the tree, filling in its :params), or "back". The answer is the new page\'s tree.',
    inputSchema: { type: 'object', properties: { route: { type: 'string', description: 'e.g. /settings/ai, or back' } }, required: ['route'] },
  },
  {
    name: 'ui_peek',
    description:
      'See another page\'s controls without taking the user there, to plan: what is on it and the keys to act on after navigating (e.g. peek /settings/ai, then navigate there and act by key). Says whether it is current or as last seen.',
    inputSchema: { type: 'object', properties: { route: { type: 'string', description: 'e.g. /settings/ai' } }, required: ['route'] },
  },
  {
    name: 'ui_handoff',
    description:
      'Only when the user is away (the other ui_ tools answer code away): do what you can with your other tools, then leave the user a handoff for when they come back — a short message, and where to take them: route, the page to open first (one of the routes), then calls, ops to run there in order. The app usually shows it as a notification, and runs it when they tap. ' +
      'A call names a control by its key, never its id (ids don\'t last until then): e.g. {key: "drafts.list[42]", op: "press"} to open the draft you wrote. Keep it to bringing them to the result — open the page, the item; nothing that sends, pays, deletes or can\'t be undone: they see it happen, and ops that need their yes still ask. At most 20 calls; message at most 500 characters, in the user\'s language.',
    inputSchema: {
      type: 'object',
      properties: {
        message: { type: 'string', description: 'What you did and what is waiting for them, in a sentence or two' },
        route: { type: 'string', description: 'The page to open first, e.g. /drafts' },
        calls: {
          type: 'array',
          description: 'Then these, in order: { key, op, args? }',
          items: { type: 'object', properties: { key: { type: 'string' }, op: { type: 'string' }, args: { type: 'object' } }, required: ['key', 'op'] },
        },
      },
      required: ['message'],
    },
  },
];

/** One of AGENT_TOOLS called by the agent → what the app should run (null for ui_look: just send the context; ui_handoff is not one). */
export function toCall(tool: string, args: Record<string, unknown>): Call | null {
  const obj = (v: unknown) => (v && typeof v === 'object' ? (v as Record<string, unknown>) : {});
  switch (tool) {
    case 'ui_look':
      return null;
    case 'ui_act':
      return { node: String(args.node ?? ''), op: String(args.op ?? ''), args: obj(args.args) };
    case 'ui_tool':
      return { tool: String(args.name ?? ''), args: obj(args.args) };
    case 'ui_navigate':
      return { navigate: String(args.route ?? '') };
    case 'ui_peek':
      return { peek: String(args.route ?? '') };
    case 'ui_handoff':
      throw new Error('ui_handoff is not a call to the app: it goes to the host (AffordRemote with onHandoff)');
  }
  throw new Error(`Not an AffordKit tool: ${tool}`);
}

/** A result as text for the agent. */
export function describeResult(r: CallResult): string {
  if (!r.ok) return r.needsConfirm ? `Waiting: ${r.error}` : `Failed${r.code ? ` (${r.code})` : ''}: ${r.error}`;
  if ('peek' in r.call && r.value && typeof r.value === 'object') return describePage(r.value as PagePeek);
  if ('navigate' in r.call) return `Now at ${String(r.value ?? r.call.navigate)}.`;
  if ('op' in r.call && r.call.op === 'items' && r.value && typeof r.value === 'object' && Array.isArray((r.value as ItemsPage).items)) return describeItems(r.value as ItemsPage);
  if ('op' in r.call && r.call.op === 'item' && r.value && typeof r.value === 'object' && (r.value as ItemTree).root) return describeItem(r.value as ItemTree);
  if (isImage(r.value)) return describeImage(r.value);
  return r.value === undefined ? 'Done.' : typeof r.value === 'string' ? r.value : JSON.stringify(r.value);
}

/** A picture as text (the picture itself goes beside it, where the agent's stack can take one). */
export function describeImage(v: { mime: string; data?: string; url?: string; width?: number; height?: number }): string {
  const size = v.width && v.height ? `${v.width}×${v.height} ` : '';
  return v.data ? `(A picture, ${size}${v.mime}: attached.)` : `(A picture at ${v.url ?? 'an unknown place'}${size ? `, ${size.trim()}` : ''}: it could not be read here.)`;
}

/** A fetched entry as text: what it is, then its tree. */
export function describeItem(item: ItemTree, { maxNodes = 200 }: { maxNodes?: number } = {}): string {
  const head = `Entry ${item.key ?? item.id}${item.index !== undefined ? ` #${item.index}` : ''}${item.source === 'preview' ? ' — built off screen: its ids cannot be acted on, act by key (that brings it in)' : ''}:`;
  return [head, ...treeLines(item.root, maxNodes)].join('\n');
}

/** A page of a container's entries as text: one per line, by key (or id). */
export function describeItems(page: ItemsPage): string {
  const end = page.offset + page.items.length;
  const head = page.items.length ? `Items ${page.offset}–${end - 1}${page.count !== undefined ? ` of ${page.count}` : ''}:` : `No items${page.offset ? ` from ${page.offset}` : ''}${page.count !== undefined ? ` (${page.count} in all)` : ''}.`;
  const lines = page.items.map((i) => `  [${i.key ?? i.id}]${i.index !== undefined ? ` #${i.index}` : ''} ${JSON.stringify(i.name)}${i.description ? ` — ${i.description}` : ''}`);
  return [head, ...lines].join('\n');
}
