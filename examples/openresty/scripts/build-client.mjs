// build-client.mjs — Ratatoskr stage-2 builder for the BROWSER.
//
//   node build-client.mjs <shaken-dir> <out.js>
//
// Like ShenScript's own bin/ratatoskr-build.js, but instead of emitting a
// Node "run once and exit" program, it emits a browser ES module that
// compiles the shaken kernel+user slice ahead of time and EXPORTS an async
// `createValidator()` returning a plain (name, message) -> string[] function
// ([] means valid). runtime.js and overrides.js are pure (no node imports),
// so the output is self-contained and runs in any modern browser with no
// ShenScript checkout and no npm install.
//
// Normally invoked via build-client.sh, which runs the Ratatoskr shake first.
// Needs a ShenScript checkout (env SHENSCRIPT_DIR, default ../ShenScript next
// to this repo) for the ahead-of-time compile step only.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [shakenDir, outPath] = process.argv.slice(2);
if (!shakenDir || !outPath) {
  console.error('usage: node build-client.mjs <shaken-dir> <out.js>');
  process.exit(1);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../..');          // examples/openresty/scripts -> repo root
const SS = process.env.SHENSCRIPT_DIR || path.resolve(repoRoot, '../ShenScript');
if (!fs.existsSync(path.join(SS, 'lib', 'backend.js'))) {
  console.error(`ShenScript not found at ${SS} (set SHENSCRIPT_DIR)`);
  process.exit(1);
}
const lib = f => pathToFileURL(path.join(SS, 'lib', f)).href;
const backend = (await import(lib('backend.js'))).default;
const { parseFile } = await import(pathToFileURL(path.join(SS, 'scripts', 'parser.js')).href);
const { Arrow, Block, Call, Const, Id, Let, Program, Return, Statement, generate } =
  await import(lib('ast.js'));

// ---- manifest -------------------------------------------------------------
const manifest = { user: [] };
for (const line of fs.readFileSync(path.join(shakenDir, 'ratatoskr.manifest.txt'), 'utf-8').split('\n')) {
  const t = line.trim(); if (!t) continue;
  const eq = t.indexOf('='); if (eq < 0) continue;
  const k = t.slice(0, eq), v = t.slice(eq + 1);
  if (Array.isArray(manifest[k])) manifest[k].push(v); else manifest[k] = v;
}
if (manifest['needs-eval'] === 'true') {
  console.error('needs-eval=true: this browser builder only handles eval-stripped slices');
  process.exit(1);
}

// ---- compile the slice ahead of time (same pipeline as bin/ratatoskr-build.js)
const $ = backend();
const { assemble, construct, isArray, s } = $;
const parseKl = file => parseFile(fs.readFileSync(path.join(shakenDir, file), 'utf-8'));
const kernelForms = parseKl(manifest.kernel);
const userForms = manifest.user.flatMap(parseKl);

const body = assemble(
  Block,
  ...kernelForms.filter(isArray).map(construct),
  Call(Id('overrides'), [Id('$')]),
  assemble(Statement, construct([s`${manifest.init}`])),
  ...userForms.filter(isArray).map(construct));

const program = generate(Program([
  Const(Id('run'), Arrow([Id('$')], Block(
    Let(Id('w$')),                                   // maybe-await slot (see lib/backend.js)
    ...Object.entries(body.subs).map(([k, v]) => Const(Id(k), v)),
    ...body.ast.body,
    Return(Id('$'))), true))]));

// ---- emit a browser module ------------------------------------------------
const embed = (file, rename) =>
  fs.readFileSync(path.join(SS, 'lib', file), 'utf-8')
    .replace(/^import .*$/gm, '')
    .replace(/^export default/m, `const ${rename} =`)
    .replace(/^export (class|const)/gm, '$1');

const artifact = `// GENERATED — do not edit. Built by examples/openresty/scripts/build-client.{sh,mjs}
// from rules.shen (+ client.glue.shen) via Ratatoskr (Shen tree-shaker) and
// ShenScript's compiler. Regenerate with: examples/openresty/scripts/build-client.sh
// kernel defuns: ${kernelForms.length}; user: ${manifest.user.join(', ')}; needs-eval: ${manifest['needs-eval']}
// Self-contained: runtime.js + overrides.js are embedded; no imports, no checkout needed at runtime.
${embed('runtime.js', 'runtime')}
${embed('overrides.js', 'overrides')}
${program}

// A pure validator needs no real I/O; *stoutput* stays a raise-thunk (never hit).
export async function createValidator() {
  const $ = runtime({ implementation: 'ShenScript', release: 'shaken', os: 'browser', port: 'openresty-demo' });
  await run($);
  const cell = $.lookup('check-fields');
  // check-fields : string -> string -> (list string); [] means valid.
  // Shen functions may trampoline/await, so settle (and await) before reading.
  return async (name, message) => $.toArray(await $.settle(cell.f(name, message)));
}
`;
fs.writeFileSync(outPath, artifact);
console.log(`${path.relative(process.cwd(), outPath)}: ${artifact.length} bytes, ` +
  `${kernelForms.length} kernel forms, ${userForms.length} user forms`);
