import { Tree, logger } from '@nx/devkit';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';

export interface CompositionGeneratorSchema {
  name: string;
  providers?: string[];
  group?: string;
  version?: string;
  directory?: string;
  registry?: string;
}

type Tier = 'standard' | 'nearline' | 'cold' | 'archive';

type StorageClass =
  | { kind: 'field'; field: string; map: Record<Tier, string> }
  | {
      // S3 has no bucket-level storage class: express tiers via a separate
      // BucketLifecycleConfiguration MR that transitions objects to a class.
      kind: 's3lifecycle';
      map: Partial<Record<Tier, [storageClass: string, days: number]>>;
      lifecycleFields: string[];
    }
  | {
      // Azure account accessTier covers standard..cold but has no Archive;
      // emit a ManagementPolicy MR to tier blobs to Archive for the listed tiers.
      kind: 'azureTier';
      field: string;
      map: Record<Tier, string>;
      archiveDays: Partial<Record<Tier, number>>;
    };

interface Backend {
  apiVersion: string;
  kind: string;
  /** Schema package name to look for (created via nx-kcl:import-crd). */
  schemaPackage: string;
  /** KCL lines (8-space indent) setting the managed resource's spec fields. */
  fields: string[];
  /** How the abstract spec.storageClass maps to this provider, if supported. */
  storageClass?: StorageClass;
}

const BACKENDS: Record<string, Backend> = {
  aws: {
    apiVersion: 's3.aws.m.upbound.io/v1beta1',
    kind: 'Bucket',
    schemaPackage: 'aws-s3',
    fields: ['        spec.forProvider.region = oxr.spec.region'],
    storageClass: {
      kind: 's3lifecycle',
      map: { nearline: ['STANDARD_IA', 30], cold: ['GLACIER_IR', 90], archive: ['DEEP_ARCHIVE', 180] },
      lifecycleFields: ['        spec.forProvider.region = oxr.spec.region'],
    },
  },
  gcp: {
    apiVersion: 'storage.gcp.m.upbound.io/v1beta1',
    kind: 'Bucket',
    schemaPackage: 'gcp-storage',
    fields: ['        spec.forProvider.location = oxr.spec.region'],
    storageClass: {
      kind: 'field',
      field: 'spec.forProvider.storageClass',
      map: { standard: 'STANDARD', nearline: 'NEARLINE', cold: 'COLDLINE', archive: 'ARCHIVE' },
    },
  },
  azure: {
    apiVersion: 'storage.azure.m.upbound.io/v1beta1',
    kind: 'Account',
    schemaPackage: 'azure-storage',
    fields: [
      '        spec.forProvider.location = oxr.spec.region',
      '        spec.forProvider.accountTier = "Standard"',
      '        spec.forProvider.accountReplicationType = "LRS"',
    ],
    storageClass: {
      kind: 'azureTier',
      field: 'spec.forProvider.accessTier',
      map: { standard: 'Hot', nearline: 'Cool', cold: 'Cold', archive: 'Cold' },
      archiveDays: { archive: 180 },
    },
  },
  rustfs: {
    // rustfs is S3-compatible: reuse the aws-s3 schema + a rustfs ProviderConfig.
    apiVersion: 's3.aws.m.upbound.io/v1beta1',
    kind: 'Bucket',
    schemaPackage: 'aws-s3',
    fields: [
      '        spec.providerConfigRef.kind = "ProviderConfig"',
      '        spec.providerConfigRef.name = "rustfs"',
      '        spec.forProvider.region = "us-east-1"',
    ],
    storageClass: {
      kind: 's3lifecycle',
      map: { nearline: ['STANDARD_IA', 30], cold: ['GLACIER_IR', 90], archive: ['DEEP_ARCHIVE', 180] },
      lifecycleFields: [
        '        spec.providerConfigRef.kind = "ProviderConfig"',
        '        spec.providerConfigRef.name = "rustfs"',
        '        spec.forProvider.region = "us-east-1"',
      ],
    },
  },
};

const RN = 'metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}';

function pascal(name: string): string {
  return name
    .split(/[-_]/)
    .filter(Boolean)
    .map((p) => p[0].toUpperCase() + p.slice(1))
    .join('');
}

/** Find a KCL package by its kcl.mod name; return its workspace-relative root. */
function findSchemaPackage(tree: Tree, pkgName: string): string | null {
  let found: string | null = null;
  const walk = (dir: string) => {
    if (found) return;
    for (const child of tree.children(dir)) {
      if (found) return;
      if (child === 'node_modules' || child.startsWith('.')) continue;
      const path = dir ? `${dir}/${child}` : child;
      if (tree.isFile(path)) {
        if (child === 'kcl.mod') {
          const contents = tree.read(path, 'utf-8') ?? '';
          if (new RegExp(`^name\\s*=\\s*"${pkgName}"`, 'm').test(contents)) {
            found = dir;
          }
        }
      } else {
        walk(path);
      }
    }
  };
  walk('');
  return found;
}

/** Find the generated schema module (e.g. models.v1beta2.storage_gcp_..._bucket). */
function discoverSchemaModule(
  schemaRootAbs: string,
  kind: string,
  apiVersion: string
): string | null {
  const modelsDir = join(schemaRootAbs, 'models');
  let entries: string[];
  try {
    entries = readdirSync(modelsDir, { recursive: true }) as string[];
  } catch {
    return null;
  }
  const needleSchema = `schema ${kind}:`;
  for (const entry of entries) {
    const rel = String(entry).replace(/\\/g, '/');
    if (!rel.endsWith('.k')) continue;
    const contents = readFileSync(join(modelsDir, rel), 'utf-8');
    if (contents.includes(needleSchema) && contents.includes(`"${apiVersion}"`)) {
      return `models.${rel.slice(0, -2).replace(/\//g, '.')}`;
    }
  }
  return null;
}

function typedRenderModule(opts: {
  name: string;
  provider: string;
  backend: Backend;
  importPath: string; // e.g. gcp_storage.models.v1beta1.storage_..._bucket
  companionImport?: string | null; // companion MR module (s3lifecycle / azureTier)
}): string {
  const { backend } = opts;
  const head = [
    `# ${opts.name} (${opts.provider}) — Crossplane Composition logic (function-kcl module).`,
    `# Typed against the ${backend.schemaPackage} schema package.`,
    `import ${opts.importPath} as backend`,
  ];
  const sc = backend.storageClass;

  if (sc?.kind === 's3lifecycle' && opts.companionImport) {
    const transition =
      '{' +
      Object.entries(sc.map)
        .map(([t, v]) => `"${t}" = {storageClass = "${v[0]}", days = ${v[1]}}`)
        .join(', ') +
      '}';
    return [
      ...head,
      `import ${opts.companionImport} as lifecycle`,
      ``,
      `# S3 has no bucket-level storage class: map the abstract tier to an object`,
      `# lifecycle transition on a companion BucketLifecycleConfiguration MR.`,
      `_transition = ${transition}`,
      ``,
      `render = lambda oxr {`,
      `    _items: [any] = [backend.${backend.kind} {`,
      `        ${RN}`,
      ...backend.fields,
      `    }]`,
      `    _sc = oxr.spec?.storageClass`,
      `    if _sc and _sc in _transition:`,
      `        _t = _transition[_sc]`,
      `        _items += [lifecycle.BucketLifecycleConfiguration {`,
      `            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "lifecycle"}`,
      ...sc.lifecycleFields.map((l) => '    ' + l),
      `            spec.forProvider.bucketSelector.matchControllerRef = True`,
      `            spec.forProvider.$rule = [{`,
      `                id = "storage-class"`,
      `                status = "Enabled"`,
      `                $filter = [{}]`,
      `                transition = [{days = _t.days, storageClass = _t.storageClass}]`,
      `            }]`,
      `        }]`,
      `    _items`,
      `}`,
      ``,
    ].join('\n');
  }

  if (sc?.kind === 'field') {
    const map =
      '{' +
      Object.entries(sc.map)
        .map(([t, v]) => `"${t}" = "${v}"`)
        .join(', ') +
      '}';
    return [
      ...head,
      ``,
      `# Abstract storage tier -> ${opts.provider} native value.`,
      `_storage_class = ${map}`,
      ``,
      `render = lambda oxr {`,
      `    [backend.${backend.kind} {`,
      `        ${RN}`,
      ...backend.fields,
      `        if oxr.spec?.storageClass:`,
      `            ${sc.field} = _storage_class[oxr.spec.storageClass]`,
      `    }]`,
      `}`,
      ``,
    ].join('\n');
  }

  if (sc?.kind === 'azureTier') {
    const tierMap =
      '{' +
      Object.entries(sc.map)
        .map(([t, v]) => `"${t}" = "${v}"`)
        .join(', ') +
      '}';
    const daysMap =
      '{' +
      Object.entries(sc.archiveDays)
        .map(([t, v]) => `"${t}" = ${v}`)
        .join(', ') +
      '}';
    const setTier = [
      `        if oxr.spec?.storageClass:`,
      `            ${sc.field} = _access_tier[oxr.spec.storageClass]`,
    ];
    if (opts.companionImport) {
      return [
        ...head,
        `import ${opts.companionImport} as policy`,
        ``,
        `# Azure accessTier has no account-level Archive: tier blobs to Archive`,
        `# via a companion ManagementPolicy MR for the deepest tier(s).`,
        `_access_tier = ${tierMap}`,
        `_archive_days = ${daysMap}`,
        ``,
        `render = lambda oxr {`,
        `    _items: [any] = [backend.${backend.kind} {`,
        `        ${RN}`,
        ...backend.fields,
        ...setTier,
        `    }]`,
        `    _sc = oxr.spec?.storageClass`,
        `    if _sc and _sc in _archive_days:`,
        `        _items += [policy.ManagementPolicy {`,
        `            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "lifecycle"}`,
        `            spec.forProvider.storageAccountIdSelector.matchControllerRef = True`,
        `            spec.forProvider.$rule = [{`,
        `                name = "archive"`,
        `                enabled = True`,
        `                filters = {blobTypes = ["blockBlob"]}`,
        `                actions = {baseBlob = {tierToArchiveAfterDaysSinceModificationGreaterThan = _archive_days[_sc]}}`,
        `            }]`,
        `        }]`,
        `    _items`,
        `}`,
        ``,
      ].join('\n');
    }
    return [
      ...head,
      ``,
      `_access_tier = ${tierMap}`,
      ``,
      `render = lambda oxr {`,
      `    [backend.${backend.kind} {`,
      `        ${RN}`,
      ...backend.fields,
      ...setTier,
      `    }]`,
      `}`,
      ``,
    ].join('\n');
  }

  return [
    ...head,
    ``,
    `render = lambda oxr {`,
    `    [backend.${backend.kind} {`,
    `        ${RN}`,
    ...backend.fields,
    `    }]`,
    `}`,
    ``,
  ].join('\n');
}

function inlineRenderModule(opts: {
  name: string;
  provider: string;
  backend: Backend;
}): string {
  const { backend } = opts;
  const head = [
    `# ${opts.name} (${opts.provider}) — Crossplane Composition logic (function-kcl module).`,
    `# Untyped fallback. Run \`nx g nx-kcl:import-crd ${backend.schemaPackage} --image=<provider-image>\``,
    `# then regenerate to get typed, default-aware schemas.`,
  ];
  const sc = backend.storageClass;
  if (sc?.kind === 'field' || sc?.kind === 'azureTier') {
    const map =
      '{' +
      Object.entries(sc.map)
        .map(([t, v]) => `"${t}" = "${v}"`)
        .join(', ') +
      '}';
    return [
      ...head,
      ``,
      `_storage_class = ${map}`,
      ``,
      `render = lambda oxr {`,
      `    [{`,
      `        apiVersion = "${backend.apiVersion}"`,
      `        kind = "${backend.kind}"`,
      `        ${RN}`,
      ...backend.fields,
      `        if oxr.spec?.storageClass:`,
      `            ${sc.field} = _storage_class[oxr.spec.storageClass]`,
      `    }]`,
      `}`,
      ``,
    ].join('\n');
  }
  return [
    ...head,
    ``,
    `render = lambda oxr {`,
    `    [{`,
    `        apiVersion = "${backend.apiVersion}"`,
    `        kind = "${backend.kind}"`,
    `        ${RN}`,
    ...backend.fields,
    `    }]`,
    `}`,
    ``,
  ].join('\n');
}

function mainModule(modId: string): string {
  return [
    `import .${modId}`,
    ``,
    `# function-kcl injects option("params"); fall back to an example for local runs.`,
    `_example = {metadata.name = "example", spec = {region = "us-central1"}}`,
    `_params = option("params") or {oxr = _example}`,
    `items = ${modId}.render(_params.oxr)`,
    ``,
  ].join('\n');
}

function testModule(modId: string, backend: Backend): string {
  const sc = backend.storageClass;
  const lines = [
    `import .${modId}`,
    ``,
    `test_render = lambda {`,
    `    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}`,
    `    items = ${modId}.render(oxr)`,
    `    assert len(items) == 1, "expected one managed resource"`,
    `    assert items[0].apiVersion == "${backend.apiVersion}"`,
    `    assert items[0].kind == "${backend.kind}"`,
    `}`,
    ``,
  ];

  if (sc?.kind === 'field') {
    lines.push(
      `test_storage_class = lambda {`,
      `    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}`,
      `    items = ${modId}.render(oxr)`,
      `    assert items[0].${sc.field} == "${sc.map.archive}", "archive -> ${sc.map.archive}"`,
      `}`,
      ``,
      `test_render()`,
      `test_storage_class()`,
      ``,
    );
    return lines.join('\n');
  }

  if (sc?.kind === 'azureTier') {
    lines.push(
      `test_storage_class = lambda {`,
      `    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}`,
      `    items = ${modId}.render(oxr)`,
      `    assert len(items) == 2, "expected account + management policy"`,
      `    assert items[1].kind == "ManagementPolicy"`,
      `    assert items[0].${sc.field} == "${sc.map.archive}", "archive accessTier -> ${sc.map.archive}"`,
      `}`,
      ``,
      `test_render()`,
      `test_storage_class()`,
      ``,
    );
    return lines.join('\n');
  }

  if (sc?.kind === 's3lifecycle') {
    lines.push(
      `test_storage_class = lambda {`,
      `    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}`,
      `    items = ${modId}.render(oxr)`,
      `    assert len(items) == 2, "expected bucket + lifecycle config"`,
      `    assert items[1].kind == "BucketLifecycleConfiguration"`,
      `}`,
      ``,
      `test_render()`,
      `test_storage_class()`,
      ``,
    );
    return lines.join('\n');
  }

  lines.push(`test_render()`, ``);
  return lines.join('\n');
}

function compositionYaml(opts: {
  name: string;
  provider: string;
  group: string;
  version: string;
  kind: string;
  source: string;
}): string {
  return [
    `apiVersion: apiextensions.crossplane.io/v1`,
    `kind: Composition`,
    `metadata:`,
    `  name: ${opts.name}-${opts.provider}`,
    `  labels:`,
    `    provider: ${opts.provider}`,
    `spec:`,
    `  compositeTypeRef:`,
    `    apiVersion: ${opts.group}/${opts.version}`,
    `    kind: ${opts.kind}`,
    `  mode: Pipeline`,
    `  pipeline:`,
    `    - step: render`,
    `      functionRef:`,
    `        name: function-kcl`,
    `      input:`,
    `        apiVersion: krm.kcl.dev/v1alpha1`,
    `        kind: KCLInput`,
    `        spec:`,
    `          # Pin a release with ?tag=<version> once published via \`nx release\`.`,
    `          source: ${opts.source}`,
    `    - step: ready`,
    `      functionRef:`,
    `        name: function-auto-ready`,
    ``,
  ].join('\n');
}

function xrdYaml(opts: { group: string; version: string; kind: string; plural: string }): string {
  return [
    `apiVersion: apiextensions.crossplane.io/v2`,
    `kind: CompositeResourceDefinition`,
    `metadata:`,
    `  name: ${opts.plural}.${opts.group}`,
    `spec:`,
    `  scope: Namespaced`,
    `  group: ${opts.group}`,
    `  names:`,
    `    kind: ${opts.kind}`,
    `    plural: ${opts.plural}`,
    `  versions:`,
    `    - name: ${opts.version}`,
    `      served: true`,
    `      referenceable: true`,
    `      schema:`,
    `        openAPIV3Schema:`,
    `          type: object`,
    `          properties:`,
    `            spec:`,
    `              type: object`,
    `              properties:`,
    `                region:`,
    `                  type: string`,
    `                  description: Cloud region/location for the ${opts.kind}.`,
    `                storageClass:`,
    `                  type: string`,
    `                  enum: [standard, nearline, cold, archive]`,
    `                  default: standard`,
    `                  description: Abstract storage tier (portable across providers); mapped to each cloud's native value.`,
    `              required:`,
    `                - region`,
    `            status:`,
    `              type: object`,
    `              properties:`,
    `                ready:`,
    `                  type: boolean`,
    ``,
  ].join('\n');
}

function functionsYaml(): string {
  return [
    `apiVersion: pkg.crossplane.io/v1`,
    `kind: Function`,
    `metadata:`,
    `  name: function-kcl`,
    `spec:`,
    `  package: xpkg.upbound.io/crossplane-contrib/function-kcl:latest`,
    `---`,
    `apiVersion: pkg.crossplane.io/v1`,
    `kind: Function`,
    `metadata:`,
    `  name: function-auto-ready`,
    `spec:`,
    `  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:latest`,
    ``,
  ].join('\n');
}

function exampleXr(opts: { group: string; version: string; kind: string; provider: string }): string {
  return [
    `apiVersion: ${opts.group}/${opts.version}`,
    `kind: ${opts.kind}`,
    `metadata:`,
    `  namespace: default`,
    `  name: my-${opts.kind.toLowerCase()}`,
    `spec:`,
    `  region: us-central1`,
    `  storageClass: archive   # standard | nearline | cold | archive (optional, default standard)`,
    `  crossplane:`,
    `    compositionSelector:`,
    `      matchLabels:`,
    `        provider: ${opts.provider}   # the flag: picks the backend`,
    ``,
  ].join('\n');
}

/**
 * Scaffold a shared Crossplane v2 XRD plus one function-kcl Composition package
 * per provider. Each provider package uses the typed schemas from its schema
 * package (created via nx-kcl:import-crd) when present, falling back to untyped
 * dicts otherwise.
 */
export default async function compositionGenerator(
  tree: Tree,
  options: CompositionGeneratorSchema
) {
  const { name } = options;
  const providers =
    options.providers && options.providers.length > 0
      ? options.providers
      : ['aws', 'gcp', 'azure', 'rustfs'];
  const group = options.group ?? 'cloud.example.org';
  const version = options.version ?? 'v1alpha1';
  const directory = options.directory ?? 'packages/cloud';
  const registry = (options.registry ?? 'oci://ghcr.io/your-org').replace(/\/+$/, '');
  const kind = pascal(name);
  const plural = `${name.toLowerCase()}s`;
  const modId = name.replace(/[^a-zA-Z0-9_]/g, '_');
  const resourceRoot = join(directory, name);

  for (const provider of providers) {
    if (!BACKENDS[provider]) throw new Error(`Unknown provider "${provider}".`);
    if (tree.exists(join(resourceRoot, provider, 'kcl.mod'))) {
      throw new Error(`A package already exists at "${join(resourceRoot, provider)}".`);
    }
  }

  // Shared XRD (the abstract API).
  tree.write(join(resourceRoot, 'xrd', 'xrd.yaml'), xrdYaml({ group, version, kind, plural }));
  tree.write(join(resourceRoot, 'xrd', 'functions.yaml'), functionsYaml());
  tree.write(
    join(resourceRoot, 'xrd', 'examples', `${name}-${providers[0]}.yaml`),
    exampleXr({ group, version, kind, provider: providers[0] })
  );

  // Per-provider Composition packages. Resolve typed schema package up front so
  // we can wire the path dependency in the post-generation step.
  const pathDeps: Record<string, string> = {};
  for (const provider of providers) {
    const backend = BACKENDS[provider];
    const pkgRoot = join(resourceRoot, provider);

    const schemaRoot = findSchemaPackage(tree, backend.schemaPackage);
    let typedImport: string | null = null;
    let companionImport: string | null = null;
    if (schemaRoot) {
      const modulePath = discoverSchemaModule(
        join(tree.root, schemaRoot),
        backend.kind,
        backend.apiVersion
      );
      if (modulePath) {
        const alias = backend.schemaPackage.replace(/-/g, '_');
        typedImport = `${alias}.${modulePath}`;
        pathDeps[provider] = relative(join(tree.root, pkgRoot), join(tree.root, schemaRoot));
        const companionKind =
          backend.storageClass?.kind === 's3lifecycle'
            ? 'BucketLifecycleConfiguration'
            : backend.storageClass?.kind === 'azureTier'
            ? 'ManagementPolicy'
            : null;
        if (companionKind) {
          const companionPath = discoverSchemaModule(
            join(tree.root, schemaRoot),
            companionKind,
            backend.apiVersion
          );
          if (companionPath) companionImport = `${alias}.${companionPath}`;
        }
      }
    }

    tree.write(
      join(pkgRoot, `${modId}.k`),
      typedImport
        ? typedRenderModule({ name, provider, backend, importPath: typedImport, companionImport })
        : inlineRenderModule({ name, provider, backend })
    );
    tree.write(join(pkgRoot, 'main.k'), mainModule(modId));
    tree.write(join(pkgRoot, `${modId}_test.k`), testModule(modId, backend));
    tree.write(
      join(pkgRoot, 'composition.yaml'),
      compositionYaml({ name, provider, group, version, kind, source: `${registry}/${name}-${provider}` })
    );
  }

  return () => {
    for (const provider of providers) {
      const pkgAbs = join(tree.root, resourceRoot, provider);
      try {
        execFileSync('kcl', ['mod', 'init'], { cwd: pkgAbs, stdio: 'inherit' });
        const modPath = join(pkgAbs, 'kcl.mod');
        const contents = readFileSync(modPath, 'utf-8');
        writeFileSync(
          modPath,
          contents.replace(/^name\s*=\s*".*"/m, `name = "${name}-${provider}"`)
        );
        const dep = pathDeps[provider];
        if (dep) {
          // Typed: depend on the schema package (and k8s, which its schemas import).
          execFileSync('kcl', ['mod', 'add', dep], { cwd: pkgAbs, stdio: 'inherit' });
          execFileSync('kcl', ['mod', 'add', 'k8s'], { cwd: pkgAbs, stdio: 'inherit' });
          // Local path deps must NOT pin a version. The schema package is
          // versioned independently; a pinned version breaks the moment it is
          // bumped (`package 'X:0.0.1' not found`). kcl resolves a path dep
          // from disk regardless of version, so drop the pin.
          const mod = readFileSync(modPath, 'utf-8');
          writeFileSync(
            modPath,
            mod.replace(
              /(\{\s*path\s*=\s*"[^"]*")\s*,\s*version\s*=\s*"[^"]*"\s*(\})/g,
              '$1 $2'
            )
          );
        }
      } catch {
        logger.warn(`Wrote sources for ${name}/${provider}, but \`kcl mod\` setup failed.`);
      }
    }
    const typed = Object.keys(pathDeps);
    logger.info(`✅ Scaffolded ${kind} XRD + ${providers.length} Composition package(s) under ${resourceRoot}.`);
    if (typed.length > 0) logger.info(`   Typed against schema packages: ${typed.join(', ')}`);
    const untyped = providers.filter((p) => !pathDeps[p]);
    if (untyped.length > 0) {
      logger.info(`   Untyped (no schema package found): ${untyped.join(', ')}.`);
      logger.info(`   Create one, e.g.: nx g nx-kcl:import-crd ${BACKENDS[untyped[0]].schemaPackage} --image=<provider-image>`);
    }
  };
}
