// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest';
import { AffordRemote, anthropicResult, describeChange, mcpHandlers, type AffordContext, type AffordNode } from '../src/index.js';
import { AffordKit } from '../src/dom.js';

const node = (id: string, role: AffordNode['role'], name: string, extra: Partial<AffordNode> = {}): AffordNode => ({ id, role, name, ops: [], ...extra });
const ctx = (route: string, children: AffordNode[]): AffordContext => ({ protocol: 1, route: { current: route, routes: [] }, tools: [], root: node('app', 'app', '', { children }) });

describe('what the agent reads and sees', () => {
  it('a dialog over the page: the page goes under it, said in one line, not each control again; closed, it is on top again', () => {
    const controls = [node('w1', 'button', 'Archive'), node('w2', 'button', 'Delete')];
    const before = ctx('/mail/1', controls);
    const after = ctx('/mail/1', [node('w9', 'button', 'Sure?'), node('behind-1', 'page', '/mail/1', { state: { behind: true }, children: controls })]);
    const opened = describeChange(before, after);
    expect(opened).toContain('+ [w9] button "Sure?"');
    expect(opened).toContain('+ [behind-1] page "/mail/1" (behind) — now under what shows: its 2 controls still work, unseen');
    expect(opened).not.toContain('Archive');
    const closed = describeChange(after, before);
    expect(closed).toContain('- [behind-1] page "/mail/1" — on top again: its controls show');
    expect(closed).toContain('- [w9] button "Sure?"');
  });

  it('a text shows its words in the tree, a field only its length', async () => {
    document.body.innerHTML = `<main><h2>Inbox</h2><div role="status" data-afford="Summary">3 new mails from Wang about the trip</div><input aria-label="Body" value="secret draft"></main>`;
    const kit = new AffordKit({ isVisible: () => true });
    const text = (await kit.agent().handle('ui_look')).text;
    expect(text).not.toContain('secret draft');
    expect(text).toContain('textbox "Body" (length: 12)');
    const all = JSON.stringify(kit.context());
    expect(all).toContain('"value":"3 new mails from Wang about the trip"');
  });

  it('a picture goes beside the text, to the stacks that take one', async () => {
    const png = 'iVBORw0KGgo=';
    const ui = new AffordRemote({
      send: async (r) =>
        'calls' in r
          ? { results: [{ call: r.calls[0]!, ok: true, value: { type: 'image', mime: 'image/png', data: png, width: 40, height: 30 } }], context: ctx('/', []) }
          : { context: ctx('/', []), ...(r.picture ? { picture: { type: 'image' as const, mime: 'image/png', data: png } } : {}) },
    });
    const seen = await ui.handle('ui_look', { picture: true });
    expect(seen.images).toEqual([{ mime: 'image/png', data: png }]);
    expect(seen.text).toContain('(A picture of the screen is attached.)');
    const viewed = await anthropicResult(ui, { id: 't', name: 'ui_act', input: { node: 'logo', op: 'view' } });
    expect(viewed.content).toEqual([
      { type: 'text', text: expect.stringContaining('(A picture, 40×30 image/png: attached.)') },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: png } },
    ]);
    const m = await mcpHandlers(ui).call({ params: { name: 'ui_act', arguments: { node: 'logo', op: 'view' } } });
    expect(m.content[1]).toEqual({ type: 'image', data: png, mimeType: 'image/png' });
  });
});
