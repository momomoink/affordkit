// The skill's references are copies of docs/ (a skill is often installed by copying its folder alone). Run after changing docs:
//   node scripts/sync-skill.mjs          copy docs/ into skills/affordkit/references/
//   node scripts/sync-skill.mjs --check  exit 1 if they differ
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const docs = path.join(root, 'docs');
const refs = path.join(root, 'skills/affordkit/references');
// Each platform's docs, and the protocol both share (the docs' own index pages are not needed: SKILL.md is the index)
const files = ['protocol.md', ...['flutter', 'js'].flatMap((p) => ['concepts.md', 'getting-started.md', 'what-to-expose.md', 'connecting-an-agent.md', 'handoffs.md'].map((f) => `${p}/${f}`))];
const check = process.argv.includes('--check');

// Links within docs/ stay as they are; links out of it point at the repository
const rewrite = (text, file) =>
  text.replace(/\]\((?!https?:|#)([^)]+)\)/g, (whole, href) => {
    const target = path.posix.normalize(path.posix.join(path.posix.dirname(file), href));
    return target.startsWith('../') ? `](https://github.com/momomoink/affordkit/blob/main/${target.replace(/^\.\.\//, '')})` : whole;
  });

const stale = [];
for (const f of files) {
  const want = rewrite(fs.readFileSync(path.join(docs, f), 'utf8'), f);
  const target = path.join(refs, f);
  const have = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : null;
  if (have === want) continue;
  stale.push(f);
  if (!check) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, want);
  }
}
// References no doc stands for any more
const listed = new Set(files.map((f) => path.join(refs, f)));
const walk = (d) => (fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)])) : []);
for (const f of walk(refs)) {
  if (listed.has(f)) continue;
  stale.push(path.relative(refs, f));
  if (!check) fs.rmSync(f);
}
if (check && stale.length) {
  console.error(`skills/affordkit/references is out of date: ${stale.join(', ')} (run node scripts/sync-skill.mjs)`);
  process.exit(1);
}
console.log(stale.length ? `${check ? 'Stale' : 'Updated'}: ${stale.join(', ')}` : 'References are up to date');
