/**
 * Turns the `tsc` output in `dist/tools/nx-kcl` into a self-contained,
 * publishable npm package.
 *
 * `tsc` only emits JS/d.ts. Nx resolves generators, executors and their JSON
 * schemas through relative paths in `generators.json` / `executors.json`, so
 * those manifests and every `*schema*.json` under `src/` have to be copied
 * next to the emitted JS. The source `package.json` stays `private` and points
 * at TypeScript (that is what the in-repo workspace link and the
 * `./tools/nx-kcl/src/index.ts` plugin entry use); the published one is
 * generated here and points at the built JS.
 */
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const workspaceRoot = resolve(packageRoot, '../..');
const distRoot = join(workspaceRoot, 'dist/tools/nx-kcl');

if (!existsSync(join(distRoot, 'src/index.js'))) {
  console.error(
    `prepare-dist: ${relative(workspaceRoot, join(distRoot, 'src/index.js'))} is missing — run tsc first.`,
  );
  process.exit(1);
}

const source = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));

/** Every non-TS asset Nx needs at runtime: the two manifests plus all schemas. */
const rootAssets = ['generators.json', 'executors.json', 'README.md'];
for (const asset of rootAssets) {
  cpSync(join(packageRoot, asset), join(distRoot, asset));
}

let schemas = 0;
const copyJson = (dir) => {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const from = join(dir, entry.name);
    if (entry.isDirectory()) {
      copyJson(from);
    } else if (entry.name.endsWith('.json')) {
      const to = join(distRoot, relative(packageRoot, from));
      mkdirSync(dirname(to), { recursive: true });
      cpSync(from, to);
      schemas++;
    }
  }
};
copyJson(join(packageRoot, 'src'));

// The package name is load-bearing: inferred targets reference executors as
// `nx-kcl:publish` / `nx-kcl:remove` / `nx-kcl:render` (see src/create-nodes.ts),
// which Nx resolves by requiring `nx-kcl` from the consumer's node_modules.
writeFileSync(
  join(distRoot, 'package.json'),
  JSON.stringify(
    {
      name: source.name,
      version: source.version,
      description: 'Nx plugin for KCL packages: inferred build/test/lint targets, OCI publishing and nx release integration.',
      keywords: ['nx', 'nx-plugin', 'kcl', 'kcl-lang', 'crossplane', 'oci'],
      repository: {
        type: 'git',
        url: 'git+https://github.com/slavalslutkovsky/kcl-packages.git',
        directory: 'tools/nx-kcl',
      },
      main: './src/index.js',
      types: './src/index.d.ts',
      generators: './generators.json',
      executors: './executors.json',
      dependencies: {
        '@nx/devkit': '^23.0.0',
      },
      peerDependencies: {
        nx: '^23.0.0',
      },
    },
    null,
    2,
  ) + '\n',
);

console.log(
  `prepare-dist: ${relative(workspaceRoot, distRoot)} ready (${rootAssets.length} manifests, ${schemas} schemas).`,
);
