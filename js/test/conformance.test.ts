// The agent side's conformance cases (conformance/remote.json, at the repository root), shared by every port of it (TypeScript,
// Python, Go): each case runs AffordRemote against an app that answers as scripted, and records what it sent the app and what the
// agent got back. Run with CONFORMANCE_UPDATE=1 to write the file from this implementation; without it, this implementation is
// checked against the file like the others.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { AffordError, AffordRemote, anthropicResult, anthropicTools, mcpHandlers, openaiResponsesResult, openaiResponsesTools, openaiResult, openaiTools, type AffordContext, type AffordNode, type UiAnswer, type UiRequest } from '../src/index.js';

const file = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../conformance/remote.json');

// ---------------- screens ----------------

const n = (id: string, role: AffordNode['role'], name: string, ops: string[] = [], more: Partial<AffordNode> = {}): AffordNode => ({
  id,
  role,
  name,
  ops: ops.map((o) => (o.includes(':') ? { name: o.split(':')[0]!, policy: o.split(':')[1] as 'confirm' | 'deny' } : { name: o, policy: 'allow' as const })),
  ...more,
});

const routes = [
  { path: '/mail/:box', description: 'A mailbox', params: { box: { values: ['inbox', 'archive'], description: 'which' } } },
  { path: '/message/:id', description: 'One mail' },
  { path: '/reply/:id', description: 'Writing a reply' },
  { path: '/drafts', description: 'The drafts' },
];

const inbox: AffordContext = {
  protocol: 1,
  route: { current: '/mail/inbox', pattern: '/mail/:box', params: { box: 'inbox' }, canGoBack: false, routes },
  tools: [
    { name: 'set_theme', description: 'Switch the theme', inputSchema: { type: 'object', properties: { theme: { type: 'string', enum: ['light', 'dark'] } }, required: ['theme'] }, policy: 'allow' },
    { name: 'empty_trash', description: 'Delete the trash for good', inputSchema: { type: 'object', properties: {} }, policy: 'confirm' },
  ],
  root: n('app', 'app', 'Mail', ['read'], {
    children: [
      n('w1', 'heading', 'Inbox', [], { value: 'Inbox' }),
      n('w2', 'textbox', 'Search', ['read', 'write', 'append', 'clear'], { key: 'mail.search', state: { length: 0 }, description: 'Words to look for' }),
      n('w3', 'container', 'Inbox', ['read', 'item', 'items', 'scroll_to', 'scroll'], {
        key: 'mail.list',
        state: { kind: 'list', count: 312, first: 0, last: 2 },
        preview: [
          { key: 'mail.list[42]', id: '42', index: 0, name: 'Lunch on Tuesday?', description: 'Wang · 10:15' },
          { key: 'mail.list[41]', id: '41', index: 1, name: 'Invoice "October"' },
          { id: '40', index: 2, name: 'Weekly sync' },
        ],
      }),
      n('w4', 'button', 'Compose', ['press'], { key: 'mail.compose' }),
      n('w5', 'switch', 'Notify me', ['toggle', 'set'], { state: { checked: true } }),
      n('w6', 'textbox', 'Password', ['read:deny', 'write:deny'], { state: { filled: true } }),
    ],
  }),
};

// The thread of mail 42: another page (most of the screen changes)
const thread: AffordContext = {
  protocol: 1,
  route: { current: '/message/42', pattern: '/message/:id', params: { id: '42' }, canGoBack: true, routes },
  tools: inbox.tools,
  root: n('app', 'app', 'Mail', ['read'], {
    children: [
      n('w10', 'heading', 'Lunch on Tuesday?', [], { value: 'Lunch on Tuesday?' }),
      n('w11', 'button', 'Reply', ['press'], { key: 'thread.reply' }),
      n('w12', 'text', 'Message', ['read'], { key: 'thread.body' }),
      n('w13', 'button', 'Delete', ['press:confirm'], { key: 'thread.delete' }),
    ],
  }),
};

// The inbox a moment later: a field filled in, the list scrolled, Compose gone, a dialog in front of the page
const inboxAfter: AffordContext = {
  ...inbox,
  root: n('app', 'app', 'Mail', ['read'], {
    children: [
      n('p1', 'page', 'Inbox page', ['read'], {
        state: { behind: true },
        children: [
          n('w1', 'heading', 'Inbox', [], { value: 'Inbox' }),
          n('w2', 'textbox', 'Search', ['read', 'write', 'append', 'clear'], { key: 'mail.search', state: { length: 7 }, description: 'Words to look for' }),
          n('w3', 'container', 'Inbox', ['read', 'item', 'items', 'scroll_to', 'scroll'], {
            key: 'mail.list',
            state: { kind: 'list', count: 1, first: 0, last: 0 },
            preview: [{ key: 'mail.list[7]', id: '7', index: 0, name: 'Invoice' }],
          }),
          n('w5', 'switch', 'Notify me', ['toggle', 'set'], { state: { checked: false } }),
          n('w6', 'textbox', 'Password', ['read:deny', 'write:deny'], { state: { filled: true } }),
        ],
      }),
      n('d1', 'dialog', 'Search tips', ['read'], { value: 'Use quotes for a phrase' }),
    ],
  }),
};

// The reply page: the route changes, a few controls come and go
const reply: AffordContext = {
  ...thread,
  route: { current: '/reply/42', pattern: '/reply/:id', params: { id: '42' }, canGoBack: true, routes },
  root: n('app', 'app', 'Mail', ['read'], {
    children: [
      n('w10', 'heading', 'Lunch on Tuesday?', [], { value: 'Lunch on Tuesday?' }),
      n('w12', 'text', 'Message', ['read'], { key: 'thread.body' }),
      n('w13', 'button', 'Delete', ['press:confirm'], { key: 'thread.delete' }),
      n('w20', 'region', 'Reply', ['read'], {
        key: 'compose',
        children: [n('w21', 'textbox', 'Body', ['read', 'write', 'append', 'clear'], { key: 'compose.body' }), n('w22', 'button', 'Send', ['press:deny'], { key: 'compose.send' })],
      }),
    ],
  }),
};

const noTools: AffordContext = { ...inbox, tools: [] };
const noRoute: AffordContext = { protocol: 1, tools: [], root: n('app', 'app', '', [], { children: [n('a', 'button', 'OK', ['press'])] }) };

// ---------------- cases ----------------

/** What the app does with one request: answer, never answer (a timeout), or fail to deliver it. */
type Reply = UiAnswer | { never: true } | { throws: string; code?: string } | Record<string, never> | string;

interface Step {
  tool: string;
  input?: Record<string, unknown>;
  /** The app's reply to the request this step sends (absent: it sends none). */
  reply?: Reply;
  /** What the handoff host answers (ui_handoff with onHandoff), or that it throws. */
  handoffSays?: string | { throws: string; code?: string };
}

interface Case {
  name: string;
  options?: { timeoutMs?: number; screen?: 'changes' | 'whole'; tools?: string[]; maxNodes?: number; present?: boolean; handoff?: boolean };
  seen?: AffordContext | null;
  steps: Step[];
}

const ok = (context: AffordContext, results: UiAnswer extends infer A ? (A extends { results?: infer R } ? R : never) : never, more: object = {}): UiAnswer => ({ context, results, ...more }) as UiAnswer;

const cases: Case[] = [
  { name: 'look: the whole screen, route, routes and tools', steps: [{ tool: 'ui_look', reply: { context: inbox } }] },
  { name: 'look: no route, no tools', steps: [{ tool: 'ui_look', reply: { context: noRoute } }] },
  {
    name: 'look with picture: the picture goes beside the text',
    steps: [{ tool: 'ui_look', input: { picture: true }, reply: { context: inbox, picture: { type: 'image', mime: 'image/png', data: 'iVBORw0KGgo=', width: 2, height: 1 } } }],
  },
  { name: 'look with picture, none taken', steps: [{ tool: 'ui_look', input: { picture: true }, reply: { context: inbox } }] },
  { name: 'look: a small node budget cuts the tree short', options: { maxNodes: 3 }, steps: [{ tool: 'ui_look', reply: { context: inbox } }] },
  {
    name: 'act after a look: only what changed (came under a parent, went, changed, behind)',
    steps: [
      { tool: 'ui_look', reply: { context: inbox } },
      { tool: 'ui_act', input: { node: 'mail.search', op: 'write', args: { text: 'invoice' } }, reply: ok(inboxAfter, [{ call: { node: 'mail.search', op: 'write', args: { text: 'invoice' } }, ok: true }]) },
    ],
  },
  {
    name: 'act with nothing seen before: the whole screen after',
    steps: [{ tool: 'ui_act', input: { node: 'w4', op: 'press' }, reply: ok(thread, [{ call: { node: 'w4', op: 'press', args: {} }, ok: true }]) }],
  },
  {
    name: 'seen first (sent with the message): the first act answers with what changed; another page is the whole screen',
    seen: inbox,
    steps: [
      { tool: 'ui_act', input: { node: 'mail.list[42]', op: 'press' }, reply: ok(thread, [{ call: { node: 'mail.list[42]', op: 'press', args: {} }, ok: true }]) },
      { tool: 'ui_act', input: { node: 'thread.reply', op: 'press' }, reply: ok(reply, [{ call: { node: 'thread.reply', op: 'press', args: {} }, ok: true }]) },
      { tool: 'ui_act', input: { node: 'thread.body', op: 'read' }, reply: ok(reply, [{ call: { node: 'thread.body', op: 'read', args: {} }, ok: true, value: 'Can we meet at ten?' }]) },
      { tool: 'ui_act', input: { node: 'compose.body', op: 'write', args: { text: 'Yes' } }, reply: ok(reply, [{ call: { node: 'compose.body', op: 'write', args: { text: 'Yes' } }, ok: true, value: { length: 3 } }]) },
    ],
  },
  {
    name: 'act: failures with their codes, waiting for a yes',
    seen: thread,
    steps: [
      { tool: 'ui_act', input: { node: 'nope', op: 'press' }, reply: ok(thread, [{ call: { node: 'nope', op: 'press', args: {} }, ok: false, code: 'not_found', error: 'No node nope' }]) },
      { tool: 'ui_act', input: { node: 'compose.send', op: 'press' }, reply: ok(thread, [{ call: { node: 'compose.send', op: 'press', args: {} }, ok: false, code: 'denied', error: 'Send is the user\'s to press' }]) },
      { tool: 'ui_act', input: { node: 'thread.delete', op: 'press' }, reply: ok(thread, [{ call: { node: 'thread.delete', op: 'press', args: {} }, ok: false, needsConfirm: true, error: 'Delete needs the user\'s yes' }]) },
      { tool: 'ui_act', input: { node: 'w12', op: 'fly' }, reply: ok(thread, [{ call: { node: 'w12', op: 'fly', args: {} }, ok: false, error: 'No op fly' }]) },
    ],
  },
  {
    name: 'act: an entry of a container, and a page of its entries',
    seen: inbox,
    steps: [
      {
        tool: 'ui_act',
        input: { node: 'mail.list', op: 'item', args: { id: '42' } },
        reply: ok(inbox, [
          {
            call: { node: 'mail.list', op: 'item', args: { id: '42' } },
            ok: true,
            value: { key: 'mail.list[42]', id: '42', index: 0, source: 'live', root: n('e42', 'listitem', 'Lunch on Tuesday?', ['press'], { key: 'mail.list[42]', children: [n('e43', 'button', 'Reply', ['press'], { key: 'mail.list[42].reply' })] }) },
          },
        ]),
      },
      {
        tool: 'ui_act',
        input: { node: 'mail.list', op: 'item', args: { id: '9' } },
        reply: ok(inbox, [{ call: { node: 'mail.list', op: 'item', args: { id: '9' } }, ok: true, value: { key: 'mail.list[9]', id: '9', source: 'preview', root: n('p9', 'listitem', 'Old mail', ['press'], { key: 'mail.list[9]' }) } }]),
      },
      {
        tool: 'ui_act',
        input: { node: 'mail.list', op: 'items', args: { offset: 10, limit: 2 } },
        reply: ok(inbox, [
          {
            call: { node: 'mail.list', op: 'items', args: { offset: 10, limit: 2 } },
            ok: true,
            value: { offset: 10, count: 312, items: [{ key: 'mail.list[30]', id: '30', index: 10, name: 'A', description: 'from B' }, { id: '29', index: 11, name: 'C' }] },
          },
        ]),
      },
      { tool: 'ui_act', input: { node: 'mail.list', op: 'items', args: { offset: 400 } }, reply: ok(inbox, [{ call: { node: 'mail.list', op: 'items', args: { offset: 400 } }, ok: true, value: { offset: 400, count: 312, items: [] } }]) },
    ],
  },
  {
    name: 'act: a picture of a control comes back beside the text',
    seen: inbox,
    steps: [
      { tool: 'ui_act', input: { node: 'w1', op: 'view' }, reply: ok(inbox, [{ call: { node: 'w1', op: 'view', args: {} }, ok: true, value: { type: 'image', mime: 'image/jpeg', data: '/9j/4AAQ', width: 40, height: 20 } }]) },
      { tool: 'ui_act', input: { node: 'w1', op: 'view' }, reply: ok(inbox, [{ call: { node: 'w1', op: 'view', args: {} }, ok: true, value: { type: 'image', mime: 'image/png', url: 'https://example.com/a.png' } }]) },
    ],
  },
  {
    name: 'navigate and back: where it is now; peek a page in each of its sources',
    seen: inbox,
    steps: [
      { tool: 'ui_navigate', input: { route: '/message/42' }, reply: ok(thread, [{ call: { navigate: '/message/42' }, ok: true, value: '/message/42' }]) },
      { tool: 'ui_navigate', input: { route: 'back' }, reply: ok(inbox, [{ call: { navigate: 'back' }, ok: true, value: '/mail/inbox' }]) },
      { tool: 'ui_navigate', input: { route: '/nowhere' }, reply: ok(inbox, [{ call: { navigate: '/nowhere' }, ok: false, code: 'not_found', error: 'No route /nowhere' }]) },
      { tool: 'ui_peek', input: { route: '/message/42' }, reply: ok(inbox, [{ call: { peek: '/message/42' }, ok: true, value: { route: '/message/42', pattern: '/message/:id', source: 'preview', description: 'One mail', root: thread.root } }]) },
      { tool: 'ui_peek', input: { route: '/drafts' }, reply: ok(inbox, [{ call: { peek: '/drafts' }, ok: true, value: { route: '/drafts', source: 'seen', seenAt: 1792711772948, root: noRoute.root } }]) },
      { tool: 'ui_peek', input: { route: '/reply/42' }, reply: ok(inbox, [{ call: { peek: '/reply/42' }, ok: true, value: { route: '/reply/42', pattern: '/reply/:id', source: 'declared', description: 'Writing a reply' } }]) },
      { tool: 'ui_peek', input: { route: '/mail/inbox' }, reply: ok(inbox, [{ call: { peek: '/mail/inbox' }, ok: true, value: { route: '/mail/inbox', pattern: '/mail/:box', source: 'live', root: inbox.root } }]) },
    ],
  },
  {
    name: 'the app\'s own tools: a word back, an object back, a refusal',
    seen: inbox,
    steps: [
      { tool: 'ui_tool', input: { name: 'set_theme', args: { theme: 'dark' } }, reply: ok(inbox, [{ call: { tool: 'set_theme', args: { theme: 'dark' } }, ok: true, value: 'Theme: dark' }]) },
      { tool: 'ui_tool', input: { name: 'set_theme' }, reply: ok(inbox, [{ call: { tool: 'set_theme', args: {} }, ok: true, value: { theme: 'light', changed: false } }]) },
      { tool: 'ui_tool', input: { name: 'set_theme', args: { theme: 'x' } }, reply: ok(inbox, [{ call: { tool: 'set_theme', args: { theme: 'x' } }, ok: true }]) },
      { tool: 'ui_tool', input: { name: 'empty_trash' }, reply: ok(inbox, [{ call: { tool: 'empty_trash', args: {} }, ok: false, code: 'declined', error: 'The user said no' }]) },
    ],
  },
  {
    name: 'what the user did meanwhile comes first, on a look and after an act',
    seen: inbox,
    steps: [
      {
        tool: 'ui_look',
        reply: {
          context: inboxAfter,
          userActions: [
            { at: 1, op: 'write', node: { id: 'w2', key: 'mail.search', role: 'textbox', name: 'Search' }, value: 'invoice' },
            { at: 2, op: 'toggle', node: { id: 'w5', role: 'switch', name: 'Notify me' }, value: 'off' },
          ],
        },
      },
      {
        tool: 'ui_act',
        input: { node: 'mail.compose', op: 'press' },
        reply: ok(thread, [{ call: { node: 'mail.compose', op: 'press', args: {} }, ok: true }], {
          userActions: [
            { at: 3, op: 'press', node: { id: 'w3', key: 'mail.list[42]', role: 'listitem', name: 'Lunch on Tuesday?' }, route: '/message/42' },
            { at: 4, op: 'select', node: { id: 'w8', role: 'tab', name: 'Archive' }, value: 'Archive' },
            { at: 5, op: 'navigate', route: '/drafts' },
            { at: 6, op: 'back', route: '/mail/inbox' },
            { at: 7, op: 'back' },
            { at: 8, op: 'scroll', node: { id: 'w3', key: 'mail.list', role: 'container', name: 'Inbox' } },
            { at: 9, op: 'append', node: { id: 'w21', role: 'textbox', name: '' } },
          ],
        }),
      },
      { tool: 'ui_look', reply: { context: inboxAfter, userActions: [] } },
    ],
  },
  {
    name: 'the whole screen after each act when asked',
    options: { screen: 'whole' },
    seen: inbox,
    steps: [
      { tool: 'ui_act', input: { node: 'w5', op: 'toggle' }, reply: ok(noTools, [{ call: { node: 'w5', op: 'toggle', args: {} }, ok: true }]) },
      { tool: 'ui_navigate', input: { route: '/message/42' }, reply: ok(thread, [{ call: { navigate: '/message/42' }, ok: true, value: '/message/42' }]) },
    ],
  },
  {
    name: 'no change on screen',
    seen: thread,
    steps: [{ tool: 'ui_act', input: { node: 'thread.body', op: 'read' }, reply: ok(thread, [{ call: { node: 'thread.body', op: 'read', args: {} }, ok: true, value: '' }]) }],
  },
  {
    name: 'the app could not do it: its error, a lost request, an answer without results, no answer, an answer that is none',
    options: { timeoutMs: 50 },
    seen: inbox,
    steps: [
      { tool: 'ui_look', reply: { error: 'The page is still loading', code: 'unavailable' } },
      { tool: 'ui_look', reply: { error: 'Something broke' } },
      { tool: 'ui_act', input: { node: 'w4', op: 'press' }, reply: { throws: 'The socket closed' } },
      { tool: 'ui_act', input: { node: 'w4', op: 'press' }, reply: { throws: 'Not on screen', code: 'unreachable' } },
      { tool: 'ui_act', input: { node: 'w4', op: 'press' }, reply: { context: inbox, results: [] } },
      { tool: 'ui_act', input: { node: 'w4', op: 'press' }, reply: { never: true } },
      { tool: 'ui_look', reply: {} },
      { tool: 'ui_look', reply: 'not an answer' },
    ],
  },
  {
    name: 'bad input: an unknown tool, missing arguments taken as empty',
    seen: inbox,
    steps: [
      { tool: 'ui_fly' },
      { tool: 'ui_act', input: {}, reply: ok(inbox, [{ call: { node: '', op: '', args: {} }, ok: false, code: 'not_found', error: 'No node ' }]) },
      { tool: 'ui_act', input: { node: 'w2', op: 'write', args: 'oops' }, reply: ok(inbox, [{ call: { node: 'w2', op: 'write', args: {} }, ok: false, code: 'bad_args', error: 'write needs text' }]) },
    ],
  },
  {
    name: 'the user away: screen tools answer away without asking the app',
    options: { present: false, handoff: true },
    steps: [{ tool: 'ui_look' }, { tool: 'ui_act', input: { node: 'w4', op: 'press' } }, { tool: 'ui_navigate', input: { route: '/drafts' } }],
  },
  {
    name: 'handoffs: left, checked against the routes, refused',
    options: { handoff: true, present: false },
    seen: inbox,
    steps: [
      { tool: 'ui_handoff', input: { message: 'Your reply to Wang is in Drafts.', route: '/drafts', calls: [{ key: 'drafts.list[7]', op: 'press' }] }, handoffSays: 'notification sent' },
      { tool: 'ui_handoff', input: { message: 'Done.' }, handoffSays: '' },
      { tool: 'ui_handoff', input: { message: 'Look.', route: '/nowhere' } },
      { tool: 'ui_handoff', input: { message: 'Go back.', route: 'back' } },
      { tool: 'ui_handoff', input: { message: 'Look.', route: '/mail/%zz' } },
      { tool: 'ui_handoff', input: { route: '/drafts' } },
      { tool: 'ui_handoff', input: { message: 'x'.repeat(501) } },
      { tool: 'ui_handoff', input: { message: 'Open it.', calls: [{ op: 'press' }] } },
      { tool: 'ui_handoff', input: { message: 'Open it.', calls: Array.from({ length: 21 }, () => ({ key: 'a', op: 'press' })) } },
      { tool: 'ui_handoff', input: { message: 'Open it.', id: 'mine', expiresAt: 1 }, handoffSays: 'kept' },
      { tool: 'ui_handoff', input: { message: 'Open it.' }, handoffSays: { throws: 'No push token', code: 'unavailable' } },
    ],
  },
  { name: 'handoff without a host: not offered, refused', steps: [{ tool: 'ui_handoff', input: { message: 'Hi' } }] },
];

// ---------------- running ----------------

interface Recorded {
  /** What the remote sent the app, when it did. */
  request?: UiRequest;
  /** The handoff given to the host (expiresAt left out: it is the time it was left), when it was. */
  handoff?: Record<string, unknown>;
  text: string;
  isError: boolean;
  code?: string;
  images?: { mime: string; data: string }[];
}

async function run(c: Case) {
  const steps: Recorded[] = [];
  let step: Step | undefined;
  let rec: Recorded = { text: '', isError: false };
  const ui = new AffordRemote({
    send: (request) => {
      rec.request = JSON.parse(JSON.stringify(request));
      const reply = step?.reply;
      if (!reply) throw new Error(`step sent a request it has no reply for: ${JSON.stringify(request)}`);
      if (typeof reply === 'object' && 'never' in reply) return new Promise<UiAnswer>(() => {});
      if (typeof reply === 'object' && 'throws' in reply) return Promise.reject(reply.code ? new AffordError(reply.code as never, reply.throws) : new Error(reply.throws));
      return Promise.resolve(JSON.parse(JSON.stringify(reply)));
    },
    ...(c.options?.timeoutMs ? { timeoutMs: c.options.timeoutMs } : {}),
    ...(c.options?.screen ? { screen: c.options.screen } : {}),
    ...(c.options?.tools ? { tools: c.options.tools } : {}),
    ...(c.options?.maxNodes ? { maxNodes: c.options.maxNodes } : {}),
    ...(c.options?.present === false ? { present: () => false } : {}),
    ...(c.options?.handoff
      ? {
          onHandoff: (h) => {
            const { expiresAt, ...rest } = h as unknown as Record<string, unknown>;
            expect(typeof expiresAt).toBe('number');
            rec.handoff = rest;
            const says = step?.handoffSays;
            if (says && typeof says === 'object') throw says.code ? new AffordError(says.code as never, says.throws) : new Error(says.throws);
            return says;
          },
        }
      : {}),
  });
  ui.seen(c.seen ?? null);
  const toolsBefore = ui.tools().map((t) => t.name);
  for (step of c.steps) {
    rec = { text: '', isError: false };
    const a = await ui.handle(step.tool, step.input ?? {});
    rec.text = a.text;
    rec.isError = a.isError;
    if (a.code) rec.code = a.code;
    if (a.images?.length) rec.images = a.images;
    steps.push(rec);
  }
  return { toolsBefore, toolsAfter: ui.tools().map((t) => t.name), steps };
}

/** The model-facing shapes of the tools and of an answer, for each stack. */
async function shapes() {
  const answering = new AffordRemote({ send: async () => ({ context: inbox, picture: { type: 'image', mime: 'image/png', data: 'AAAA' } }) });
  const failing = new AffordRemote({ send: async () => ({ error: 'gone', code: 'unavailable' }) });
  const tools = answering.tools();
  const mcp = mcpHandlers(answering);
  return {
    anthropicTools: anthropicTools(tools),
    openaiTools: openaiTools(tools),
    openaiResponsesTools: openaiResponsesTools(tools),
    mcpList: await mcp.list(),
    anthropicResult: await anthropicResult(answering, { id: 'toolu_1', name: 'ui_look', input: { picture: true } }),
    anthropicResultError: await anthropicResult(failing, { id: 'toolu_2', name: 'ui_look', input: {} }),
    openaiResult: await openaiResult(answering, { id: 'call_1', function: { name: 'ui_look', arguments: '{"picture":true}' } }),
    openaiResultBadJson: await openaiResult(failing, { id: 'call_2', function: { name: 'ui_look', arguments: '{oops' } }),
    openaiResponsesResult: await openaiResponsesResult(answering, { call_id: 'fc_1', name: 'ui_look', arguments: '' }),
    mcpCall: await mcp.call({ params: { name: 'ui_look', arguments: { picture: true } } }),
    mcpCallError: await mcpHandlers(failing).call({ params: { name: 'ui_look' } }),
  };
}

async function build() {
  const out = [];
  for (const c of cases) out.push({ name: c.name, options: c.options ?? {}, seen: c.seen ?? null, steps: c.steps, expect: await run(c) });
  return { version: 1, about: 'AffordRemote conformance: see conformance/README.md', cases: out, shapes: await shapes() };
}

describe('conformance (conformance/remote.json)', () => {
  it('this implementation gives what the file says', async () => {
    const built = JSON.parse(JSON.stringify(await build()));
    if (process.env.CONFORMANCE_UPDATE) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, `${JSON.stringify(built, null, 2)}\n`);
    }
    const want = JSON.parse(fs.readFileSync(file, 'utf8'));
    expect(built).toEqual(want);
  });
});
