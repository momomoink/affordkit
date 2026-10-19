// The skill's references are copies of docs/ (a skill is often installed by copying its folder alone). Run after changing docs:
//   node scripts/sync-skill.mjs          copy docs/*.md into skills/affordkit/references/
//   node scripts/sync-skill.mjs --check  exit 1 if they differ
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const docs = path.join(root, 'docs');
const refs = path.join(root, 'skills/affordkit/references');
const files = ['concepts.md', 'getting-started-web.md', 'getting-started-flutter.md', 'what-to-expose.md', 'connecting-an-agent.md', 'protocol.md'];
const check = process.argv.includes('--check');

// Links between docs stay as they are; links out of docs/ point at the repository
const rewrite = (text) => text.replace(/\]\(\.\.\/([^)]+)\)/g, '](https://github.com/momomoink/affordkit/blob/main/$1)');

fs.mkdirSync(refs, { recursive: true });
let stale = [];
for (const f of files) {
  const want = rewrite(fs.readFileSync(path.join(docs, f), 'utf8'));
  const target = path.join(refs, f);
  const have = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : null;
  if (have === want) continue;
  stale.push(f);
  if (!check) fs.writeFileSync(target, want);
}
if (check && stale.length) {
  console.error(`skills/affordkit/references is out of date: ${stale.join(', ')} (run node scripts/sync-skill.mjs)`);
  process.exit(1);
}
console.log(stale.length ? `${check ? 'Stale' : 'Updated'}: ${stale.join(', ')}` : 'References are up to date');
