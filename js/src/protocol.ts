/**
 * The AffordKit protocol: what an app's UI looks like to an AI agent, and how the agent acts on it. The same format on every
 * platform (DOM, Flutter): an app builds a tree of the controls on screen (context), the agent reads it and answers with calls,
 * the app runs them (execute) and the results go back to the agent as the next round's context.
 *
 * - Only controls that mean something are in the tree; pure layout is passed through (children move up to the nearest node).
 * - A node says what it is, what it's called, a short state — never its content: that is read on demand (the "read" op), so the
 *   first round stays small.
 * - Every control type comes with the operations you'd expect of it (STANDARD_OPS): a button is pressed, a text field is read and
 *   written, a switch is toggled... Apps add their own (a node's custom ops, and app-wide tools).
 * - Each operation has a policy: allow (just do it), confirm (only after the user says yes), deny (the agent can see it but never
 *   do it — e.g. the button that sends an email).
 * - The app's pages are routes: the agent knows where the user is, can take them elsewhere (navigate, or back), and can look at
 *   another page's tree before going there (peek) — so it can plan "go to settings, pick the model" in one round, addressing the
 *   controls there by the stable keys the app gives them.
 * - Many of the same thing (a mail list, a grid, a thread's messages, tabs) is a container: ONE node in the tree — how many entries,
 *   which show, a short preview of them — never their controls. The agent fetches an entry with the container's `item` op and gets
 *   it as a tree of its own (live ids and keys it can act on), or pages through all entries' summaries (`items`). Each entry has a
 *   key made from the container's (`mail.list[42]`), controls inside it keys under that (`mail.list[42].reply`); an entry that
 *   isn't built (virtualized) is scrolled to first. Acting on such a key straight away works too. Containers nest.
 */

export const PROTOCOL_VERSION = 1;

export type Role =
  | 'app'
  | 'page'
  | 'region'
  | 'dialog'
  | 'button'
  | 'link'
  | 'textbox'
  | 'checkbox'
  | 'switch'
  | 'radio'
  | 'select'
  | 'tab'
  | 'container'
  | 'list'
  | 'listitem'
  | 'heading'
  | 'text'
  | 'image'
  | 'other';

export type Policy = 'allow' | 'confirm' | 'deny';

/** A JSON Schema (an object's properties) for an operation's or a tool's arguments. */
export interface ParamsSchema {
  type: 'object';
  properties: Record<string, { type: string; description?: string; enum?: unknown[] }>;
  required?: string[];
}

/** What can be done to a node. */
export interface OpSpec {
  name: string;
  description?: string;
  params?: ParamsSchema;
  policy: Policy;
}

export type StateValue = string | number | boolean;

/** One entry of a container, as its preview and its `items` op give it (whether or not it is on screen). */
export interface ItemSummary {
  /** The entry's key (`<container key>[<id>]`), to fetch it or act on it — when the container has a key. */
  key?: string;
  id: string;
  index?: number;
  name: string;
  description?: string;
}

/** A page of a container's entries: the `items` op's answer. */
export interface ItemsPage {
  /** All the items (not only this page), when known. */
  count?: number;
  offset: number;
  items: ItemSummary[];
}

/**
 * One entry of a container, fetched (the `item` op's answer): a tree of its own, rooted at the entry. live: on screen now, its ids
 * can be acted on (also next round, while it stays); preview: built off screen, ids not live (act by key: that brings it in).
 */
export interface ItemTree {
  key?: string;
  id: string;
  index?: number;
  source: 'live' | 'preview';
  root: AffordNode;
}

export interface AffordNode {
  /** Stable while the control stays on screen; what calls refer to. */
  id: string;
  /** A name the app gives it that stays the same across pages and visits (e.g. "settings.ai.model"): calls may use it instead of the
   * id — also for a control on a page the agent only peeked at, after navigating there. */
  key?: string;
  role: Role;
  /** What the user sees it called (label, text, placeholder). */
  name: string;
  /** What it is for, when the app says (more than the name). */
  description?: string;
  /** A short state, never the content: { checked: true }, { length: 320, focused: true }, { disabled: true }... */
  state?: Record<string, StateValue>;
  /** What a text or a heading shows, to read without an op (when it isn't its name) — cut short (ending in …) when long: read
   * gives it all. A field's content isn't here: read it. */
  value?: string;
  ops: OpSpec[];
  children?: AffordNode[];
  /** A container: its entries on screen, in short (capped) — an entry's tree is fetched with its `item` op. */
  preview?: ItemSummary[];
}

/** An app-wide operation, not tied to a control (same shape as a WebMCP tool). */
export interface ToolSpec {
  name: string;
  description: string;
  inputSchema?: ParamsSchema;
  policy: Policy;
}

/** A place in the app the agent can go to. */
export interface RouteSpec {
  /** A pattern such as /settings/:tab or /mail/folder/:id. */
  path: string;
  description: string;
  /** What each :param can be (its values when there are only a few). */
  params?: Record<string, { description?: string; values?: string[] }>;
}

/** Where the user is, and where the agent can take them. */
export interface RouteState {
  /** The route now, e.g. /settings/ai. */
  current: string;
  /** The pattern it is (one of routes), and its params: { tab: "ai" }. */
  pattern?: string;
  params?: Record<string, string>;
  /** Whether navigate "back" goes somewhere. */
  canGoBack?: boolean;
  routes: RouteSpec[];
}

export interface AffordContext {
  protocol: typeof PROTOCOL_VERSION;
  route?: RouteState;
  root: AffordNode;
  tools: ToolSpec[];
}

/**
 * Another page's tree, peeked at without going there. Its ids are not live (they can't be acted on from here): navigate there, then
 * act by the nodes' keys (or look again for live ids).
 * - live: the page showing now; preview: the app built the page off screen just now (its state as it would open);
 * - seen: as it was the last time it showed (seenAt); declared: never seen, only what the route says it is (no tree).
 */
export interface PagePeek {
  route: string;
  pattern?: string;
  source: 'live' | 'preview' | 'seen' | 'declared';
  seenAt?: number;
  description?: string;
  root?: AffordNode;
}

/** One thing the agent asks for: an op on a node (by id, or key), an app-wide tool, going to a route (or "back"), or a peek at one. */
export type Call =
  | { node: string; op: string; args?: Record<string, unknown> }
  | { tool: string; args?: Record<string, unknown> }
  | { navigate: string }
  | { peek: string };

/** Why a call failed, for the agent's loop to act on (the error says it in words). */
export type ErrorCode =
  /** No such node (it went), route, tool or entry. */
  | 'not_found'
  /** The node has no such op. */
  | 'no_op'
  /** The op's arguments are missing or wrong. */
  | 'bad_args'
  /** Policy deny: the user does this themselves. */
  | 'denied'
  /** Policy confirm, and the app gave no way to ask: nothing was done. */
  | 'needs_confirm'
  /** The user was asked and said no. */
  | 'declined'
  /** The control is disabled. */
  | 'disabled'
  /** Something is over it (a dialog, another page) and it can't be worked from there. */
  | 'unreachable'
  /** The app did not answer in time. */
  | 'timeout'
  /** There is no app to work, or it could not answer. */
  | 'unavailable'
  /** Anything else that went wrong doing it. */
  | 'failed';

/** An error with its code (thrown by the kit, and by an app's own ops when it wants to say which). */
export class AffordError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'AffordError';
  }
}

export interface CallResult {
  call: Call;
  ok: boolean;
  /** What a read returned, or what a tool answered. */
  value?: unknown;
  error?: string;
  /** Why it failed. */
  code?: ErrorCode;
  /** Needs the user's yes first (policy confirm, and the app gave no way to ask): nothing was done. */
  needsConfirm?: boolean;
}

/**
 * What goes from the agent's side to the app (over whatever the app uses: a socket, HTTP, a message port): look at the screen, or
 * run calls. The app answers with answer() — the kit's own — and the agent's side reads it with AffordRemote.
 */
export type UiRequest = { look: true; picture?: boolean } | { calls: Call[] };

/** The app's answer: the screen (and the calls' results; a picture of the screen when asked and it can), or why it couldn't. */
export type UiAnswer = { context: AffordContext; results?: CallResult[]; picture?: ImageValue } | { error: string; code?: ErrorCode };

/** A picture (what op view answers, and a look with picture): PNG / JPEG as base64, or where it is when it couldn't be read. */
export interface ImageValue {
  type: 'image';
  mime: string;
  data?: string;
  url?: string;
  width?: number;
  height?: number;
}

/** Whether a value is a picture. */
export function isImage(v: unknown): v is ImageValue {
  return !!v && typeof v === 'object' && (v as ImageValue).type === 'image' && typeof (v as ImageValue).mime === 'string';
}

/** What execute gives back: the results, and the context as it is afterwards (the agent's next round). */
export interface ExecuteResult {
  results: CallResult[];
  context: AffordContext;
}

const textParam = (description: string): ParamsSchema => ({ type: 'object', properties: { text: { type: 'string', description } }, required: ['text'] });

/** What each kind of control can do, unless the app says otherwise. */
export const STANDARD_OPS: Record<Role, OpSpec[]> = {
  app: [{ name: 'read', description: 'All the text on screen', policy: 'allow' }],
  page: [{ name: 'read', description: 'All the text of this page', policy: 'allow' }],
  region: [{ name: 'read', description: 'All the text in it', policy: 'allow' }],
  dialog: [{ name: 'read', description: 'All the text in it', policy: 'allow' }],
  button: [{ name: 'press', policy: 'allow' }],
  link: [{ name: 'press', description: 'Follow the link', policy: 'allow' }],
  textbox: [
    { name: 'read', description: 'What is written in it', policy: 'allow' },
    { name: 'write', description: 'Replace what is written', params: textParam('The new text'), policy: 'allow' },
    { name: 'append', description: 'Add to the end', params: textParam('The text to add'), policy: 'allow' },
    { name: 'clear', policy: 'allow' },
  ],
  checkbox: [
    { name: 'toggle', policy: 'allow' },
    { name: 'set', params: { type: 'object', properties: { on: { type: 'boolean' } }, required: ['on'] }, policy: 'allow' },
  ],
  switch: [
    { name: 'toggle', policy: 'allow' },
    { name: 'set', params: { type: 'object', properties: { on: { type: 'boolean' } }, required: ['on'] }, policy: 'allow' },
  ],
  radio: [{ name: 'select', policy: 'allow' }],
  select: [
    { name: 'read', description: 'The choice and the options', policy: 'allow' },
    { name: 'choose', params: { type: 'object', properties: { option: { type: 'string', description: 'The option, by its text or value' } }, required: ['option'] }, policy: 'allow' },
  ],
  tab: [{ name: 'select', policy: 'allow' }],
  container: [
    { name: 'read', description: 'The text of the entries on screen', policy: 'allow' },
    {
      name: 'item',
      description:
        'Fetch one entry as a tree of its own (its controls, with ids and keys to act on): by id (or key), index, or the first whose name has query; brought into view first if it is not. preview: true builds it off screen instead, when the app can',
      params: {
        type: 'object',
        properties: {
          id: { type: 'string', description: "The entry's id or key" },
          index: { type: 'number' },
          query: { type: 'string' },
          preview: { type: 'boolean' },
        },
      },
      policy: 'allow',
    },
    {
      name: 'items',
      description: 'Page through all its entries (also those not on screen): their keys and names',
      params: {
        type: 'object',
        properties: {
          offset: { type: 'number', description: 'From (default 0)' },
          limit: { type: 'number', description: 'How many (default 20)' },
          query: { type: 'string', description: 'Only items whose name has this' },
        },
      },
      policy: 'allow',
    },
    {
      name: 'scroll_to',
      description: 'Bring an entry into view, by its index or its key / id',
      params: { type: 'object', properties: { index: { type: 'number' }, item: { type: 'string', description: "The entry's key or id" } } },
      policy: 'allow',
    },
    { name: 'scroll', description: 'Scroll it by pages (negative: back up)', params: { type: 'object', properties: { by: { type: 'number', description: 'Pages, e.g. 1 or -1' } } }, policy: 'allow' },
  ],
  list: [{ name: 'read', description: 'The text of its items', policy: 'allow' }],
  listitem: [
    { name: 'read', policy: 'allow' },
    { name: 'press', description: 'Open it', policy: 'allow' },
  ],
  heading: [],
  text: [{ name: 'read', policy: 'allow' }],
  image: [{ name: 'view', description: 'See it: the picture itself', policy: 'allow' }],
  other: [{ name: 'read', policy: 'allow' }],
};

/** An entry's key: the container's key and the entry's id (`mail.list` + `42` → `mail.list[42]`). */
export const itemKey = (containerKey: string, id: string): string => `${containerKey}[${id}]`;

/** The innermost entry a key names: `mail.list[42].star` → { list: 'mail.list' (the container's key), id: '42', rest: '.star' }; null when it names none. */
export function parseItemKey(key: string): { list: string; id: string; rest: string } | null {
  const m = /^(.+)\[([^[\]]+)\](.*)$/.exec(key);
  return m ? { list: m[1]!, id: m[2]!, rest: m[3]! } : null;
}

/** A route's params if it is this pattern (/settings/:tab against /settings/ai → { tab: "ai" }), else null. */
export function matchRoute(pattern: string, route: string): Record<string, string> | null {
  const split = (p: string) => p.split(/[?#]/)[0]!.split('/').filter(Boolean);
  const want = split(pattern);
  const got = split(route);
  const tail = want.at(-1) === '*';
  if (tail ? got.length < want.length - 1 : got.length !== want.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < want.length; i++) {
    const w = want[i]!;
    if (w === '*') break;
    if (w.startsWith(':')) params[w.slice(1)] = decodeURIComponent(got[i]!);
    else if (w !== got[i]) return null;
  }
  return params;
}

/** The pattern a route is (the most specific: fewest params), and its params. */
export function findRoute(routes: RouteSpec[], route: string): { spec: RouteSpec; params: Record<string, string> } | null {
  let best: { spec: RouteSpec; params: Record<string, string> } | null = null;
  for (const spec of routes) {
    const params = matchRoute(spec.path, route);
    if (params && (!best || Object.keys(params).length < Object.keys(best.params).length)) best = { spec, params };
  }
  return best;
}

/** A node's ops: the standard ones for its role with the app's policies applied, plus its own. */
export function opsFor(role: Role, policy?: Policy | Record<string, Policy>, own: OpSpec[] = []): OpSpec[] {
  const pick = (op: string, fallback: Policy): Policy => (typeof policy === 'string' ? policy : (policy?.[op] ?? fallback));
  const standard = STANDARD_OPS[role].map((op) => ({ ...op, policy: pick(op.name, op.policy) }));
  return [...standard.filter((op) => !own.some((o) => o.name === op.name)), ...own.map((op) => ({ ...op, policy: pick(op.name, op.policy) }))];
}
