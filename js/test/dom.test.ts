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
    expect(AGENT_TOOLS.map((t) => t.name)).toEqual(['ui_look', 'ui_act', 'ui_tool', 'ui_navigate', 'ui_peek']);
  });
});
