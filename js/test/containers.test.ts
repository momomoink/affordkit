// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest';
import { describe as describeTree, describeResult, type AffordNode, type ItemsPage, type ItemTree } from '../src/index.js';
import { AffordKit } from '../src/dom.js';

const all = (n: AffordNode): AffordNode[] => [n, ...(n.children ?? []).flatMap(all)];
const byKey = (root: AffordNode, key: string) => all(root).find((n) => n.key === key);

/** A virtualized mail list: 1000 mails, 10 rows built at a time, each with a star and a reply button. */
function mailList() {
  const mails = Array.from({ length: 1000 }, (_, i) => ({ id: `m${i}`, subject: `Mail ${i}` }));
  const box = document.createElement('div');
  document.body.replaceChildren(box);
  let start = 0;
  const starred: string[] = [];
  const replied: string[] = [];
  const opened: string[] = [];
  const render = () => {
    box.innerHTML = mails
      .slice(start, start + 10)
      .map((m, k) => `<div class="row" data-id="${m.id}" data-index="${start + k}"><span>${m.subject}</span> <button data-afford-key="star">Star</button> <button data-afford-key="reply">Reply</button></div>`)
      .join('');
    for (const row of box.querySelectorAll<HTMLElement>('.row')) {
      row.addEventListener('click', () => opened.push(row.dataset.id!));
      const [star, reply] = row.querySelectorAll('button');
      star!.addEventListener('click', (e) => (e.stopPropagation(), starred.push(row.dataset.id!)));
      reply!.addEventListener('click', (e) => (e.stopPropagation(), replied.push(row.dataset.id!)));
    }
  };
  render();
  const kit = new AffordKit({ isVisible: () => true });
  let scrolls = 0;
  kit.registerContainer(box, {
    key: 'mail.list',
    name: 'Inbox',
    kind: 'list',
    itemId: (el) => (el as HTMLElement).dataset.id,
    indexOf: (el) => Number((el as HTMLElement).dataset.index),
    count: () => mails.length,
    items: ({ offset, limit, query }) =>
      mails
        .filter((m) => !query || m.subject.includes(query))
        .slice(offset, offset + limit)
        .map((m) => ({ id: m.id, name: m.subject })),
    scrollTo: ({ id, index }) => {
      scrolls++;
      const at = index ?? mails.findIndex((m) => m.id === id);
      if (at < 0) return; // (no such mail: stays put)
      start = at;
      render();
    },
  });
  return { kit, starred, replied, opened, scrolls: () => scrolls };
}

describe('AffordKit containers', () => {
  it('a container is one node with a preview; fetching an entry gives its tree, acted on next round', async () => {
    const { kit, replied } = mailList();
    const ctx = kit.context();
    const list = byKey(ctx.root, 'mail.list')!;
    expect(list).toMatchObject({ role: 'container', name: 'Inbox', state: { kind: 'list', count: 1000, first: 0, last: 9 } });
    // Not the rows' controls: a preview of them
    expect(list.children).toBeUndefined();
    expect(byKey(ctx.root, 'mail.list[m3].reply')).toBeUndefined();
    expect(list.preview).toHaveLength(10);
    expect(list.preview![3]).toEqual({ key: 'mail.list[m3]', id: 'm3', index: 3, name: 'Mail 3 Star Reply' });
    const text = describeTree(ctx);
    expect(text).toContain('container "Inbox" (list) 1000 entries, showing 0–9 (entry keys: mail.list[<id>]) — read, item, items, scroll_to, scroll');
    expect(text).toContain('· [mail.list[m3]] #3 "Mail 3 Star Reply"');
    expect(text).toContain('990 more; op item fetches');

    // Round 1: fetch entry 42 (not built: scrolled to) — a tree of its own
    const first = await kit.execute([{ node: 'mail.list', op: 'item', args: { id: 'm42' } }]);
    const item = first.results[0]!.value as ItemTree;
    expect(item).toMatchObject({ key: 'mail.list[m42]', id: 'm42', index: 42, source: 'live' });
    expect(item.root).toMatchObject({ role: 'listitem', key: 'mail.list[m42]' });
    const reply = item.root.children!.find((n) => n.key === 'mail.list[m42].reply')!;
    expect(reply).toMatchObject({ role: 'button', name: 'Reply' });
    expect(describeResult(first.results[0]!)).toContain('Entry mail.list[m42] #42:');
    expect(describeResult(first.results[0]!)).toContain('key=mail.list[m42].reply] button "Reply"');
    // (the next round's tree is still the container alone)
    expect(byKey(first.context.root, 'mail.list[m42].reply')).toBeUndefined();

    // Round 2: press its reply by the id the fetch gave
    const second = await kit.execute([{ node: reply.id, op: 'press' }]);
    expect(second.results[0]!.error ?? 'ok').toBe('ok');
    expect(replied).toEqual(['m42']);
  });

  it('entries by index and query, paging all of them, and keys acted on straight away (fetched first) — one round', async () => {
    const { kit, starred, opened, scrolls } = mailList();
    const { results, context } = await kit.execute([
      { node: 'mail.list', op: 'items', args: { offset: 995, limit: 20 } },
      { node: 'mail.list', op: 'item', args: { index: 7 } },
      { node: 'mail.list', op: 'item', args: { query: 'Mail 123' } },
      { node: 'mail.list[m500].star', op: 'press' },
      { node: 'mail.list[m501]', op: 'press' },
      { node: 'mail.list[m2000]', op: 'press' },
      { node: 'mail.list', op: 'item', args: { id: 'mail.list[m3]' } },
    ]);
    expect(results.map((r) => r.ok)).toEqual([true, true, true, true, true, false, true]);
    const page = results[0]!.value as ItemsPage;
    expect(page.count).toBe(1000);
    expect(page.items.map((i) => [i.key, i.index])).toEqual([995, 996, 997, 998, 999].map((i) => [`mail.list[m${i}]`, i]));
    expect((results[1]!.value as ItemTree).key).toBe('mail.list[m7]');
    expect((results[2]!.value as ItemTree).key).toBe('mail.list[m123]');
    expect(starred).toEqual(['m500']);
    expect(opened).toEqual(['m501']); // (built already after m500: no second scroll)
    expect((results[6]!.value as ItemTree).id).toBe('m3');
    expect(scrolls()).toBe(4); // m123, m500, the try for m2000, m3 (m7 and m501 were built already)
    expect(byKey(context.root, 'mail.list')!.state).toMatchObject({ first: 3, last: 12 });
  });

  it('DOM containers as marked: data-afford-container entries, controls between them, a long <ol> by itself, a short <ul> stays a list; nested containers', async () => {
    document.body.innerHTML = `
      <div data-afford-container="thread" data-afford-key="thread" aria-label="Thread">
        <button data-afford-key="older">Show older</button>
        <article data-afford-item="a">From Wang <button data-afford-key="reply">Reply</button>
          <ul data-afford-container="list" data-afford-key="files"><li data-afford-item="1">plan.pdf <button data-afford-key="open">Open</button></li></ul>
        </article>
        <article data-afford-item="b">From Li <button data-afford-key="reply">Reply</button></article>
      </div>
      <ul aria-label="Nav"><li><a href="#in">Inbox</a></li><li><a href="#out">Sent</a></li></ul>
      <ol data-afford-key="log">${Array.from({ length: 30 }, (_, i) => `<li>Line ${i}</li>`).join('')}</ol>`;
    const opened: string[] = [];
    document.querySelector('[data-afford-key="open"]')!.addEventListener('click', () => opened.push('plan.pdf'));
    const scrolled = vi.fn();
    (document.querySelectorAll('article')[1] as HTMLElement).scrollIntoView = scrolled;
    const kit = new AffordKit({ isVisible: () => true });
    const { root } = kit.context();
    const thread = byKey(root, 'thread')!;
    expect(thread).toMatchObject({ role: 'container', state: { kind: 'thread', count: 2, first: 0, last: 1 } });
    expect(thread.children!.map((n) => n.key)).toEqual(['older']); // (what is in it besides its entries)
    expect(thread.preview!.map((p) => p.key)).toEqual(['thread[a]', 'thread[b]']);
    expect(all(root).find((n) => n.name === 'Nav')).toMatchObject({ role: 'list' });
    expect(all(root).filter((n) => n.role === 'link')).toHaveLength(2);
    expect(byKey(root, 'log')).toMatchObject({ role: 'container', state: { kind: 'list', count: 30 } });
    expect(byKey(root, 'log')!.preview).toHaveLength(10);

    const { results } = await kit.execute([
      { node: 'thread', op: 'item', args: { id: 'a' } },
      { node: 'thread[a].files[1].open', op: 'press' },
      { node: 'thread', op: 'scroll_to', args: { item: 'thread[b]' } },
      { node: 'log', op: 'item', args: { index: 25 } },
    ]);
    expect(results.map((r) => r.error ?? 'ok')).toEqual(['ok', 'ok', 'ok', 'ok']);
    const a = (results[0]!.value as ItemTree).root;
    expect(all(a).map((n) => [n.role, n.key])).toEqual([
      ['listitem', 'thread[a]'],
      ['button', 'thread[a].reply'],
      ['container', 'thread[a].files'],
    ]);
    expect(all(a).find((n) => n.key === 'thread[a].files')!.preview![0]!.key).toBe('thread[a].files[1]');
    expect(opened).toEqual(['plan.pdf']);
    expect(scrolled).toHaveBeenCalled();
    expect((results[3]!.value as ItemTree).root).toMatchObject({ key: 'log[25]', name: 'Line 25' });
  });

  it('an entry built off screen for a preview (ids not live), and the errors', async () => {
    document.body.innerHTML = `<div id="box"></div>`;
    const box = document.getElementById('box')!;
    const kit = new AffordKit({ isVisible: () => true });
    let disposed = 0;
    kit.registerContainer(box, {
      key: 'cards',
      count: () => 3,
      build: ({ id }) => {
        if (id !== 'x') return null;
        const root = document.createElement('div');
        root.innerHTML = `<section data-afford-item="x">Card X <button data-afford-key="pin">Pin</button></section>`;
        return { root, dispose: () => void disposed++ };
      },
    });
    const { results } = await kit.execute([
      { node: 'cards', op: 'item', args: { id: 'x', preview: true } },
      { node: 'cards', op: 'item', args: { id: 'y' } },
      { node: 'cards', op: 'item', args: {} },
    ]);
    const x = results[0]!.value as ItemTree;
    expect(x).toMatchObject({ key: 'cards[x]', source: 'preview' });
    expect(all(x.root).every((n) => n.id.startsWith('peek:'))).toBe(true);
    expect(all(x.root).map((n) => n.key)).toEqual(['cards[x]', 'cards[x].pin']);
    expect(describeResult(results[0]!)).toContain('built off screen');
    expect(disposed).toBe(1);
    expect(results[1]!.error).toContain('No entry y');
    expect(results[2]!.error).toContain('Say which entry');
  });
});
