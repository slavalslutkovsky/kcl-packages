/**
 * The benchmark matrix: which function runtimes to start, and which
 * Compositions to make them render.
 *
 * Everything here is data. `main.ts` owns the flow, `request.ts` turns a
 * (runtime, scenario, phase) triple into a RunFunctionRequest.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseAllDocuments } from 'yaml';

export type RuntimeId = 'kcl' | 'kclx' | 'python';

export interface Runtime {
  id: RuntimeId;
  label: string;
  /** How the input is encoded — KCL runtimes take a module path, python a script. */
  flavour: 'kcl' | 'python';
  image: string;
  containerName: string;
  hostPort: number;
  /** Appended after the image in `docker run`, i.e. the function's own argv. */
  extraArgs: string[];
  env?: Record<string, string>;
  /** Forced `--platform`, when the image has no arm64 manifest. */
  platform?: string;
}

export interface Scenario {
  id: string;
  label: string;
  /** Example XR, parsed and passed as `observed.composite.resource`. */
  xrPath: string;
  /** KCL module the KCL runtimes read out of the mounted workspace. */
  kclPackage: string;
  /** Python port of the same Composition, absent when there is none. */
  pythonScript?: string;
  /**
   * Injected as `status` on the observed `managed` resource in the `observed`
   * phase, so the Composition's status-plumbing path is exercised too.
   */
  observedStatus?: Record<string, unknown>;
}

/**
 * The image the cluster would run, so the benchmark measures the real pin.
 *
 * `tools/nx-kcl` reads the same field with a regex because it has to rewrite
 * the manifest byte-for-byte; here a plain parse is both shorter and stricter,
 * and it keeps this package free of a dependency on that CommonJS tree.
 */
function pinnedKclImage(repoRoot: string): string {
  const manifest = join(repoRoot, 'packages/cloud/bucket/xrd/functions.yaml');
  const docs = parseAllDocuments(readFileSync(manifest, 'utf-8'));
  for (const doc of docs) {
    const fn = doc.toJS() as { metadata?: { name?: string }; spec?: { package?: string } } | null;
    if (fn?.metadata?.name === 'function-kcl' && fn.spec?.package) return fn.spec.package;
  }
  throw new Error(`Could not read the function-kcl image pin from ${manifest}`);
}

export function runtimes(repoRoot: string): Runtime[] {
  return [
    {
      id: 'kcl',
      label: 'function-kcl (upstream, Go + KCL)',
      flavour: 'kcl',
      image: pinnedKclImage(repoRoot),
      containerName: 'bench-fn-kcl',
      hostPort: 19443,
      extraArgs: ['--insecure'],
    },
    {
      id: 'kclx',
      label: 'kclx (this repo, Rust + embedded KCL)',
      flavour: 'kcl',
      // Built by `just kclx-image`; the bench recipe depends on that target.
      image: 'function-kclx-runtime:dev',
      containerName: 'bench-fn-kclx',
      hostPort: 19444,
      extraArgs: ['--insecure'],
    },
    {
      id: 'python',
      label: 'function-python (upstream, Python)',
      flavour: 'python',
      image: 'ghcr.io/crossplane-contrib/function-python:v0.5.0',
      containerName: 'bench-fn-python',
      hostPort: 19445,
      extraArgs: ['--insecure'],
    },
  ];
}

export const SCENARIOS: Scenario[] = [
  {
    id: 'bucket-aws',
    label: 'Bucket (aws) — 11 composed S3 resources',
    xrPath: 'packages/cloud/bucket/xrd/examples/bucket-aws.yaml',
    kclPackage: 'packages/cloud/bucket/aws',
    pythonScript: 'tools/bench/scripts/bucket_aws.py',
    observedStatus: {
      atProvider: {
        id: 'my-bucket',
        arn: 'arn:aws:s3:::my-bucket',
        region: 'us-east-1',
        bucketRegionalDomainName: 'my-bucket.s3.us-east-1.amazonaws.com',
      },
    },
  },
  {
    id: 'appstack-aws',
    label: 'AppStack (aws) — 5 composed child XRs',
    xrPath: 'packages/platform/appstack/xrd/examples/appstack-aws.yaml',
    kclPackage: 'packages/platform/appstack/stack',
  },
];

/** Request phases: a first reconcile, then one with observed composed state. */
export const PHASES = ['initial', 'observed'] as const;
export type Phase = (typeof PHASES)[number];
