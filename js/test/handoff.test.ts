// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest';
import { AffordRemote, anthropicTools, handoffExpired, handoffProblem, mcpHandlers, openaiResponsesTools, openaiTools, parseHandoff, type Handoff, type RouteSpec } from '../src/index.js';
import { AffordKit } from '../src/dom.js';

/** A mail app with an inbox and a drafts page: a draft opens when pressed; one draft may not be touched, one needs a yes. */
function app(confirm?: () => boolean) {
  const opened: string[] = [];
  const pages: Record<string, string> = {
    '/mail/inbox': `<main aria-label="Inbox"><button data-afford-key="mail.compose">Compose</button></main>`,
    '/drafts': `<main aria-label="Drafts">
      <button data-afford-key="draft.7">Re: Lunch?</button>
      <button data-afford-key="draft.8" data-afford-policy="deny">Re: Contract</button>
      <button data-afford-key="draft.9" data-afford-policy="confirm">Re: Invoice</button>
    </main>`,
  };
  const history = ['/mail/inbox'];
  const render = () => {
    document.body.innerHTML = pages[history.at(-1)!] ?? '<main aria-label="Not found"></main>';
    for (const b of document.querySelectorAll('button')) b.addEventListener('click', () => opened.push(b.getAttribute('data-afford-key')!));
  };
  render();
  const routes: RouteSpec[] = [
    { path: '/mail/:folder', description: 'A mail folder' },
    { path: '/drafts', description: 'The drafts' },
  ];
  const kit = new AffordKit({ isVisible: () => true, ...(confirm ? { confirm } : {}) });
  kit.setRoutes({ current: () => history.at(-1)!, routes, navigate: (r) => (history.push(r), render()) });
  return { kit, history, opened };
}

const good: Handoff = { v: 1, message: '回复写好了，在草稿箱', route: '/drafts', calls: [{ key: 'draft.7', op: 'press' }] };

describe('handoffs: checked', () => {
  it('takes a good one (calls by key, ui_act\'s node too) and drops bad ones: ids, too many calls, no message, expired', () => {
    expect(parseHandoff(good)).toEqual(good);
    expect(parseHandoff({ message: ' Done ', calls: [{ node: 'mail.list[42].reply', op: 'press', args: {} }] })).toEqual({ v: 1, message: 'Done', calls: [{ key: 'mail.list[42].reply', op: 'press', args: {} }] });
    for (const id of ['n12', 'w4', 'p3', 'app', 'behind-2', 'peek:n1']) {
      expect(parseHandoff({ message: 'x', calls: [{ key: id, op: 'press' }] })).toBeNull();
      expect(handoffProblem({ message: 'x', calls: [{ key: id, op: 'press' }] })).toContain('use the control\'s key');
    }
    const many = Array.from({ length: 21 }, (_, i) => ({ key: `draft.${i}`, op: 'press' }));
    expect(handoffProblem({ message: 'x', calls: many })).toContain('Too many calls');
    expect(parseHandoff({ message: 'x', calls: many.slice(0, 20) })).not.toBeNull();
    expect(parseHandoff({ route: '/drafts' })).toBeNull();
    expect(parseHandoff({ message: '   ' })).toBeNull();
    expect(handoffProblem({ message: 'x'.repeat(501) })).toContain('too long');
    expect(parseHandoff({ message: 'x', route: 'back' })).toBeNull();
    expect(parseHandoff({ message: 'x', calls: [{ key: 'a', op: 'press', args: [] }] })).toBeNull();
    expect(parseHandoff({ v: 2, message: 'x' })).toBeNull();
    expect(parseHandoff('{"message":"x"}')).toBeNull();
    // Expired: not a handoff any more
    expect(parseHandoff({ ...good, expiresAt: 1000 }, 2000)).toBeNull();
    expect(parseHandoff({ ...good, expiresAt: 3000 }, 2000)).toMatchObject({ expiresAt: 3000 });
    expect(handoffExpired({ expiresAt: 1000 }, 2000)).toBe(true);
    expect(handoffExpired({}, 2000)).toBe(false);
  });
});

describe('the agent\'s side while the user is away', () => {
  it('answers code away for the screen tools at once, without asking the app', async () => {
    let asked = 0;
    let present = false;
    const ui = new AffordRemote({ send: async (r) => (asked++, { error: `unexpected ${JSON.stringify(r)}` }), present: () => present });
    for (const [name, input] of [['ui_look', {}], ['ui_act', { node: 'reply', op: 'press' }], ['ui_navigate', { route: '/drafts' }], ['ui_peek', { route: '/drafts' }], ['ui_tool', { name: 'refresh' }]] as const) {
      const a = await ui.handle(name, input);
      expect([a.isError, a.code]).toEqual([true, 'away']);
      expect(a.text).toContain('not in the app right now');
    }
    expect(asked).toBe(0);
    // (not a tool of these: as before)
    expect((await ui.handle('ui_fly')).code).toBe('bad_args');
    present = true;
    expect((await ui.handle('ui_look')).code).toBe('unavailable');
    expect(asked).toBe(1);
  });

  it('offers ui_handoff only with onHandoff, checks it, gives it to the host and tells the agent what the host said', async () => {
    const { kit } = app();
    expect(kit.agent().tools().map((t) => t.name)).not.toContain('ui_handoff');
    expect((await kit.agent().handle('ui_handoff', { message: 'x' })).code).toBe('not_found');
    expect(new AffordRemote({ send: kit.answer.bind(kit), tools: ['ui_look', 'ui_handoff'] }).tools().map((t) => t.name)).toEqual(['ui_look']);

    const left: Handoff[] = [];
    let away = false;
    const ui = kit.agent({ present: () => !away, onHandoff: async (h) => (left.push({ ...h, id: 'h1' }), 'notification sent') });
    expect(ui.tools().map((t) => t.name)).toContain('ui_handoff');
    expect(anthropicTools(ui.tools()).at(-1)!.name).toBe('ui_handoff');
    expect(openaiTools(ui.tools()).at(-1)!.function.name).toBe('ui_handoff');
    expect(openaiResponsesTools(ui.tools()).at(-1)!.name).toBe('ui_handoff');
    expect((await mcpHandlers(ui).list()).tools.map((t) => t.name)).toContain('ui_handoff');
    await ui.handle('ui_look');

    away = true;
    expect((await ui.handle('ui_look')).text).toContain('leave a handoff (ui_handoff)');
    const bad = await ui.handle('ui_handoff', { message: 'Done', calls: [{ key: 'w12', op: 'press' }] });
    expect([bad.isError, bad.code]).toEqual([true, 'bad_args']);
    expect((await ui.handle('ui_handoff', { message: 'Done', route: '/nowhere' })).text).toContain('No route /nowhere');
    expect(left).toEqual([]);

    const before = Date.now();
    const ok = await ui.handle('ui_handoff', { message: '回复写好了，在草稿箱', route: '/drafts', calls: [{ key: 'draft.7', op: 'press' }], expiresAt: 1, id: 'mine' });
    expect(ok).toEqual({ text: 'Handoff left: notification sent', isError: false });
    expect(left).toHaveLength(1);
    expect(left[0]).toMatchObject({ v: 1, message: '回复写好了，在草稿箱', route: '/drafts', calls: [{ key: 'draft.7', op: 'press' }], id: 'h1' });
    // (its expiry the remote's, a day on by default)
    expect(left[0]!.expiresAt! - before).toBeGreaterThanOrEqual(24 * 3600_000 - 1000);

    const quiet = new AffordRemote({ send: kit.answer.bind(kit), onHandoff: () => {} });
    expect((await quiet.handle('ui_handoff', { message: 'Done' })).text).toBe('Handoff left: the user gets it when they come back.');
  });
});

describe('kit.runHandoff: the user is back', () => {
  it('goes to its route and presses a keyed node there', async () => {
    const { kit, history, opened } = app();
    const r = await kit.runHandoff({ ...good, id: 'h1', expiresAt: Date.now() + 60_000 });
    expect(r).toMatchObject({ ok: true, ran: 1 });
    expect(r.results.map((x) => x.ok)).toEqual([true, true]);
    expect(history.at(-1)).toBe('/drafts');
    expect(opened).toEqual(['draft.7']);
  });

  it('stops with not_found at a key that is not there, and never runs a denied node', async () => {
    const { kit, opened } = app();
    const missing = await kit.runHandoff({ v: 1, message: 'x', route: '/drafts', calls: [{ key: 'draft.6', op: 'press' }, { key: 'draft.7', op: 'press' }] });
    expect(missing).toMatchObject({ ok: false, ran: 0, stoppedAt: 0, code: 'not_found' });
    expect(opened).toEqual([]);
    const denied = await kit.runHandoff({ v: 1, message: 'x', calls: [{ key: 'draft.7', op: 'press' }, { key: 'draft.8', op: 'press' }] });
    expect(denied).toMatchObject({ ok: false, ran: 1, stoppedAt: 1, code: 'denied' });
    expect(opened).toEqual(['draft.7']);
  });

  it('asks before a confirm node (declined: stops), not run without a way to ask', async () => {
    const { kit, opened } = app();
    const call: Handoff = { v: 1, message: 'x', route: '/drafts', calls: [{ key: 'draft.9', op: 'press' }] };
    expect(await kit.runHandoff(call)).toMatchObject({ ok: false, code: 'needs_confirm', stoppedAt: 0 });
    let asked = 0;
    expect(await kit.runHandoff(call, { confirm: () => (asked++, false) })).toMatchObject({ ok: false, code: 'declined', ran: 0 });
    expect(asked).toBe(1);
    expect(opened).toEqual([]);
    expect(await kit.runHandoff(call, { confirm: () => true })).toMatchObject({ ok: true, ran: 1 });
    expect(opened).toEqual(['draft.9']);
    // (the kit's own confirm, when the handoff gives none)
    const own = app(() => false);
    expect(await own.kit.runHandoff(call)).toMatchObject({ code: 'declined' });
  });

  it('refuses an expired one, and one that is not a handoff', async () => {
    const { kit, history, opened } = app();
    expect(await kit.runHandoff({ ...good, expiresAt: 1000 })).toMatchObject({ ok: false, ran: 0, stoppedAt: -1, code: 'expired', results: [] });
    expect(await kit.runHandoff({ ...good, expiresAt: 3000 }, { now: 2000 })).toMatchObject({ ok: true });
    expect(await kit.runHandoff({ v: 1, message: 'x', calls: [{ key: 'n1', op: 'press' }] })).toMatchObject({ ok: false, code: 'bad_args' });
    expect(await kit.runHandoff({ v: 1, message: 'x', route: '/nowhere', calls: [] })).toMatchObject({ ok: false, code: 'not_found', stoppedAt: -1 });
    expect(history).toEqual(['/mail/inbox', '/drafts']);
    expect(opened).toEqual(['draft.7']);
  });
});
