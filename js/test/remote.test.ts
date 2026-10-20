// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest';
import { AffordRemote, anthropicResult, anthropicTools, mcpHandlers, openaiResult, openaiTools, runners, type ItemsPage, type UiRequest } from '../src/index.js';
import { AffordKit } from '../src/dom.js';

/** A compose page: a reply button that opens a form under it, and a send button the agent may not press. */
function page() {
  document.body.innerHTML = `
    <main data-afford="Mail" data-afford-key="mail">
      <button id="reply" data-afford-key="reply">Reply</button>
      <button id="send" data-afford-key="send" data-afford-policy="deny">Send</button>
      <div id="form"></div>
    </main>`;
  let sent = 0;
  document.getElementById('send')!.addEventListener('click', () => sent++);
  document.getElementById('reply')!.addEventListener('click', () => {
    document.getElementById('form')!.innerHTML = `<textarea data-afford-key="body" aria-label="Body"></textarea>`;
  });
  return { sent: () => sent };
}

describe('AffordRemote: the agent side over any transport', () => {
  it('looks, acts and answers with what changed on screen (not the whole tree), errors with a code', async () => {
    const p = page();
    const kit = new AffordKit({ isVisible: () => true });
    // (the "transport": JSON both ways, as over a socket)
    const sent: UiRequest[] = [];
    const ui = new AffordRemote({
      send: async (r) => {
        sent.push(r);
        return JSON.parse(JSON.stringify(await kit.answer(JSON.parse(JSON.stringify(r)))));
      },
    });
    expect(ui.tools().map((t) => t.name)).toEqual(['ui_look', 'ui_act', 'ui_tool', 'ui_navigate', 'ui_peek']);

    const look = await ui.handle('ui_look');
    expect(look.isError).toBe(false);
    expect(look.text).toContain('key=reply] button "Reply"');
    // The app has no tools of its own: once seen, ui_tool isn't offered
    expect(ui.has('ui_tool')).toBe(false);

    const reply = await ui.handle('ui_act', { node: 'reply', op: 'press' });
    expect(reply.isError).toBe(false);
    expect(reply.text).toMatch(/^Done\.\n\nThe screen changed:\n\+ \[\S+ key=body\] textbox "Body"/);
    expect(reply.text).not.toContain('"Send"');

    const again = await ui.handle('ui_act', { node: 'body', op: 'read' });
    expect(again.text).toContain('The screen did not change.');

    const send = await ui.handle('ui_act', { node: 'send', op: 'press' });
    expect([send.isError, send.code]).toEqual([true, 'denied']);
    expect(send.text).toMatch(/^Failed \(denied\)/);
    expect(p.sent()).toBe(0);
    const gone = await ui.handle('ui_act', { node: 'nope', op: 'press' });
    expect(gone.code).toBe('not_found');
    const noOp = await ui.handle('ui_act', { node: 'reply', op: 'fly' });
    expect(noOp.code).toBe('no_op');
    expect((await ui.handle('ui_fly')).code).toBe('bad_args');
    // (a tool that isn't one never reaches the app)
    expect(sent.length).toBe(6);
  });

  it('times out with a code, and the whole screen each time when asked to', async () => {
    const slow = new AffordRemote({ send: () => new Promise(() => {}), timeoutMs: 20 });
    expect(await slow.handle('ui_look')).toMatchObject({ isError: true, code: 'timeout' });
    const down = new AffordRemote({ send: async () => ({ error: 'No app', code: 'unavailable' }) });
    expect((await down.handle('ui_look')).text).toBe('Failed (unavailable): No app');

    page();
    const whole = new AffordKit({ isVisible: () => true }).agent({ screen: 'whole' });
    await whole.handle('ui_look');
    const after = await whole.handle('ui_act', { node: 'reply', op: 'press' });
    expect(after.text).toContain('The screen now:');
    expect(after.text).toContain('"Send"');
  });

  it('the tools in each stack\'s shape, and the answers back in it', async () => {
    page();
    const ui = new AffordKit({ isVisible: () => true }).agent();
    const [look] = anthropicTools(ui.tools());
    expect(look).toEqual({ name: 'ui_look', description: expect.any(String), input_schema: { type: 'object', properties: { picture: { type: 'boolean', description: 'Also a picture of the screen' } } } });
    expect(openaiTools(ui.tools())[1]!.function.name).toBe('ui_act');

    const block = await anthropicResult(ui, { id: 'tu1', name: 'ui_act', input: { node: 'send', op: 'press' } });
    expect(block).toMatchObject({ type: 'tool_result', tool_use_id: 'tu1', is_error: true });
    const msg = await openaiResult(ui, { id: 'c1', function: { name: 'ui_look', arguments: '{}' } });
    expect(msg).toMatchObject({ role: 'tool', tool_call_id: 'c1' });
    expect(msg.content).toContain('Reply');

    const mcp = mcpHandlers(ui);
    expect((await mcp.list()).tools.map((t) => t.name)).toContain('ui_navigate');
    const called = await mcp.call({ params: { name: 'ui_act', arguments: { node: 'reply', op: 'press' } } });
    expect(called.isError).toBeUndefined();
    const first = called.content[0]!;
    expect(first.type).toBe('text');
    expect(first.type === 'text' ? first.text : '').toContain('The screen changed:');
    expect((await runners(ui)[0]!.run({})).isError).toBe(false);
  });
});

describe('a virtualized list with no items given: searched by scrolling through it', () => {
  it('finds an entry far down, leaves it showing for item, and scrolls back after items', async () => {
    const mails = Array.from({ length: 300 }, (_, i) => `Mail ${i} from ${['Wang', 'Li', 'Zhao'][i % 3]}`);
    document.body.innerHTML = `<div id="box" style="overflow-y: auto"></div>`;
    const box = document.getElementById('box')!;
    // 20 px rows, 200 px high, only the rows in view (and 2 more) rendered
    Object.defineProperty(box, 'clientHeight', { get: () => 200 });
    Object.defineProperty(box, 'scrollHeight', { get: () => mails.length * 20 });
    let top = 0;
    Object.defineProperty(box, 'scrollTop', { get: () => top, set: (v: number) => (top = Math.max(0, Math.min(v, mails.length * 20 - 200))) });
    const render = () => {
      const first = Math.floor(top / 20);
      box.innerHTML = mails
        .slice(first, first + 12)
        .map((m, k) => `<div data-afford-item="m${first + k}" data-afford-index="${first + k}" role="listitem">${m}</div>`)
        .join('');
    };
    box.addEventListener('scroll', render);
    render();
    const kit = new AffordKit({ isVisible: () => true });
    kit.registerContainer(box, { key: 'mail.list', name: 'Inbox' });
    top = 400;
    render();

    const { results } = await kit.execute([
      { node: 'mail.list', op: 'items', args: { query: 'mail 250' } },
      { node: 'mail.list', op: 'items', args: { query: 'zhao 1', limit: 3 } },
    ]);
    expect(results.map((r) => r.error ?? 'ok')).toEqual(['ok', 'ok']);
    expect((results[0]!.value as ItemsPage).items.map((i) => [i.key, i.index])).toEqual([['mail.list[m250]', 250]]);
    expect((results[1]!.value as ItemsPage).items.map((i) => i.id)).toEqual(['m11', 'm14', 'm17']);
    // (back where it was)
    expect(top).toBe(400);

    const item = await kit.execute([{ node: 'mail.list', op: 'item', args: { query: 'Mail 270' } }]);
    expect(item.results[0]!.error).toBeUndefined();
    expect(box.textContent).toContain('Mail 270');
  });
});
