import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'cybros-ts-package-'));
function run(command: [string, ...string[]], cwd = temporary) {
  const [executable, ...args] = command;
  const result = spawnSync(executable, args, { cwd, encoding: 'utf8' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command.join(' ')}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}
try {
  run(['pnpm', 'pack', '--pack-destination', temporary], root);
  const archive = (await readdir(temporary)).find(name => name.endsWith('.tgz'));
  if (!archive) throw new Error('Package tarball missing');
  const installed = join(temporary, 'node_modules/@cybros/agent'); await mkdir(installed, { recursive: true });
  run(['tar', '-xzf', join(temporary, archive), '--strip-components=1', '-C', installed]);
  const contents = await readdir(installed);
  if (contents.sort().join(',') !== 'LICENSE,README.md,dist,package.json') throw new Error('Unexpected published package contents');
  if (await readFile(join(installed, 'LICENSE'), 'utf8') !== await readFile(resolve(root, '../../LICENSE.md'), 'utf8')) throw new Error('Published license differs from repository license');
  const metadata = JSON.parse(await readFile(join(installed, 'package.json'), 'utf8'));
  if (metadata.repository?.url !== 'https://github.com/jasl/cybros.ai.git' || metadata.repository?.directory !== 'sdks/typescript') throw new Error('Published repository metadata missing');
  await writeFile(join(temporary, 'package.json'), JSON.stringify({ type: 'module' }));
  await writeFile(join(temporary, 'smoke.mjs'), "import { Client, ExecutorClient, PlatformClient, Steps } from '@cybros/agent';\nif (![Client,ExecutorClient,PlatformClient].every(value => typeof value === 'function') || !Steps.tool({name:'read'}).tool) throw new Error('Package export missing');\n");
  run([process.execPath, 'smoke.mjs']);
  await symlink(join(root, 'node_modules/ws'), join(temporary, 'node_modules/ws'));
  await writeFile(join(temporary, 'runtime.mjs'), await readFile(join(root, 'test/runtime.mjs'), 'utf8'));
  run([process.execPath, '--test', 'runtime.mjs']);
  const guide = await readFile(resolve(root, '../../guides/build/sdk-typescript.md'), 'utf8');
  const example = [...guide.matchAll(/```ts\n([\s\S]*?)```/g)].map(match => match[1]).join('\n');
  if (!example) throw new Error('Guide has no TypeScript example');
  await writeFile(join(temporary, 'guide.ts'), example);
  await writeFile(join(temporary, 'consumer.ts'), await readFile(join(root, 'examples/server.ts'), 'utf8'));
  await writeFile(join(temporary, 'standalone-agent.ts'), await readFile(join(root, 'examples/standalone-agent.ts'), 'utf8'));
  await symlink(join(root, 'node_modules/@types'), join(temporary, 'node_modules/@types'));
  await writeFile(join(temporary, 'tsconfig.json'), JSON.stringify({ compilerOptions: { target: 'ES2022', module: 'NodeNext', moduleResolution: 'NodeNext', strict: true, exactOptionalPropertyTypes: true, noUncheckedIndexedAccess: true, noEmit: true, types: ['node'], lib: ['ES2022', 'DOM', 'DOM.Iterable'] }, include: ['*.ts'] }));
  run([process.execPath, join(root, 'node_modules/typescript/bin/tsc'), '-p', join(temporary, 'tsconfig.json')]);
  console.log('Packed package imports without ws; native HTTP/realtime tests pass; exported declarations and public guide compile.');
} finally { await rm(temporary, { recursive: true, force: true }); }
