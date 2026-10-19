// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest';
import { describe as describeTree, describePage, findRoute, matchRoute, type AffordNode, type PagePeek, type RouteSpec } from '../src/index.js';
import { AffordKit } from '../src/dom.js';

const all = (n: AffordNode): AffordNode[] => [n, ...(n.children ?? []).flatMap(all)];

/** A tiny app: two pages and a router with history. */
function app() {
  const pages: Record<string, string> = {
    '/mail/inbox': `<main aria-label="Inbox"><button data-afford-key="mail.compose">Compose</button><ul><li>Lunch?</li><li>Invoice</li></ul></main>`,
    '/settings/ai': `<main aria-label="AI settings"><select data-afford-key="ai.model" aria-label="Model"><option>Claude</option><option>Qwen</option></select>
      <label><input type="checkbox" data-afford-key="ai.tagging"> Tag new mail</label></main>`,
  };
  const render = (route: string, into: Element) => (into.innerHTML = pages[route] ?? '<main aria-label="Not found"></main>');
  const history = ['/mail/inbox'];
  render(history[0]!, document.body);
  const routes: RouteSpec[] = [
    { path: '/mail/:folder', description: 'A mail folder', params: { folder: { values: ['inbox', 'sent', 'junk'] } } },
    { path: '/settings/:tab', description: 'A settings page', params: { tab: { values: ['general', 'ai'] } } },
  ];
  const kit = new AffordKit({ isVisible: () => true });
  const go = (route: string) => {
    history.push(route);
    render(route, document.body);
  };
  return { kit, routes, history, go, render };
}

describe('AffordKit routes', () => {
  it('matches routes to patterns', () => {
    expect(matchRoute('/settings/:tab', '/settings/ai')).toEqual({ tab: 'ai' });
    expect(matchRoute('/settings/:tab', '/settings/ai/more')).toBeNull();
    expect(matchRoute('/files/*', '/files/a/b')).toEqual({});
    expect(findRoute([{ path: '/m/:id', description: '' }, { path: '/m/new', description: '' }], '/m/new')!.spec.path).toBe('/m/new');
  });

  it('says where the user is; peeks at a page before going; navigates and acts there by key in one round; goes back', async () => {
    const { kit, routes, history, go, render } = app();
    kit.setRoutes({
      current: () => history.at(-1)!,
      routes,
      navigate: go,
      back: () => (history.pop(), render(history.at(-1)!, document.body)),
      canGoBack: () => history.length > 1,
    });
    const ctx = kit.context();
    expect(ctx.route).toMatchObject({ current: '/mail/inbox', pattern: '/mail/:folder', params: { folder: 'inbox' }, canGoBack: false });
    expect(describeTree(ctx)).toContain(':tab ∈ {general, ai}');
    expect(describeTree(ctx)).toContain('key=mail.compose');

    // Never seen: only what the route says
    const before = await kit.peek('/settings/ai');
    expect(before).toMatchObject({ source: 'declared', pattern: '/settings/:tab', description: 'A settings page' });
    expect(before.root).toBeUndefined();

    // Go there and back: now it has been seen; a peek shows its controls (ids not live, keys usable)
    await kit.execute([{ navigate: '/settings/ai' }, { navigate: 'back' }]);
    const { results } = await kit.execute([{ peek: '/settings/ai' }]);
    const seen = results[0]!.value as PagePeek;
    expect(seen.source).toBe('seen');
    const model = all(seen.root!).find((n) => n.key === 'ai.model')!;
    expect(model.id.startsWith('peek:')).toBe(true);
    expect(describePage(seen)).toContain('navigate there, then act by key');

    // A peek id can't be acted on; a plan by key can: go, choose, toggle — one round
    const refused = await kit.execute([{ node: model.id, op: 'read' }]);
    expect(refused.results[0]!.error).toContain('navigate to the page first');
    const done = await kit.execute([
      { navigate: '/settings/ai' },
      { node: 'ai.model', op: 'choose', args: { option: 'Qwen' } },
      { node: 'ai.tagging', op: 'set', args: { on: true } },
    ]);
    expect(done.results.map((r) => r.ok)).toEqual([true, true, true]);
    expect((document.querySelector('select') as HTMLSelectElement).value).toBe('Qwen');
    expect((document.querySelector('input[type=checkbox]') as HTMLInputElement).checked).toBe(true);
    expect(done.context.route).toMatchObject({ current: '/settings/ai', canGoBack: true });

    // Unknown routes and nowhere back
    const bad = await kit.execute([{ navigate: '/nope' }]);
    expect(bad.results[0]!.error).toContain('No route /nope');
  });

  it('peeks by building the page off screen when the app can, and keeps what it saw across runs', async () => {
    const { kit, routes, history, go, render } = app();
    let disposed = 0;
    kit.setRoutes({
      current: () => history.at(-1)!,
      routes,
      navigate: go,
      preview: (route) => {
        const root = document.createElement('div');
        render(route, root);
        return { root, dispose: () => void disposed++ };
      },
    });
    const view = await kit.peek('/settings/ai');
    expect(view.source).toBe('preview');
    expect(all(view.root!).map((n) => n.key).filter(Boolean)).toEqual(['ai.model', 'ai.tagging']);
    expect(disposed).toBe(1);
    // The user's page wasn't touched
    expect(document.body.textContent).toContain('Lunch?');

    // Snapshots: kept by one run, known to the next
    kit.context();
    const saved = JSON.parse(JSON.stringify(kit.snapshots()));
    const next = new AffordKit({ isVisible: () => true });
    next.loadSnapshots(saved);
    next.setRoutes({ current: () => '/settings/ai', routes, navigate: () => {} });
    expect((await next.peek('/mail/inbox')).source).toBe('seen');
    // Another route of the same pattern: as that pattern last looked
    expect((await next.peek('/mail/sent')).source).toBe('seen');
  });
});
