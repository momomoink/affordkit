/**
 * AffordKit for the DOM: the page's controls as an AffordKit tree, and the agent's calls run on them.
 *
 * The tree comes from the page itself, by subtraction: elements that mean something — buttons, links, fields, choices, tabs,
 * dialogs, lists, headings, and whatever the app registers — become nodes; everything else (layout, decoration) is passed through.
 * Nothing needs registering to be seen; registering (or data-afford attributes) gives a node a better name, a description, a policy
 * or operations of its own.
 *
 *   const kit = new AffordKit();
 *   kit.register(sendButton, { name: 'Send', policy: 'deny' });      // or <button data-afford="Send" data-afford-policy="deny">
 *   kit.setRoutes({ current: () => location.pathname, routes, navigate: (r) => router.push(r) });
 *   const ctx = kit.context();                                       // → the agent
 *   const { results, context } = await kit.execute(calls);           // the agent's answer → its next round
 *
 * Pages: the agent can go to a route (or back), and peek at another page's tree first — built off screen by the app (preview), or
 * as it was the last time it showed (the kit keeps each page's last tree: snapshots() / loadSnapshots() to keep them across runs).
 *
 * Containers: many of the same thing (a mail list, a grid, a thread's messages) are one node — how many, which show, a short
 * preview — and the agent fetches the entry it wants as a tree of its own (op item), then acts on it. A short <ul>/<ol> is just a
 * list of its <li>s; a long one (more than 20) is a container by itself. Mark one with data-afford-container (data-afford-item="id"
 * on its entries), or register it — a virtualized one says more, so any entry can be reached, also one not built yet:
 *
 *   kit.registerContainer(listEl, {
 *     key: 'mail.list', name: 'Inbox', kind: 'list',
 *     itemId: (el) => el.dataset.id,                      // or <div data-afford-item="42"> on each row
 *     count: () => mails.length,
 *     items: ({ offset, limit, query }) => mails.filter(...).slice(offset, offset + limit).map((m) => ({ id: m.id, name: m.subject })),
 *     scrollTo: ({ id, index }) => virtualizer.scrollToIndex(index ?? mails.findIndex((m) => m.id === id)),
 *   });
 *   // the agent: { node: 'mail.list', op: 'item', args: { id: '42' } } → the row as a tree (mail.list[42], mail.list[42].reply ...),
 *   // then { node: 'mail.list[42].reply', op: 'press' } — or that straight away: the row is fetched (scrolled to) first
 *
 * Handoffs: what an agent left for a user who was away (see Handoff), run when they come back — they tapped its notification and
 * the app fetched it by id from its own server: `await kit.runHandoff(handoff)` goes to its route and runs its calls there.
 *
 * The user's own hands: while the agent works the screen, `kit.watchUser(true)` notes what the user does themselves (press, type,
 * toggle, pick, go to a page) — never the kit's own calls — and the next answer carries it (userActions), so the agent sees why the
 * screen moved under it. `kit.watchUser(false)` when the agent is done.
 */

import { AffordError, PROTOCOL_VERSION, findRoute, handoffProblem, itemKey, opsFor, parseHandoff, parseItemKey, type ErrorCode, type Handoff, type ItemSummary, type ItemsPage, type ItemTree, type PagePeek, type RouteState, type AffordContext, type AffordNode, type Call, type CallResult, type ExecuteResult, type OpSpec, type ParamsSchema, type Policy, type Role, type RouteSpec, type StateValue, type ToolSpec, type UiAnswer, type UiRequest, type ImageValue, type UserAction } from './protocol.js';
import { AffordRemote, type RemoteOptions } from './remote.js';

/** An operation the app adds to a control. */
export interface CustomOp {
  name: string;
  description?: string;
  params?: ParamsSchema;
  policy?: Policy;
  run: (args: Record<string, unknown>, el: Element) => unknown;
}

export interface RegisterOptions {
  name?: string;
  /** Stays the same across pages and visits (or data-afford-key): calls can use it, also after navigating to a peeked page. */
  key?: string;
  description?: string;
  role?: Role;
  /** For all of the node's ops, or per op ({ press: 'deny' }). */
  policy?: Policy | Record<string, Policy>;
  ops?: CustomOp[];
  /** Leave it (and everything in it) out of the tree. */
  skip?: boolean;
}

/** Where a container scrolls to: an entry by its id, or by its index. */
export interface ScrollTarget {
  id?: string;
  index?: number;
}

/** An entry as a container's items callback gives it (its key is made from the container's). */
export type ItemInfo = Omit<ItemSummary, 'key'>;

/**
 * A container (see registerContainer). All optional: without them its entries are what is in the DOM. Give count, items and
 * scrollTo for one that builds only the entries on screen (virtualized), so the agent can page through and reach all of them.
 */
export interface ContainerOptions extends Omit<RegisterOptions, 'role'> {
  /** What its entries are, in a word (list, grid, thread, tabs...): said with it. */
  kind?: string;
  /** An element's entry id if it is one of its entries (else null). Default: data-afford-item, else an <li> / role=listitem. */
  itemId?: (el: Element) => string | null | undefined;
  /** An entry element's index among all (default: data-afford-index, else its place among those built). */
  indexOf?: (el: Element) => number | undefined;
  /** How many entries there are in all. */
  count?: () => number;
  /** A page of all the entries, built or not (for the items op): an array, or { count, items }. */
  items?: (q: { offset: number; limit: number; query?: string }) => ItemInfo[] | { count?: number; items: ItemInfo[] } | Promise<ItemInfo[] | { count?: number; items: ItemInfo[] }>;
  /** Bring an entry into view (built, for a virtualized one). Default: scrollIntoView on it, when it is built. */
  scrollTo?: (target: ScrollTarget) => unknown;
  /** Build an entry off screen (op item with preview, or one not built with no scrollTo): an element holding it, and how to take it down. */
  build?: (target: ScrollTarget) => Promise<{ root: Element; dispose?: () => void } | null> | { root: Element; dispose?: () => void } | null;
  /** Scroll by pages (negative: up). Default: its scrolling box by its height. */
  scroll?: (pages: number) => unknown;
  /** Resolves once a scroll has shown its entries (default: a frame or two). */
  settle?: () => Promise<void>;
  /** Most entries in its preview (default 10). */
  previewItems?: number;
}

/** @deprecated The same as ContainerOptions (a list is a container of kind list). */
export type ListOptions = ContainerOptions;

/** A plain <ul> / <ol> with more items than this is a container. */
const AUTO_CONTAINER = 20;

export interface Tool extends Omit<ToolSpec, 'policy'> {
  policy?: Policy;
  execute: (args: Record<string, unknown>) => unknown;
}

export interface Routes {
  current: () => string;
  routes: RouteSpec[];
  navigate: (route: string) => unknown;
  /** Back where the user was (navigate "back"); canGoBack says whether there is somewhere. */
  back?: () => unknown;
  canGoBack?: () => boolean;
  /** Resolves once a page navigated to has shown (default: the next frame or two). */
  settle?: () => Promise<void>;
  /** Build a page off screen for a peek: an element holding it (any size, attached or not), and how to take it down. */
  preview?: (route: string) => Promise<{ root: Element; dispose?: () => void } | null> | { root: Element; dispose?: () => void } | null;
}

export interface AffordKitOptions {
  /** The part of the page the agent sees (default: the whole document). */
  root?: Element;
  /** Also left out (besides data-afford-skip): e.g. the agent's own chat panel. */
  skip?: string;
  /** Asked before an op or tool with policy confirm runs; without it those come back needsConfirm. */
  confirm?: (what: { call: Call; node?: AffordNode; tool?: ToolSpec }) => Promise<boolean> | boolean;
  /** Whether an element is on screen (default: laid out and not hidden). */
  isVisible?: (el: Element) => boolean;
  /** Longest text a read returns. */
  maxRead?: number;
  /** Resolves once what the agent's calls changed has shown (default: a frame or two) — before it is given the screen after them. */
  settle?: () => Promise<void>;
  /**
   * Called before an op runs on an element (allowed by its policy): e.g. to show the user where the agent is about to act, and wait a
   * moment so they see it happen. The op runs when it resolves. Not for reads, nor a container fetching or scrolling its entries.
   */
  onAct?: (event: ActEvent) => Promise<void> | void;
  /** Called with each thing the user does themselves while watched (watchUser), as it is noted (a write again as their typing goes on). */
  onUserAction?: (action: UserAction) => void;
}

/** An op about to run on an element (for onAct): what, on which node, and the element. */
export interface ActEvent {
  node: AffordNode;
  op: string;
  args: Record<string, unknown>;
  el: Element;
}

/** How a handoff is run (kit.runHandoff). */
export interface HandoffOptions {
  /** Asked before a call with policy confirm (default: the kit's confirm; without either, the handoff stops there with needs_confirm). */
  confirm?: AffordKitOptions['confirm'];
  /** The time now, in ms (for its expiry; default Date.now()). */
  now?: number;
}

/** What came of running a handoff: whether it all ran, how many of its calls did, and where and why it stopped. */
export interface HandoffResult {
  ok: boolean;
  /** How many of its calls ran (its route not counted). */
  ran: number;
  /** The call it stopped at (its index), or -1 before any: invalid, expired, or its route could not be gone to. */
  stoppedAt?: number;
  code?: ErrorCode;
  error?: string;
  /** Each step's result: the route's first, when it has one. */
  results: CallResult[];
}

/** Elements whose role the tag (or ARIA) gives, and what they are. */
const ARIA_ROLES: Partial<Record<string, Role>> = {
  button: 'button',
  link: 'link',
  textbox: 'textbox',
  searchbox: 'textbox',
  checkbox: 'checkbox',
  switch: 'switch',
  radio: 'radio',
  combobox: 'select',
  listbox: 'select',
  tab: 'tab',
  dialog: 'dialog',
  alertdialog: 'dialog',
  list: 'list',
  listitem: 'listitem',
  option: 'listitem',
  heading: 'heading',
  region: 'region',
  main: 'page',
  navigation: 'region',
  menuitem: 'button',
  img: 'image',
};

function isSecret(el: Element): boolean {
  if (!(el instanceof HTMLInputElement)) return false;
  const hint = `${el.name} ${el.id} ${el.autocomplete} ${el.getAttribute('aria-label') ?? ''} ${el.placeholder}`.toLowerCase();
  return el.type === 'password' || el.hasAttribute('data-afford-secret') || /password|passwd|secret|token|api.?key|one-time-code/.test(hint);
}

function roleOf(el: Element): Role | null {
  const explicit = el.getAttribute('data-afford-role') as Role | null;
  if (explicit) return explicit;
  const aria = el.getAttribute('role');
  if (aria && ARIA_ROLES[aria]) return ARIA_ROLES[aria]!;
  switch (el.tagName) {
    case 'BUTTON':
    case 'SUMMARY':
      return 'button';
    case 'A':
      return el.hasAttribute('href') ? 'link' : null;
    case 'TEXTAREA':
      return 'textbox';
    case 'SELECT':
      return 'select';
    case 'DIALOG':
      return 'dialog';
    case 'MAIN':
      return 'page';
    case 'NAV':
    case 'ASIDE':
      return 'region';
    case 'SECTION':
    case 'FORM':
      return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
    case 'UL':
    case 'OL':
      return 'list';
    case 'LI':
      return 'listitem';
    case 'H1':
    case 'H2':
    case 'H3':
      return 'heading';
    case 'IMG':
      return el.getAttribute('alt') ? 'image' : null;
    case 'INPUT': {
      const type = (el as HTMLInputElement).type;
      if (type === 'hidden') return null;
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      if (type === 'button' || type === 'submit' || type === 'reset') return 'button';
      if (type === 'file' || type === 'image' || type === 'color' || type === 'range') return 'other';
      return 'textbox';
    }
  }
  if ((el as HTMLElement).isContentEditable && !el.parentElement?.closest('[contenteditable]')) return 'textbox';
  return null;
}

const squash = (text: string) => text.replace(/\s+/g, ' ').trim();

function nameOf(el: Element, role: Role): string {
  const own = el.getAttribute('data-afford') || el.getAttribute('aria-label');
  if (own) return own;
  const labelledBy = el.getAttribute('aria-labelledby');
  if (labelledBy) {
    const text = labelledBy.split(/\s+/).map((id) => el.ownerDocument.getElementById(id)?.textContent ?? '').join(' ');
    if (squash(text)) return squash(text);
  }
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
    const forLabel = el.id ? el.ownerDocument.querySelector(`label[for="${CSS.escape(el.id)}"]`) : null;
    const label = forLabel?.textContent || el.closest('label')?.textContent;
    if (label && squash(label)) return squash(label).slice(0, 80);
    if ('placeholder' in el && el.placeholder) return el.placeholder;
    if (el instanceof HTMLInputElement && (el.type === 'button' || el.type === 'submit') && el.value) return el.value;
  }
  if (role === 'image') return el.getAttribute('alt') ?? '';
  if (role === 'dialog' || role === 'region' || role === 'page' || role === 'list') {
    const heading = el.querySelector('h1, h2, h3, [role="heading"]');
    return squash(heading?.textContent ?? el.getAttribute('title') ?? '').slice(0, 80);
  }
  return squash((el as HTMLElement).innerText ?? el.textContent ?? el.getAttribute('title') ?? '').slice(0, 80);
}

function stateOf(el: Element, role: Role): Record<string, StateValue> | undefined {
  const s: Record<string, StateValue> = {};
  const aria = (k: string) => el.getAttribute(`aria-${k}`);
  if ((el as HTMLButtonElement).disabled || aria('disabled') === 'true') s.disabled = true;
  if (el === el.ownerDocument.activeElement) s.focused = true;
  if (role === 'textbox') {
    if (isSecret(el)) s.secret = true;
    const value = (el as HTMLInputElement).value ?? (el as HTMLElement).innerText ?? '';
    s.length = value.length;
  }
  if (role === 'checkbox' || role === 'switch' || role === 'radio') s.checked = el instanceof HTMLInputElement ? el.checked : aria('checked') === 'true';
  if (role === 'tab' || role === 'listitem') {
    if (aria('selected') === 'true' || aria('current') === 'page' || aria('current') === 'true') s.selected = true;
  }
  if (aria('pressed')) s.pressed = aria('pressed') === 'true';
  if (aria('expanded')) s.expanded = aria('expanded') === 'true';
  if (role === 'select' && el instanceof HTMLSelectElement) s.value = el.options[el.selectedIndex]?.textContent?.trim() ?? el.value;
  return Object.keys(s).length ? s : undefined;
}

/** A frame or two for what changed to show (not forever: no frames come in a hidden tab). */
const nextFrames = () =>
  new Promise<void>((resolve) => {
    const done = setTimeout(resolve, 120);
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => requestAnimationFrame(() => (clearTimeout(done), resolve())));
  });

const strip = (n: AffordNode, prefix: string): AffordNode => ({ ...n, id: prefix + n.id, ...(n.children ? { children: n.children.map((c) => strip(c, prefix)) } : {}) });

function defaultVisible(el: Element): boolean {
  const h = el as HTMLElement;
  if (h.hidden || el.getAttribute('aria-hidden') === 'true') return false;
  // display: contents has no box of its own (checkVisibility says no) but its children show: a wrapper a framework puts around a
  // dialog or a transition, which left whatever is in it out of the tree
  if (getComputedStyle(el).display === 'contents') return true;
  if (typeof h.checkVisibility === 'function') return h.checkVisibility({ checkOpacity: false, checkVisibilityCSS: true });
  const r = h.getBoundingClientRect();
  return r.width > 0 || r.height > 0;
}

/** Set a field's value so frameworks (React included) see it as typed. */
function setValue(el: Element, value: string): void {
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value')?.set?.call(el, value);
  } else (el as HTMLElement).innerText = value;
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
}

export class AffordKit {
  private readonly registered = new WeakMap<Element, RegisterOptions>();
  private readonly containers = new WeakMap<Element, ContainerOptions>();
  /** The nodes of entries fetched (op item, or an entry's key acted on): their ids stay live while the entry is on the page. */
  private fetched = new Map<string, AffordNode>();
  private readonly ids = new WeakMap<Element, string>();
  private readonly byId = new Map<string, WeakRef<Element>>();
  private readonly tools = new Map<string, Tool>();
  private routes: Routes | null = null;
  private next = 1;
  private lastTree: Map<string, AffordNode> = new Map();
  /** Each page's tree the last time it showed (by route), for peeks. */
  private seen = new Map<string, { root: AffordNode; at: number }>();
  /** What the user did themselves since the last answer (watchUser), oldest first. */
  private userActions: UserAction[] = [];
  /** Stops watching the user; set while watching. */
  private unwatch: (() => void) | null = null;
  /** The kit's own calls running (execute, a handoff), and until when what they set off may still fire events on the page. */
  private acting = 0;
  private quietUntil = 0;
  /** The route as last seen while watching: a change the kit didn't make is the user's. */
  private userRoute: string | undefined;
  /** When the user last went back (popstate): the route change that follows is a back. */
  private wentBackAt = 0;

  constructor(private readonly options: AffordKitOptions = {}) {}

  /** Give an element a name, description, policy or ops of its own (it is in the tree anyway if it means something). Returns undo. */
  register(el: Element, opts: RegisterOptions = {}): () => void {
    this.registered.set(el, opts);
    return () => this.registered.delete(el);
  }

  /**
   * Make an element a container: one node in the tree, its entries fetched one at a time as trees of their own (op item, or by key:
   * `<key>[<entry id>]`, also entries not built yet). Returns undo.
   */
  registerContainer(el: Element, opts: ContainerOptions = {}): () => void {
    this.containers.set(el, opts);
    const undo = this.register(el, { ...opts, role: 'container' });
    return () => (this.containers.delete(el), undo());
  }

  /** @deprecated registerContainer, of kind list. */
  registerList(el: Element, opts: ContainerOptions = {}): () => void {
    return this.registerContainer(el, { kind: 'list', ...opts });
  }

  /** The container an element is, if it is one: registered, data-afford-container (or -list), or a long <ul> / <ol>. */
  private containerOf(el: Element): ContainerOptions | null {
    const reg = this.containers.get(el);
    if (reg) return reg;
    const kind = el.getAttribute('data-afford-container') ?? (el.hasAttribute('data-afford-list') ? 'list' : null);
    if (kind !== null) return { kind: kind || 'list' };
    const role = this.registered.get(el)?.role ?? el.getAttribute('data-afford-role');
    if (role === 'container') return {};
    if (role || !(el.tagName === 'UL' || el.tagName === 'OL')) return null;
    let n = 0;
    for (const c of el.children) if (c.tagName === 'LI' && ++n > AUTO_CONTAINER) return { kind: 'list' };
    return null;
  }

  /** An element's entry id if it is an entry of this container (else null; '' for one with no id of its own: its index is). */
  private itemIdOf(el: Element, box: ContainerOptions): string | null {
    if (box.itemId) return box.itemId(el) ?? null;
    const attr = el.getAttribute('data-afford-item');
    if (attr !== null) return attr;
    return roleOf(el) === 'listitem' ? '' : null;
  }

  /** The container's entries in the DOM, in order (an entry's own containers are its own). */
  private itemsOf(boxEl: Element, box: ContainerOptions): { el: Element; id: string; index: number }[] {
    const out: { el: Element; id: string; index: number }[] = [];
    const walk = (el: Element) => {
      for (const child of el.children) {
        const id = this.itemIdOf(child, box);
        if (id === null) {
          if (!this.containers.has(child)) walk(child);
          continue;
        }
        out.push({ el: child, id, index: this.indexOf(child, box, out.length) });
        if (!id) out.at(-1)!.id = String(out.at(-1)!.index);
      }
    };
    walk(boxEl);
    return out;
  }

  private indexOf(el: Element, box: ContainerOptions, fallback: number): number {
    return box.indexOf?.(el) ?? (el.hasAttribute('data-afford-index') ? Number(el.getAttribute('data-afford-index')) : fallback);
  }

  /** An entry built now, by id or index. */
  private builtItem(boxEl: Element, box: ContainerOptions, target: ScrollTarget) {
    return this.itemsOf(boxEl, box).find((i) => (target.id !== undefined ? i.id === target.id : i.index === target.index));
  }

  /** Bring an entry into view (by id or index), and wait for it to show. */
  private async reveal(boxEl: Element, box: ContainerOptions, target: ScrollTarget): Promise<void> {
    if (box.scrollTo) await box.scrollTo(target);
    else {
      // Not rendered (a virtualized list): scrolled through until it is
      if (!this.builtItem(boxEl, box, target)) await this.scrollScan(boxEl, box, (i) => (target.id !== undefined ? i.id === target.id : i.index === target.index), 1, true);
      const item = this.builtItem(boxEl, box, target);
      if (!item) throw new AffordError('not_found', `No entry ${target.id ?? '#' + target.index} here`);
      (item.el as HTMLElement).scrollIntoView?.({ block: 'nearest' });
    }
    await (box.settle?.() ?? nextFrames());
  }

  /**
   * One entry as a tree of its own: built (scrolled to first when it isn't, and the container can), or off screen (preview, or
   * when it can only be built). Its nodes' ids are live until it leaves the page.
   */
  private async fetchItem(boxEl: Element, box: ContainerOptions, boxKey: string | undefined, target: ScrollTarget, preview = false): Promise<ItemTree> {
    let item = preview ? undefined : this.builtItem(boxEl, box, target);
    if (!item && !preview) {
      try {
        await this.reveal(boxEl, box, target);
      } catch (error) {
        if (!box.build) throw error;
      }
      item = this.builtItem(boxEl, box, target);
    }
    if (!item) {
      const built = box.build ? await box.build(target) : null;
      if (!built) throw new AffordError('not_found', `No entry ${target.id ?? '#' + target.index} here${preview ? ' to preview' : ''}`);
      try {
        // (built off screen: its first entry, or itself)
        const el = this.itemsOf(built.root, box)[0]?.el ?? built.root;
        const id = target.id ?? this.itemIdOf(el, box) ?? String(target.index ?? '');
        const key = boxKey === undefined ? undefined : itemKey(boxKey, id || String(target.index));
        const nodes = new Map<string, AffordNode>();
        const root = this.itemNode(el, key, () => true, false, nodes);
        return { ...(key ? { key } : {}), id, ...(target.index !== undefined ? { index: target.index } : {}), source: 'preview', root: strip(root, 'peek:') };
      } finally {
        built.dispose?.();
      }
    }
    const key = boxKey === undefined ? undefined : itemKey(boxKey, item.id);
    const root = this.itemNode(item.el, key, this.options.isVisible ?? defaultVisible, true, this.fetched);
    return { ...(key ? { key } : {}), id: item.id, index: item.index, source: 'live', root };
  }

  /** An app-wide operation (shaped like a WebMCP tool). Returns undo. */
  registerTool(tool: Tool): () => void {
    this.tools.set(tool.name, tool);
    return () => this.tools.delete(tool.name);
  }

  /** The app's routes, so the agent knows where the user is and can take them elsewhere. */
  setRoutes(routes: Routes | null): void {
    this.routes = routes;
  }

  private idOf(el: Element): string {
    let id = this.ids.get(el);
    if (!id) {
      id = `n${this.next++}`;
      this.ids.set(el, id);
    }
    this.byId.set(id, new WeakRef(el));
    return id;
  }

  private optionsOf(el: Element): RegisterOptions | undefined {
    const reg = this.registered.get(el);
    const attr = el.getAttribute('data-afford-policy');
    const key = reg?.key ?? el.getAttribute('data-afford-key');
    if (!attr && !el.hasAttribute('data-afford-describe') && !key) return reg;
    // data-afford-policy="deny" or "press:deny, write:confirm"
    let policy: RegisterOptions['policy'] = reg?.policy;
    if (attr) policy = attr.includes(':') ? Object.fromEntries(attr.split(',').map((p) => p.split(':').map((x) => x.trim()) as [string, Policy])) : (attr.trim() as Policy);
    const description = reg?.description ?? el.getAttribute('data-afford-describe');
    return { ...reg, ...(policy ? { policy } : {}), ...(description ? { description } : {}), ...(key ? { key } : {}) };
  }

  /** Where the user is (with the pattern it is and its params), and where the agent can go. */
  private routeState(): RouteState | undefined {
    const r = this.routes;
    if (!r) return undefined;
    const current = r.current();
    const hit = findRoute(r.routes, current);
    return { current, ...(hit ? { pattern: hit.spec.path, params: hit.params } : {}), ...(r.canGoBack ? { canGoBack: r.canGoBack() } : {}), routes: r.routes };
  }

  /** The tree of what is on screen now. */
  context(): AffordContext {
    const { app, nodes } = this.tree(this.options.root ?? document.documentElement, this.options.isVisible ?? defaultVisible, true);
    this.lastTree = nodes;
    const route = this.routeState();
    if (route) this.seen.set(route.current, { root: app, at: Date.now() });
    return {
      protocol: PROTOCOL_VERSION,
      ...(route ? { route } : {}),
      root: app,
      tools: [...this.tools.values()].map(({ name, description, inputSchema, policy }) => ({ name, description, ...(inputSchema ? { inputSchema } : {}), policy: policy ?? 'allow' })),
    };
  }

  /** Another page's tree without going there (see PagePeek). */
  async peek(route: string): Promise<PagePeek> {
    const r = this.routes;
    if (!r) throw new AffordError('not_found', 'This app has no routes');
    const hit = findRoute(r.routes, route);
    const base = { route, ...(hit ? { pattern: hit.spec.path, description: hit.spec.description } : {}) };
    if (route === r.current()) return { ...base, source: 'live', root: this.context().root };
    const built = await r.preview?.(route);
    if (built) {
      try {
        // Built off screen: everything in it counts as showing; ids that can't be acted on from here
        return { ...base, source: 'preview', root: strip(this.tree(built.root, () => true, false).app, 'peek:') };
      } finally {
        built.dispose?.();
      }
    }
    // As it last showed: this very route, else another of the same pattern (/mail/folder/2 for /mail/folder/7)
    const seen = this.seen.get(route) ?? (hit ? [...this.seen.entries()].find(([k]) => findRoute([hit.spec], k))?.[1] : undefined);
    if (seen) return { ...base, source: 'seen', seenAt: seen.at, root: strip(seen.root, 'peek:') };
    return { ...base, source: 'declared' };
  }

  /** The pages' last trees, to keep (e.g. in storage) and give back with loadSnapshots next time: peeks then know pages not seen yet this run. */
  snapshots(): Record<string, { root: AffordNode; at: number }> {
    return Object.fromEntries(this.seen);
  }

  loadSnapshots(snapshots: Record<string, { root: AffordNode; at: number }>): void {
    for (const [route, snap] of Object.entries(snapshots)) if (!this.seen.has(route)) this.seen.set(route, snap);
  }

  private tree(root: Element, visible: (el: Element) => boolean, live: boolean): { app: AffordNode; nodes: Map<string, AffordNode> } {
    const nodes = new Map<string, AffordNode>();
    const walk = this.walker(visible, live, nodes);
    const top: AffordNode[] = [];
    for (const child of root.children) walk(child, top);
    const app: AffordNode = { id: 'app', role: 'app', name: document.title, ops: opsFor('app'), children: top };
    nodes.set('app', app);
    return { app, nodes };
  }

  /** An entry of a container as a tree of its own, rooted at it (its controls' keys under its key). */
  private itemNode(el: Element, key: string | undefined, visible: (el: Element) => boolean, live: boolean, nodes: Map<string, AffordNode>): AffordNode {
    const out: AffordNode[] = [];
    this.walker(visible, live, nodes)(el, out, { entry: { ...(key ? { key } : {}) } });
    if (!out[0]) throw new Error(`Entry ${key ?? ''} is not showing`);
    return out[0];
  }

  /** Walks the page into nodes: what means something becomes one, the rest is passed through; a container's entries are not gone into. */
  private walker(visible: (el: Element) => boolean, live: boolean, nodes: Map<string, AffordNode>) {
    const walk = (el: Element, into: AffordNode[], scope: Scope = {}): void => {
      if (el.hasAttribute('data-afford-skip') || this.optionsOf(el)?.skip) return;
      if (this.options.skip && el.matches(this.options.skip)) return;
      if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE' || el.tagName === 'TEMPLATE') return;
      if (!visible(el)) return;
      const opts = this.optionsOf(el);
      // One of a container's entries: only noted (which show, a short preview) — its tree is fetched on its own
      const box = scope.box;
      const entryId = box && !scope.entry ? this.itemIdOf(el, box.opts) : null;
      if (box && entryId !== null) {
        const index = this.indexOf(el, box.opts, box.seen++);
        const r = box.viewport ? el.getBoundingClientRect() : null;
        const v = box.viewport;
        if (r && v && v.height && !(r.bottom > v.top && r.top < v.bottom)) return;
        box.shown.push(index);
        if (box.preview.length < (box.opts.previewItems ?? 10)) {
          const id = entryId || String(index);
          box.preview.push({ ...(box.key !== undefined ? { key: itemKey(box.key, id) } : {}), id, index, name: opts?.name ?? nameOf(el, 'listitem'), ...(opts?.description ? { description: opts.description } : {}) });
        }
        return;
      }
      // The root of an entry's own tree: its key from the container's, and its controls' under it
      const entry = scope.entry;
      const key = entry ? entry.key : opts?.key && scope.prefix ? `${scope.prefix}.${opts.key}` : opts?.key;
      let inner: Scope = entry ? (entry.key ? { prefix: entry.key } : {}) : { ...(scope.prefix ? { prefix: scope.prefix } : {}), ...(box ? { box } : {}) };
      const boxOpts = entry ? null : this.containerOf(el);
      const role: Role | null = entry ? (opts?.role ?? 'listitem') : boxOpts ? 'container' : (opts?.role ?? roleOf(el) ?? (opts || el.hasAttribute('data-afford') ? 'region' : null));
      if (!role) {
        for (const child of el.children) walk(child, into, inner);
        return;
      }
      const secret = isSecret(el);
      const own = (opts?.ops ?? []).map(({ name, description, params, policy }): OpSpec => ({ name, ...(description ? { description } : {}), ...(params ? { params } : {}), policy: policy ?? 'allow' }));
      let ops = opsFor(role, opts?.policy, own);
      // Passwords and keys: the agent sees the field exists and whether it's filled, never reads or types it
      if (secret) ops = ops.map((op) => ({ ...op, policy: 'deny' }));
      const node: AffordNode = { id: live ? this.idOf(el) : 'p' + (nodes.size + 1), role, name: opts?.name ?? nameOf(el, role === 'container' ? 'list' : role), ops };
      if (key) node.key = key;
      if (opts?.description) node.description = opts.description;
      let state = stateOf(el, role);
      nodes.set(node.id, node);
      // A container: its entries are looked for in it (what else is in it — a header, a "more" button — is its children)
      if (boxOpts) inner = { ...inner, box: { opts: boxOpts, ...(key ? { key } : {}), seen: 0, shown: [], preview: [], viewport: scrollerOf(el)?.getBoundingClientRect() ?? null } };
      // Inside a button or a field there is nothing more to act on
      if (role !== 'button' && role !== 'link' && role !== 'textbox' && role !== 'select' && role !== 'heading' && role !== 'image') {
        const children: AffordNode[] = [];
        for (const child of el.children) walk(child, children, inner);
        if (children.length) node.children = children;
      }
      // What a text, a heading or a part with no controls in it shows, to read without an op (a field's content isn't: read it)
      if (role === 'text' || role === 'heading' || (!node.children && (role === 'region' || role === 'other' || role === 'listitem' || role === 'dialog'))) {
        const words = clip(((el as HTMLElement).innerText ?? el.textContent ?? '').trim());
        if (words && words !== node.name) node.value = words;
      }
      if (boxOpts && inner.box) {
        const { seen, shown, preview } = inner.box;
        state = { ...state, ...(boxOpts.kind ? { kind: boxOpts.kind } : {}), count: boxOpts.count?.() ?? seen };
        if (shown.length) Object.assign(state, { first: Math.min(...shown), last: Math.max(...shown) });
        if (preview.length) node.preview = preview;
      }
      if (state) node.state = state;
      into.push(node);
    };
    return walk;
  }

  /** A node of the tree by its id or key (looking again if it isn't in the last tree: the page may have changed since). */
  private async resolve(ref: string, depth = 0): Promise<{ el: Element; node: AffordNode } | null> {
    const live = (node: AffordNode | undefined) => {
      const el = node && this.byId.get(node.id)?.deref();
      return node && el?.isConnected ? { el, node } : null;
    };
    const find = () => {
      for (const nodes of [this.lastTree, this.fetched]) {
        const hit = live(nodes.get(ref)) ?? live([...nodes.values()].find((n) => n.key === ref));
        if (hit) return hit;
      }
      return null;
    };
    const hit = find();
    if (hit) return hit;
    this.context();
    const again = find();
    if (again) return again;
    // In an entry of a container (or the entry itself): fetch the entry, scrolled to (the container found the same way: it may be
    // in an entry too)
    const item = parseItemKey(ref);
    if (!item || depth > 8) return null;
    const box = await this.resolve(item.list, depth + 1);
    const opts = box && this.containerOf(box.el);
    if (!box || !opts) return null;
    await this.fetchItem(box.el, opts, box.node.key, { id: item.id });
    return find();
  }

  /**
   * An agent's request (UiRequest, from AffordRemote over the app's own transport) answered: the screen, or the calls run and the
   * screen after.
   */
  async answer(request: UiRequest): Promise<UiAnswer> {
    try {
      // (a page the user went to themselves: noted before the calls go anywhere)
      this.noteRoute();
      if ('calls' in request) {
        const done = await this.execute(request.calls);
        // What the user did meanwhile, up to now (nothing runs between the context taken and this: it is the tree after it all)
        const userActions = this.drainUser();
        return { ...done, ...(userActions.length ? { userActions } : {}) };
      }
      const userActions = this.drainUser();
      return { context: this.context(), ...(userActions.length ? { userActions } : {}) };
    } catch (error) {
      return { error: (error as Error).message, code: error instanceof AffordError ? error.code : 'failed' };
    }
  }

  /**
   * Note what the user does themselves (on: while the agent works their screen): press, write, toggle and select on the tree's
   * nodes, and navigate / back — for the next answer (userActions). Never the kit's own calls: while it runs them, and for a moment
   * after (an op can set off events once it has returned), only events the browser says a person made count (isTrusted). Not in
   * what the tree leaves out (skip: e.g. the agent's own chat). Off forgets what was noted.
   */
  watchUser(on: boolean): void {
    if (!on) {
      this.unwatch?.();
      this.unwatch = null;
      this.userActions = [];
      return;
    }
    if (this.unwatch) return;
    const root = this.options.root ?? document.documentElement;
    const win = root.ownerDocument.defaultView;
    this.userRoute = this.routes?.current();
    this.wentBackAt = 0;
    const click = (e: Event) => this.onUserClick(e);
    const input = (e: Event) => this.onUserInput(e);
    const change = (e: Event) => this.onUserChange(e);
    // (the kit's own back fires it too, and the browser may call that one trusted)
    const popstate = () => {
      if (!this.acting && Date.now() >= this.quietUntil) this.wentBackAt = Date.now();
    };
    // (captured: what was pressed is named as it was before the app's own handlers change it)
    root.addEventListener('click', click, true);
    root.addEventListener('input', input, true);
    root.addEventListener('change', change, true);
    win?.addEventListener('popstate', popstate);
    // A page the user goes to: however the app routes, its current route changes
    const timer = setInterval(() => this.noteRoute(), 400);
    this.unwatch = () => {
      root.removeEventListener('click', click, true);
      root.removeEventListener('input', input, true);
      root.removeEventListener('change', change, true);
      win?.removeEventListener('popstate', popstate);
      clearInterval(timer);
    };
  }

  /** The kit's own calls are running, or have just: an event now is theirs unless a person made it. */
  private ownEvent(e: Event): boolean {
    return (this.acting > 0 || Date.now() < this.quietUntil) && !e.isTrusted;
  }

  private doneActing(): void {
    this.acting--;
    this.quietUntil = Date.now() + 300;
    if (this.routes) this.userRoute = this.routes.current();
  }

  private drainUser(): UserAction[] {
    const out = this.userActions;
    this.userActions = [];
    return out;
  }

  private noteUser(action: UserAction): void {
    const last = this.userActions.at(-1);
    // Typing into the same field on and on: one entry, with what it says now
    if (action.op === 'write' && last?.op === 'write' && last.node?.id === action.node?.id) this.userActions[this.userActions.length - 1] = action;
    else {
      this.userActions.push(action);
      if (this.userActions.length > 30) this.userActions.shift();
    }
    this.options.onUserAction?.(action);
  }

  /** The route changed and the kit didn't change it: the user went there (or back). */
  private noteRoute(): void {
    if (!this.unwatch || !this.routes) return;
    const now = this.routes.current();
    if (now === this.userRoute) return;
    this.userRoute = now;
    // (the kit's own navigate, still settling)
    if (this.acting > 0 || Date.now() < this.quietUntil) {
      this.wentBackAt = 0;
      return;
    }
    const back = Date.now() - this.wentBackAt < 1500;
    this.wentBackAt = 0;
    // A press that took them there: it says where it led too
    const last = this.userActions.at(-1);
    if (last?.op === 'press' && Date.now() - last.at < 1500) last.route = now;
    this.noteUser({ at: Date.now(), op: back ? 'back' : 'navigate', route: now });
  }

  /** An action on a node, as it is now (with the route it was on). */
  private user(op: string, node: NonNullable<UserAction['node']>, value?: string): void {
    this.noteRoute();
    const route = this.routes?.current();
    this.noteUser({ at: Date.now(), op, node, ...(value !== undefined ? { value } : {}), ...(route !== undefined ? { route } : {}) });
  }

  private onUserClick(e: Event): void {
    const target = e.target instanceof Element ? e.target : null;
    if (!target || this.ownEvent(e)) return;
    // A label's click is passed on to its field, which is noted itself
    const label = target.closest('label');
    if (label?.control && !label.control.contains(target)) return;
    const hit = this.userNode(target);
    if (!hit) return;
    const { el, node, ops } = hit;
    switch (node.role) {
      case 'checkbox':
      case 'switch': {
        // (a native box has changed by the time its click is dispatched; another one says so once the app has rendered: it will be the other)
        const on = el instanceof HTMLInputElement ? el.checked : el.getAttribute('aria-checked') !== 'true';
        return this.user('toggle', node, on ? 'on' : 'off');
      }
      case 'radio':
      case 'tab':
        return this.user('select', node, node.name);
      case 'textbox':
      case 'select':
        // (noted as what is in them changes)
        return;
    }
    if (ops.includes('press')) this.user('press', node);
  }

  private onUserInput(e: Event): void {
    const target = e.target instanceof Element ? e.target : null;
    if (!target || this.ownEvent(e)) return;
    const hit = this.userNode(target);
    if (!hit || hit.node.role !== 'textbox') return;
    const { el, node } = hit;
    // Never what goes into a password field: only that they typed in it
    const text = isSecret(el) ? undefined : ((el as HTMLInputElement).value ?? (el as HTMLElement).innerText ?? '');
    this.user('write', node, text === undefined ? undefined : text.length > 80 ? text.slice(0, 79) + '…' : text);
  }

  private onUserChange(e: Event): void {
    const target = e.target instanceof Element ? e.target : null;
    if (!(target instanceof HTMLSelectElement) || this.ownEvent(e)) return;
    const hit = this.userNode(target);
    if (hit?.node.role === 'select') this.user('select', hit.node, target.options[target.selectedIndex]?.textContent?.trim() ?? target.value);
  }

  /**
   * The node the user acted on: the nearest element the tree makes one of (a container's entry too), as the tree would have it now —
   * its id, key, role and name, and its ops' names. None in what the tree leaves out.
   */
  private userNode(target: Element): { el: Element; node: NonNullable<UserAction['node']>; ops: string[] } | null {
    const root = this.options.root ?? document.documentElement;
    if (!root.contains(target)) return null;
    const path: Element[] = [];
    for (let e: Element | null = target; e; e = e === root ? null : e.parentElement) {
      if (e.hasAttribute('data-afford-skip') || this.optionsOf(e)?.skip || (this.options.skip && e.matches(this.options.skip))) return null;
      path.push(e);
    }
    // In a container: its entry (the outermost element under it that is one) is a node, and keys inside it are under the entry's
    const boxAt = path.findIndex((e, i) => i > 0 && this.containerOf(e));
    let entry: { at: number; key?: string } | null = null;
    if (boxAt > 0) {
      const boxEl = path[boxAt]!;
      const box = this.containerOf(boxEl)!;
      const boxKey = this.knownNode(boxEl)?.key ?? this.optionsOf(boxEl)?.key;
      for (let i = boxAt - 1; i >= 0 && !entry; i--) {
        let id = this.itemIdOf(path[i]!, box);
        if (id === null) continue;
        if (!id) id = this.itemsOf(boxEl, box).find((it) => it.el === path[i])?.id ?? '';
        entry = { at: i, ...(boxKey !== undefined && id ? { key: itemKey(boxKey, id) } : {}) };
      }
    }
    const end = entry ? entry.at : path.length - 1;
    for (let i = 0; i <= end; i++) {
      const el = path[i]!;
      const opts = this.optionsOf(el);
      const isEntry = entry?.at === i;
      const role: Role | null = isEntry ? (opts?.role ?? 'listitem') : this.containerOf(el) ? 'container' : (opts?.role ?? roleOf(el) ?? (opts || el.hasAttribute('data-afford') ? 'region' : null));
      if (!role) continue;
      const known = this.knownNode(el);
      const key = known?.key ?? (isEntry ? entry!.key : opts?.key && entry?.key ? `${entry.key}.${opts.key}` : opts?.key);
      const ops = opsFor(role, undefined, (opts?.ops ?? []).map(({ name }) => ({ name, policy: 'allow' as Policy }))).map((o) => o.name);
      return { el, node: { id: this.idOf(el), ...(key ? { key } : {}), role, name: opts?.name ?? (isEntry ? nameOf(el, 'listitem') : nameOf(el, role === 'container' ? 'list' : role)) }, ops };
    }
    return null;
  }

  /** The node an element was in the last tree (or an entry fetched), if it was. */
  private knownNode(el: Element): AffordNode | undefined {
    const id = this.ids.get(el);
    return id ? (this.lastTree.get(id) ?? this.fetched.get(id)) : undefined;
  }

  /** An agent in the page itself: its tools on this kit, straight (no transport). */
  agent(options: Omit<RemoteOptions, 'send'> = {}): AffordRemote {
    return new AffordRemote({ ...options, send: (r) => this.answer(r) });
  }

  /** Run the agent's calls in order; the results, and the context afterwards (its next round). */
  async execute(calls: Call | Call[]): Promise<ExecuteResult> {
    // (what the calls set off on the page is not the user's doing: see watchUser)
    this.acting++;
    try {
      const results: CallResult[] = [];
      if (!this.lastTree.size) this.context();
      // Entries fetched before that have left the page since: their nodes go
      for (const [id] of this.fetched) if (!this.byId.get(id)?.deref()?.isConnected) this.fetched.delete(id);
      const list = Array.isArray(calls) ? calls : [calls];
      for (const call of list) results.push(await this.run(call));
      // What they changed shows before the screen goes back (a framework renders on the next frame): not after reading only
      if (list.some((c) => !('peek' in c) && !('op' in c && (c.op === 'read' || c.op === 'items' || c.op === 'view'))) && !list.every((c) => 'navigate' in c)) await (this.options.settle?.() ?? nextFrames());
      return { results, context: this.context() };
    } finally {
      this.doneActing();
    }
  }

  /**
   * A handoff an agent left (see Handoff), run when the user is back — they tapped its notification: its route first (shown before
   * going on), then its calls in order, as the agent's calls run (policies and all: deny is never run, confirm asks — confirm here,
   * else the kit's; without either it stops there, not done). Stops at the first that fails. An expired one is not run.
   *
   * Only run one your app got over its own authenticated channel (fetched by the id in the notification, never taken from the
   * notification or a link itself), and only once.
   */
  async runHandoff(handoff: Handoff, options: HandoffOptions = {}): Promise<HandoffResult> {
    this.acting++;
    try {
      return await this.handoff(handoff, options);
    } finally {
      this.doneActing();
    }
  }

  private async handoff(handoff: Handoff, options: HandoffOptions): Promise<HandoffResult> {
    const results: CallResult[] = [];
    const stop = (at: number, code: ErrorCode, error: string): HandoffResult => ({ ok: false, ran: Math.max(0, at), stoppedAt: at, code, error, results });
    const problem = handoffProblem(handoff);
    if (problem) return stop(-1, 'bad_args', problem);
    const h = parseHandoff(handoff, options.now ?? Date.now());
    if (!h) return stop(-1, 'expired', 'This handoff has expired: it was not run');
    if (!this.lastTree.size) this.context();
    for (const [id] of this.fetched) if (!this.byId.get(id)?.deref()?.isConnected) this.fetched.delete(id);
    if (h.route) {
      const r = await this.run({ navigate: h.route });
      results.push(r);
      if (!r.ok) return stop(-1, r.code ?? 'failed', r.error ?? 'Could not go there');
    }
    for (const [i, c] of h.calls.entries()) {
      const r = await this.run({ node: c.key, op: c.op, ...(c.args ? { args: c.args } : {}) }, options.confirm ?? this.options.confirm);
      results.push(r);
      if (!r.ok) return stop(i, r.code ?? 'failed', r.error ?? 'It failed');
      // (what it changed shows before the next: a press that opens what the next one works on)
      await (this.options.settle?.() ?? nextFrames());
    }
    return { ok: true, ran: h.calls.length, results };
  }

  private async allowed(policy: Policy, what: { call: Call; node?: AffordNode; tool?: ToolSpec }, confirm = this.options.confirm): Promise<CallResult | null> {
    if (policy === 'allow') return null;
    if (policy === 'deny') return { call: what.call, ok: false, code: 'denied', error: 'Not allowed: the user does this themselves' };
    const yes = confirm ? await confirm(what) : null;
    if (yes === null) return { call: what.call, ok: false, needsConfirm: true, code: 'needs_confirm', error: 'Needs the user to confirm first' };
    return yes ? null : { call: what.call, ok: false, code: 'declined', error: 'The user said no' };
  }

  private async run(call: Call, confirm = this.options.confirm): Promise<CallResult> {
    try {
      if ('navigate' in call) {
        const r = this.routes;
        if (!r) return { call, ok: false, code: 'not_found', error: 'This app has no routes' };
        if (call.navigate === 'back') {
          if (!r.back || r.canGoBack?.() === false) return { call, ok: false, code: 'not_found', error: 'Nowhere to go back to' };
          await r.back();
        } else {
          if (!findRoute(r.routes, call.navigate)) return { call, ok: false, code: 'not_found', error: 'No route ' + call.navigate + ' (the routes: ' + r.routes.map((x) => x.path).join(', ') + ')' };
          await r.navigate(call.navigate);
        }
        // The new page shows before the next call (which may act on it by key)
        await (r.settle?.() ?? nextFrames());
        this.context();
        return { call, ok: true, value: r.current() };
      }
      if ('peek' in call) return { call, ok: true, value: await this.peek(call.peek) };
      if ('tool' in call) {
        const tool = this.tools.get(call.tool);
        if (!tool) return { call, ok: false, code: 'not_found', error: `No tool ${call.tool}` };
        const spec: ToolSpec = { name: tool.name, description: tool.description, policy: tool.policy ?? 'allow' };
        const blocked = await this.allowed(spec.policy, { call, tool: spec }, confirm);
        if (blocked) return blocked;
        return { call, ok: true, value: await tool.execute(call.args ?? {}) };
      }
      if (call.node.startsWith('peek:')) return { call, ok: false, code: 'not_found', error: 'That id is from a peek: navigate to the page first, then use the key (or look again)' };
      const hit = await this.resolve(call.node);
      if (!hit) return { call, ok: false, code: 'not_found', error: `No node ${call.node} on screen (it may have gone: look at the tree again)` };
      const { el, node } = hit;
      const op = node.ops.find((o) => o.name === call.op);
      if (!op) return { call, ok: false, code: 'no_op', error: `${node.role} "${node.name}" has no op ${call.op} (it has: ${node.ops.map((o) => o.name).join(', ') || 'none'})` };
      const blocked = await this.allowed(op.policy, { call, node }, confirm);
      if (blocked) return blocked;
      const custom = this.optionsOf(el)?.ops?.find((o) => o.name === call.op);
      // (shown for what changes something on screen: not reads, nor a container fetching its entries)
      const containerOp = !custom && node.role === 'container' && ['item', 'items', 'scroll_to', 'scroll'].includes(call.op);
      if (call.op !== 'read' && call.op !== 'view' && !containerOp) await this.options.onAct?.({ node, op: call.op, args: call.args ?? {}, el });
      if (custom) return { call, ok: true, value: await custom.run(call.args ?? {}, el) };
      return { call, ok: true, value: await this.standard(el, node, call.op, call.args ?? {}) };
    } catch (error) {
      return { call, ok: false, code: error instanceof AffordError ? error.code : 'failed', error: (error as Error).message };
    }
  }

  private async standard(el: Element, node: AffordNode, op: string, args: Record<string, unknown>): Promise<unknown> {
    const max = this.options.maxRead ?? 20_000;
    const text = (v: unknown) => (typeof v === 'string' ? v : String(v ?? ''));
    const box = node.role === 'container' ? (this.containerOf(el) ?? {}) : null;
    if (box) {
      // (an entry's key: the id in it)
      const idOf = (v: unknown) => {
        const id = text(v);
        return node.key && id.startsWith(node.key + '[') && id.endsWith(']') ? id.slice(node.key.length + 1, -1) : id;
      };
      switch (op) {
        case 'items':
          return this.containerItems(el, node, box, args);
        case 'item': {
          let target: ScrollTarget;
          if (args.id !== undefined && args.id !== '') target = { id: idOf(args.id) };
          else if (typeof args.index === 'number') target = { index: args.index };
          else if (typeof args.query === 'string' && args.query) {
            // (found by scrolling through: left there, rendered)
            const first = (await this.containerItems(el, node, box, { query: args.query, limit: 1 }, true)).items[0];
            if (!first) throw new AffordError('not_found', `No entry has "${args.query}"`);
            target = { id: first.id };
          } else throw new AffordError('bad_args', 'Say which entry: id, index or query');
          return this.fetchItem(el, box, node.key, target, args.preview === true);
        }
        case 'scroll_to': {
          const index = typeof args.index === 'number' ? args.index : undefined;
          if (args.item !== undefined) await this.reveal(el, box, { id: idOf(args.item) });
          else if (index !== undefined) await this.reveal(el, box, { index });
          else throw new AffordError('bad_args', 'Say which entry: index or item');
          return undefined;
        }
        case 'scroll': {
          const pages = typeof args.by === 'number' ? args.by : 1;
          if (box.scroll) await box.scroll(pages);
          else {
            const scroller = scrollerOf(el);
            if (scroller) scroller.scrollBy?.({ top: pages * scroller.clientHeight });
            else window.scrollBy?.({ top: pages * window.innerHeight });
          }
          await (box.settle?.() ?? nextFrames());
          return undefined;
        }
      }
    }
    switch (op) {
      case 'press':
      case 'select':
        if (node.state?.disabled) throw new AffordError('disabled', `"${node.name}" is disabled`);
        (el as HTMLElement).click();
        return undefined;
      case 'read':
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) return el.value;
        if (el instanceof HTMLSelectElement) return { value: el.options[el.selectedIndex]?.textContent?.trim() ?? el.value, options: [...el.options].map((o) => o.textContent?.trim() ?? o.value) };
        return ((el as HTMLElement).innerText ?? el.textContent ?? '').slice(0, max);
      case 'write':
        setValue(el, text(args.text));
        return undefined;
      case 'append':
        setValue(el, ((el as HTMLInputElement).value ?? (el as HTMLElement).innerText ?? '') + text(args.text));
        return undefined;
      case 'clear':
        setValue(el, '');
        return undefined;
      case 'toggle':
        (el as HTMLElement).click();
        return undefined;
      case 'view':
        return viewImage(el);
      case 'set': {
        const on = el instanceof HTMLInputElement ? el.checked : el.getAttribute('aria-checked') === 'true';
        if (on !== Boolean(args.on)) (el as HTMLElement).click();
        return undefined;
      }
      case 'choose': {
        if (!(el instanceof HTMLSelectElement)) throw new AffordError('no_op', 'Not a native select: use its own ops');
        const want = text(args.option);
        const option = [...el.options].find((o) => o.value === want || o.textContent?.trim() === want);
        if (!option) throw new AffordError('bad_args', `No option "${want}"`);
        el.value = option.value;
        option.selected = true;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return undefined;
      }
    }
    throw new AffordError('no_op', `No way to ${op} a ${node.role}`);
  }

  /** A page of a container's entries: from the app's data when it gives it, else the entries in the DOM. */
  private async containerItems(el: Element, node: AffordNode, list: ContainerOptions, args: Record<string, unknown>, stay = false): Promise<ItemsPage> {
    const offset = Math.max(0, Math.floor(Number(args.offset ?? 0)) || 0);
    const limit = Math.min(200, Math.max(1, Math.floor(Number(args.limit ?? 20)) || 20));
    const query = typeof args.query === 'string' && args.query ? args.query : undefined;
    const keyed = (i: ItemInfo): ItemSummary => ({ ...(node.key ? { key: itemKey(node.key, i.id) } : {}), ...i });
    if (list.items) {
      const got = await list.items({ offset, limit, ...(query ? { query } : {}) });
      const items = Array.isArray(got) ? got : got.items;
      const count = (Array.isArray(got) ? undefined : got.count) ?? list.count?.();
      return { ...(count !== undefined ? { count } : {}), offset, items: items.map((it, k) => keyed({ index: offset + k, ...it, id: String(it.id) })) };
    }
    // Found by the kit: the entries in the DOM, by all their text; looking for more than they hold, scrolled through (a virtualized
    // list has only those on screen)
    const all = this.itemsOf(el, list)
      .filter((i) => !query || matches(query, this.entryText(i.el)))
      .map(({ el: item, id, index }) => ({ id, index, name: this.entryName(item) }));
    if (query && all.length < offset + limit && scrollerOf(el)) {
      const found = await this.scrollScan(el, list, (i) => matches(query, this.entryText(i.el)), offset + limit, stay);
      return { offset, items: found.slice(offset).map(keyed) };
    }
    return { count: all.length, offset, items: all.slice(offset, offset + limit).map(keyed) };
  }

  private entryName(el: Element): string {
    return this.optionsOf(el)?.name ?? nameOf(el, 'listitem');
  }

  private entryText(el: Element): string {
    return `${this.entryName(el)}\n${this.optionsOf(el)?.description ?? ''}\n${el.textContent ?? ''}`;
  }

  /**
   * Scrolls through a container from the top, a page at a time, reading each entry as it is rendered, until limit entries wanted are
   * found; then back where it was (or, stay, left at the last one found, rendered).
   */
  private async scrollScan(boxEl: Element, box: ContainerOptions, want: (i: { el: Element; id: string; index: number }) => boolean, limit: number, stay = false): Promise<ItemInfo[]> {
    const scroller = scrollerOf(boxEl);
    const seen = new Set<string>();
    const found: ItemInfo[] = [];
    const look = () => {
      for (const i of this.itemsOf(boxEl, box)) {
        const order = seen.size;
        if (seen.has(i.id)) continue;
        seen.add(i.id);
        const explicit = box.indexOf?.(i.el) ?? (i.el.hasAttribute('data-afford-index') ? i.index : undefined);
        if (found.length < limit && want(i)) found.push({ id: i.id, index: explicit ?? order, name: this.entryName(i.el) });
      }
    };
    if (!scroller) {
      look();
      return found;
    }
    const start = scroller.scrollTop;
    const go = async (top: number) => {
      scroller.scrollTop = top;
      scroller.dispatchEvent(new Event('scroll'));
      await (box.settle?.() ?? nextFrames());
    };
    await go(0);
    for (let n = 0; n < 1000; n++) {
      look();
      const max = scroller.scrollHeight - scroller.clientHeight;
      if (found.length >= limit || scroller.scrollTop >= max - 1) break;
      const was = scroller.scrollTop;
      await go(Math.min(was + scroller.clientHeight * 0.9, max));
      if (scroller.scrollTop <= was) break;
    }
    if (!stay || !found.length) await go(start);
    return found;
  }
}

/**
 * While the tree is built: the container being walked (its entries are found among its descendants), the key prefix inside an
 * entry, and (entry) that the element walked is the root of an entry's own tree.
 */
interface Scope {
  box?: { opts: ContainerOptions; key?: string; seen: number; shown: number[]; preview: ItemSummary[]; viewport: DOMRect | null };
  prefix?: string;
  entry?: { key?: string };
}

/** Long text cut short for the tree (read gives it all). */
function clip(text: string, max = 200): string {
  const t = text.replace(/\s+/g, ' ');
  return t.length > max ? t.slice(0, max - 1) + '…' : t;
}

/** An image (img, canvas, svg) as a picture: read through a canvas, else where it is (another site's image can't be read). */
async function viewImage(el: Element): Promise<ImageValue> {
  const doc = el.ownerDocument;
  if (el instanceof HTMLCanvasElement) return { type: 'image', mime: 'image/png', data: el.toDataURL('image/png').split(',')[1] ?? '', width: el.width, height: el.height };
  const img = el instanceof HTMLImageElement ? el : el.querySelector('img');
  if (img) {
    const width = img.naturalWidth || img.width;
    const height = img.naturalHeight || img.height;
    try {
      const canvas = doc.createElement('canvas');
      const scale = Math.min(1, 1024 / Math.max(width, height, 1));
      canvas.width = Math.max(1, Math.round(width * scale));
      canvas.height = Math.max(1, Math.round(height * scale));
      const g = canvas.getContext('2d');
      if (!g) throw new Error('no canvas');
      g.drawImage(img, 0, 0, canvas.width, canvas.height);
      const data = canvas.toDataURL('image/png').split(',')[1];
      if (!data) throw new Error('no data');
      return { type: 'image', mime: 'image/png', data, width: canvas.width, height: canvas.height };
    } catch {
      return { type: 'image', mime: 'image/*', url: img.currentSrc || img.src, width, height };
    }
  }
  throw new AffordError('no_op', 'Nothing to view in it (an img, a canvas)');
}

/** Whether an entry is what a query asks for: each of its words in its text (any case). */
function matches(query: string, text: string): boolean {
  const t = text.toLowerCase();
  return query.toLowerCase().split(/\s+/).filter(Boolean).every((w) => t.includes(w));
}

/** The box an element scrolls in (itself or an ancestor), if any. */
function scrollerOf(el: Element): Element | null {
  for (let e: Element | null = el; e && e !== e.ownerDocument.documentElement; e = e.parentElement) {
    const style = e.ownerDocument.defaultView?.getComputedStyle(e);
    if (style && /(auto|scroll)/.test(style.overflowY) && e.scrollHeight > e.clientHeight) return e;
  }
  return null;
}
