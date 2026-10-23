// @vitest-environment happy-dom
import { beforeEach, describe, expect, it } from 'vitest';
import { AGENT_TOOLS, describe as describeTree, toCall, type AffordNode } from '../src/index.js';
import { AffordKit } from '../src/dom.js';

const all = (n: AffordNode): AffordNode[] => [n, ...(n.children ?? []).flatMap(all)];
const find = (root: AffordNode, name: string) => all(root).find((n) => n.name === name)!;

beforeEach(() => {
  document.body.innerHTML = `
    <main aria-label="Mail">
      <h1>Inbox</h1>
      <div class="layout"><div class="deep">
        <input aria-label="Search" value="invoice">
        <button id="send" data-afford-policy="deny">Send</button>
        <button id="later">Later</button>
      </div></div>
      <label for="body">Body</label><textarea id="body">Hi Wang,
see you Tuesday.</textarea>
      <label><input type="checkbox" checked> Notify me</label>
      <select aria-label="Interval"><option value="1">1 min</option><option value="5" selected>5 min</option></select>
      <input id="pw" type="password" aria-label="Password" value="hunter2">
      <aside class="chat"><textarea aria-label="Ask Momo">refine</textarea></aside>
    </main>`;
});

describe('AffordKit on the DOM', () => {
  it('builds the tree by subtraction: controls and their ops, layout passed through, never content or secrets', () => {
    const kit = new AffordKit({ isVisible: () => true, skip: '.chat' });
    const { root } = kit.context();
    const main = root.children![0]!;
    expect(main).toMatchObject({ role: 'page', name: 'Mail' }); // (its aria-label, over its heading)
    // The two layout divs are gone: the controls sit right under the page
    expect(main.children!.map((n) => [n.role, n.name])).toEqual([
      ['heading', 'Inbox'],
      ['textbox', 'Search'],
      ['button', 'Send'],
      ['button', 'Later'],
      ['textbox', 'Body'],
      ['checkbox', 'Notify me'],
      ['select', 'Interval'],
      ['textbox', 'Password'],
    ]);
    expect(find(root, 'Body')).toMatchObject({ state: { length: 25 }, ops: expect.arrayContaining([expect.objectContaining({ name: 'write', policy: 'allow' })]) });
    expect(JSON.stringify(root)).not.toContain('see you Tuesday');
    expect(find(root, 'Send').ops).toEqual([{ name: 'press', policy: 'deny' }]);
    expect(find(root, 'Password').ops.every((o) => o.policy === 'deny')).toBe(true);
    expect(all(root).some((n) => n.name === 'Ask Momo')).toBe(false);
    // And as text for a prompt
    expect(describeTree(kit.context())).toContain(`button "Send" — press(deny)`);
  });

  it('goes into a display: contents wrapper (a dialog portalled in one): it has no box, but what is in it shows', () => {
    document.body.innerHTML = `
      <main aria-label="Mail"><button>Reply</button></main>
      <div class="presence" style="display: contents"><div role="dialog" aria-label="Reply"><textarea aria-label="Body"></textarea></div></div>
      <div style="display: none"><button>Hidden</button></div>`;
    // (as browsers answer: no box for display: contents, nor for display: none)
    const real = HTMLElement.prototype.checkVisibility;
    HTMLElement.prototype.checkVisibility = function (this: HTMLElement) {
      for (let e: HTMLElement | null = this; e; e = e.parentElement) if (['contents', 'none'].includes(e.style.display) && (e === this || e.style.display === 'none')) return false;
      return true;
    };
    try {
      const { root } = new AffordKit().context();
      expect(find(root, 'Reply')).toBeTruthy();
      expect(all(root).map((n) => [n.role, n.name])).toEqual(expect.arrayContaining([['dialog', 'Reply'], ['textbox', 'Body']]));
      expect(all(root).some((n) => n.name === 'Hidden')).toBe(false);
    } finally {
      HTMLElement.prototype.checkVisibility = real;
    }
  });

  it('runs the agent\'s calls: reads on demand, writes as if typed, refuses what is denied, returns the next context', async () => {
    const kit = new AffordKit({ isVisible: () => true });
    const ctx = kit.context();
    const body = find(ctx.root, 'Body');
    const send = find(ctx.root, 'Send');
    const later = find(ctx.root, 'Later');
    let typed = '';
    document.getElementById('body')!.addEventListener('input', (e) => (typed = (e.target as HTMLTextAreaElement).value));
    let pressed = 0;
    document.getElementById('later')!.addEventListener('click', () => pressed++);
    document.getElementById('send')!.addEventListener('click', () => {
      throw new Error('must not be pressed');
    });
    const { results, context } = await kit.execute([
      { node: body.id, op: 'read' },
      { node: body.id, op: 'write', args: { text: 'Hi Wang, Tuesday works for me.' } },
      { node: later.id, op: 'press' },
      { node: send.id, op: 'press' },
      toCall('ui_act', { node: find(ctx.root, 'Interval').id, op: 'choose', args: { option: '1 min' } })!,
      { node: find(ctx.root, 'Password').id, op: 'read' },
    ]);
    expect(results.map((r) => r.ok)).toEqual([true, true, true, false, true, false]);
    expect(results[0]!.value).toBe('Hi Wang,\nsee you Tuesday.');
    expect(typed).toBe('Hi Wang, Tuesday works for me.');
    expect(pressed).toBe(1);
    expect(results[3]!.error).toContain('user does this themselves');
    expect(find(context.root, 'Interval').state).toMatchObject({ value: '1 min' });
    expect(find(context.root, 'Body').state).toMatchObject({ length: 30 });
  });

  it('asks before confirm ops, and offers app tools and routes', async () => {
    let asked = 0;
    const kit = new AffordKit({ isVisible: () => true, confirm: () => (asked++, false) });
    const later = document.getElementById('later')!;
    kit.register(later, { name: 'Archive', description: 'Archive this mail', policy: 'confirm' });
    let route = '/mail/inbox';
    kit.setRoutes({ current: () => route, routes: [{ path: '/settings/:tab', description: 'A settings page' }], navigate: (r) => void (route = r) });
    kit.registerTool({ name: 'insert_at_cursor', description: 'Insert text where the cursor is', execute: (a) => `inserted ${String(a.text)}` });
    const ctx = kit.context();
    expect(ctx.route).toEqual({ current: '/mail/inbox', routes: [{ path: '/settings/:tab', description: 'A settings page' }] });
    expect(ctx.tools.map((t) => t.name)).toEqual(['insert_at_cursor']);
    const archive = find(ctx.root, 'Archive');
    expect(archive.description).toBe('Archive this mail');
    const { results, context } = await kit.execute([{ node: archive.id, op: 'press' }, { tool: 'insert_at_cursor', args: { text: 'hi' } }, { navigate: '/settings/ai' }]);
    expect(asked).toBe(1);
    expect(results.map((r) => [r.ok, r.value ?? r.error])).toEqual([
      [false, 'The user said no'],
      [true, 'inserted hi'],
      [true, '/settings/ai'],
    ]);
    expect(context.route!.current).toBe('/settings/ai');
    expect(AGENT_TOOLS.map((t) => t.name)).toEqual(['ui_look', 'ui_act', 'ui_tool', 'ui_navigate', 'ui_peek', 'ui_handoff']);
  });

  it('shows each act before it runs (onAct): not reads, nor what its policy stops', async () => {
    const body = document.getElementById('body') as HTMLTextAreaElement;
    const seen: string[] = [];
    const kit = new AffordKit({ isVisible: () => true, onAct: ({ node, op, el }) => void seen.push(`${op} ${node.name} ${el.tagName} ${el === body ? body.value.length : '-'}`) });
    const ctx = kit.context();
    await kit.execute([
      { node: find(ctx.root, 'Later').id, op: 'press' },
      { node: find(ctx.root, 'Body').id, op: 'read' },
      { node: find(ctx.root, 'Body').id, op: 'write', args: { text: 'Tuesday works.' } },
      { node: find(ctx.root, 'Send').id, op: 'press' },
    ]);
    // (the write is shown before it is typed: the field still has the old text then)
    expect(seen).toEqual(['press Later BUTTON -', 'write Body TEXTAREA 25']);
    expect(body.value).toBe('Tuesday works.');
  });
});

describe('What the user does themselves (watchUser)', () => {
  const typeInto = (el: HTMLInputElement | HTMLTextAreaElement, text: string) => {
    for (let i = 1; i <= text.length; i++) {
      el.value = text.slice(0, i);
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }
  };

  it('notes their presses, typing (one entry per field), toggles and picks on the next answer, then forgets them', async () => {
    const kit = new AffordKit({ isVisible: () => true, skip: '.chat' });
    const ctx = kit.context();
    kit.watchUser(true);
    document.getElementById('later')!.click();
    typeInto(document.getElementById('body') as HTMLTextAreaElement, 'Friday instead?');
    (document.querySelector('input[type=checkbox]') as HTMLInputElement).click();
    const select = document.querySelector('select')!;
    select.value = '1';
    select.dispatchEvent(new Event('change', { bubbles: true }));
    // (not in the agent's own chat)
    typeInto(document.querySelector('.chat textarea') as HTMLTextAreaElement, 'stop');
    const answer = await kit.answer({ look: true });
    expect('userActions' in answer && answer.userActions!.map(({ op, node, value }) => [op, node?.role, node?.name, value])).toEqual([
      ['press', 'button', 'Later', undefined],
      ['write', 'textbox', 'Body', 'Friday instead?'],
      ['toggle', 'checkbox', 'Notify me', 'off'],
      ['select', 'select', 'Interval', '1 min'],
    ]);
    // The same node as the tree has it
    expect('userActions' in answer && answer.userActions![0]!.node!.id).toBe(find(ctx.root, 'Later').id);
    const again = await kit.answer({ look: true });
    expect('userActions' in again).toBe(false);
    kit.watchUser(false);
  });

  it("never notes the kit's own calls, nor anything while not watching, nor a password typed", async () => {
    const kit = new AffordKit({ isVisible: () => true });
    const ctx = kit.context();
    document.getElementById('later')!.click();
    kit.watchUser(true);
    const answer = await kit.answer({
      calls: [
        { node: find(ctx.root, 'Later').id, op: 'press' },
        { node: find(ctx.root, 'Body').id, op: 'write', args: { text: 'Tuesday works.' } },
        { node: find(ctx.root, 'Notify me').id, op: 'toggle' },
      ],
    });
    expect('results' in answer && answer.results!.every((r) => r.ok)).toBe(true);
    expect('userActions' in answer).toBe(false);
    // (and what they set off just after)
    document.getElementById('later')!.click();
    expect('userActions' in (await kit.answer({ look: true }))).toBe(false);
    await new Promise((r) => setTimeout(r, 320));
    typeInto(document.getElementById('pw') as HTMLInputElement, 'swordfish');
    const typed = await kit.answer({ look: true });
    expect('userActions' in typed && typed.userActions).toEqual([expect.objectContaining({ op: 'write', node: expect.objectContaining({ name: 'Password' }) })]);
    expect(JSON.stringify(typed)).not.toContain('swordfish');
    expect('userActions' in typed && 'value' in typed.userActions![0]!).toBe(false);
    // Off: forgotten, and nothing more
    document.getElementById('later')!.click();
    kit.watchUser(false);
    document.getElementById('later')!.click();
    expect('userActions' in (await kit.answer({ look: true }))).toBe(false);
  });

  it('notes a page the user went to (not one the kit went to), and an entry of a container by its key', async () => {
    document.body.innerHTML = `<main><ul data-afford-key="mail.list" data-afford-container="list"><li data-afford-item="42"><b>Lunch on Tuesday?</b></li><li data-afford-item="43">Invoice</li></ul></main>`;
    let route = '/mail/inbox';
    const kit = new AffordKit({ isVisible: () => true });
    kit.setRoutes({ current: () => route, routes: [{ path: '/mail/inbox', description: 'Inbox' }, { path: '/message/:id', description: 'A mail' }, { path: '/settings', description: 'Settings' }], navigate: (r) => void (route = r), settle: async () => {} });
    kit.context();
    kit.watchUser(true);
    await kit.answer({ calls: [{ navigate: '/settings' }] });
    route = '/mail/inbox';
    await new Promise((r) => setTimeout(r, 320));
    document.querySelector('b')!.click();
    route = '/message/42';
    const answer = await kit.answer({ look: true });
    expect('userActions' in answer && answer.userActions!.map(({ op, node, route }) => [op, node?.key, node?.role, route])).toEqual([
      ['navigate', undefined, undefined, '/mail/inbox'],
      ['press', 'mail.list[42]', 'listitem', '/message/42'],
      ['navigate', undefined, undefined, '/message/42'],
    ]);
    kit.watchUser(false);
  });
});
