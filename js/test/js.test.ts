// @vitest-environment happy-dom
// From plain JavaScript: the package as built (dist/*.js), used without types.
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const pkg = path.resolve(here, '..');

// Built as the package ships (dist/, the same as pnpm build)
beforeAll(() => {
  const tsc = path.join(path.dirname(createRequire(path.join(pkg, 'package.json')).resolve('typescript/package.json')), 'bin/tsc');
  execFileSync(process.execPath, [tsc, '-p', path.join(pkg, 'tsconfig.build.json')]);
}, 60_000);

describe('AffordKit from plain JS', () => {
  it('the built modules load and work, with plain objects', async () => {
    const { AffordKit } = await import(/* @vite-ignore */ path.join(pkg, 'dist/dom.js'));
    const { describe: describeTree, AGENT_TOOLS, toCall } = await import(/* @vite-ignore */ path.join(pkg, 'dist/index.js'));
    document.body.innerHTML = `<ul data-afford-container="list" data-afford-key="todo"><li data-afford-item="a">Milk</li><li data-afford-item="b">Bread</li></ul><button data-afford-key="add">Add</button>`;
    let added = 0;
    document.querySelector('button')!.addEventListener('click', () => added++);
    const kit = new AffordKit({ isVisible: () => true });
    kit.registerTool({ name: 'hello', description: 'Says hi', execute: () => 'hi' });
    expect(describeTree(kit.context())).toContain('container (list) 2 entries, showing 0–1 (entry keys: todo[<id>])');
    const { results } = await kit.execute([toCall('ui_act', { node: 'add', op: 'press' }), { tool: 'hello' }, { node: 'todo', op: 'items' }]);
    expect(results.map((r: { ok: boolean }) => r.ok)).toEqual([true, true, true]);
    expect(added).toBe(1);
    expect(results[2].value.items.map((i: { key: string }) => i.key)).toEqual(['todo[a]', 'todo[b]']);
    expect(AGENT_TOOLS.map((t: { name: string }) => t.name)).toContain('ui_peek');
  });
});
