/**
 * Benchmark the Crossplane composition-function runtimes this repo can choose
 * between, on the Compositions this repo actually ships.
 *
 *   node tools/bench/src/main.ts [--iterations 100] [--warmup 5]
 *                               [--only kcl,kclx,python] [--scenario bucket-aws]
 *                               [--out tools/bench/out] [--no-gate] [--keep]
 *
 * Each runtime renders every scenario twice: once as a first reconcile (no
 * observed composed resources) and once with the composed state fed back, which
 * is the path a Composition's status plumbing runs on. Latency is measured on
 * the gRPC RunFunction call, so no CLI, YAML parsing or process spawn is in the
 * sample. Resource footprint comes from `docker stats` streamed alongside the
 * measured loop, and behavioural equivalence from diffing the desired state
 * against upstream function-kcl.
 */
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { cpus, totalmem } from 'node:os';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import {
  collectStats,
  imageInfo,
  logs,
  pullIfMissing,
  removeContainer,
  serverVersion,
  snapshotStats,
  startFunction,
} from './docker.ts';
import type { StatsSummary } from './docker.ts';
import { connectFunction, runFunction, waitForReady } from './client.ts';
import type { FunctionClient, Result, RunFunctionResponse, State } from './client.ts';
import { buildRequest, observedFrom, readXr } from './request.ts';
import { canonical, diffText, stripEmptyMetadata } from './normalize.ts';
import type { Json } from './struct.ts';
import { PHASES, SCENARIOS, runtimes } from './scenarios.ts';
import type { Phase, Runtime, RuntimeId, Scenario } from './scenarios.ts';
import type { Cell, Latency, Results } from './results.ts';
import { renderHtml } from './report.ts';

const PROTO = 'tools/bench/proto/run_function.proto';
/** Behavioural equivalence is measured against this runtime. */
const REFERENCE: RuntimeId = 'kcl';

function percentile(sorted: number[], q: number): number {
  if (!sorted.length) return 0;
  const idx = Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1);
  return sorted[Math.max(0, idx)];
}

function summarize(samplesMs: number[]): Latency {
  const sorted = [...samplesMs].sort((a, b) => a - b);
  const mean = sorted.reduce((a, b) => a + b, 0) / (sorted.length || 1);
  return {
    n: sorted.length,
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    p99: percentile(sorted, 0.99),
    mean,
    min: sorted[0] ?? 0,
    max: sorted[sorted.length - 1] ?? 0,
    rps: mean > 0 ? 1000 / mean : 0,
  };
}

function fatal(results: Result[] | undefined): Result | undefined {
  return (results ?? []).find((r) => r.severity === 'SEVERITY_FATAL');
}

interface MeasureArgs {
  client: FunctionClient;
  runtime: Runtime;
  scenario: Scenario;
  phase: Phase;
  repoRoot: string;
  xr: Record<string, unknown>;
  observedResources?: State['resources'];
  iterations: number;
  warmup: number;
}

interface Measured {
  cell: Cell;
  response: RunFunctionResponse;
}

async function measure(args: MeasureArgs): Promise<Measured> {
  const request = buildRequest({
    repoRoot: args.repoRoot,
    runtime: args.runtime,
    scenario: args.scenario,
    phase: args.phase,
    xr: args.xr,
    observedResources: args.observedResources,
  });

  // The first call carries module load and — for the KCL runtimes — dependency
  // resolution, so it is reported separately instead of skewing the loop.
  const first = await runFunction(args.client, request);
  const blocker = fatal(first.response.results);
  if (blocker) {
    throw new Error(
      `${args.runtime.id}/${args.scenario.id}/${args.phase}: function returned a fatal result: ` +
        `${blocker.message}\n${logs(args.runtime.containerName, 20)}`
    );
  }
  for (let i = 0; i < args.warmup; i++) await runFunction(args.client, request);

  const stats = collectStats(args.runtime.containerName);
  const samplesMs: number[] = [];
  let last = first.response;
  for (let i = 0; i < args.iterations; i++) {
    const sample = await runFunction(args.client, request);
    samplesMs.push(Number(sample.elapsedNs) / 1e6);
    last = sample.response;
  }
  const footprint = stats.stop();

  const shape = canonical(last);
  const status = shape.compositeStatus;
  return {
    response: last,
    cell: {
      runtime: args.runtime.id,
      scenario: args.scenario.id,
      phase: args.phase,
      latency: summarize(samplesMs),
      firstCallMs: Number(first.elapsedNs) / 1e6,
      responseBytes: JSON.stringify(last).length,
      resourceCount: Object.keys(shape.resources).length,
      resourceNames: Object.keys(shape.resources),
      ready: [...new Set(Object.values(shape.ready))].sort(),
      statusKeys: status && typeof status === 'object' && !Array.isArray(status) ? Object.keys(status) : [],
      results: shape.results,
      footprint,
      equivalence: null,
      canonical: shape,
    },
  };
}

async function main(): Promise<number> {
  const { values } = parseArgs({
    options: {
      iterations: { type: 'string', default: '100' },
      warmup: { type: 'string', default: '5' },
      only: { type: 'string' },
      scenario: { type: 'string', multiple: true },
      out: { type: 'string', default: 'tools/bench/out' },
      'no-gate': { type: 'boolean', default: false },
      keep: { type: 'boolean', default: false },
    },
  });

  const repoRoot = process.cwd();
  const iterations = Number(values.iterations);
  const warmup = Number(values.warmup);
  const outDir = resolve(repoRoot, values.out!);
  const wanted = values.only?.split(',').map((s) => s.trim());
  const selectedRuntimes = runtimes(repoRoot).filter((r) => !wanted || wanted.includes(r.id));
  const selectedScenarios = SCENARIOS.filter(
    (s) => !values.scenario?.length || values.scenario.includes(s.id)
  );
  if (!selectedRuntimes.length) throw new Error(`--only matched no runtime: ${values.only}`);
  if (!selectedScenarios.length) throw new Error(`--scenario matched no scenario`);

  const results: Results = {
    meta: {
      startedAt: new Date().toISOString(),
      gitSha: execFileSync('git', ['rev-parse', '--short', 'HEAD'], { encoding: 'utf-8' }).trim(),
      cpu: cpus()[0]?.model ?? 'unknown',
      cores: cpus().length,
      memGb: Math.round(totalmem() / 1024 ** 3),
      node: process.version,
      docker: serverVersion(),
      iterations,
      warmup,
      hostPlatform: `${process.platform}/${process.arch}`,
      reference: REFERENCE,
      scenarios: selectedScenarios.map(({ id, label, xrPath, kclPackage, pythonScript }) => ({
        id,
        label,
        xrPath,
        kclPackage,
        pythonScript,
      })),
    },
    runtimes: [],
    cells: [],
  };

  const xrs = new Map<string, Record<string, unknown>>();
  for (const scenario of selectedScenarios) xrs.set(scenario.id, readXr(repoRoot, scenario));

  for (const runtime of selectedRuntimes) {
    const pulled = pullIfMissing(runtime.image, runtime.platform);
    const info = imageInfo(runtime.image);
    const emulated = info.platform !== `linux/${process.arch}`;
    const { startedAt } = await startFunction({
      name: runtime.containerName,
      image: runtime.image,
      port: runtime.hostPort,
      workspaceRoot: repoRoot,
      args: runtime.extraArgs,
      env: runtime.env,
      platform: runtime.platform,
    });

    const client = connectFunction(join(repoRoot, PROTO), `127.0.0.1:${runtime.hostPort}`);
    try {
      await waitForReady(client);
    } catch (err) {
      console.error(logs(runtime.containerName));
      throw err;
    }
    const coldStartMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    console.log(
      `${runtime.id.padEnd(7)} ${runtime.image} ${info.platform}` +
        `${emulated ? ' (emulated)' : ''} cold start ${coldStartMs.toFixed(0)}ms`
    );

    const runtimeStats: StatsSummary[] = [];
    try {
      for (const scenario of selectedScenarios) {
        if (runtime.flavour === 'python' && !scenario.pythonScript) {
          console.log(`${runtime.id.padEnd(7)} ${scenario.id.padEnd(13)} skipped (no python port)`);
          continue;
        }
        const xr = xrs.get(scenario.id)!;
        let observedResources: State['resources'];
        for (const phase of PHASES) {
          if (phase === 'observed' && !observedResources) break;
          const measured = await measure({
            client,
            runtime,
            scenario,
            phase,
            repoRoot,
            xr,
            observedResources,
            iterations,
            warmup,
          });
          const cell = measured.cell;
          runtimeStats.push(cell.footprint);
          results.cells.push(cell);
          console.log(
            `${runtime.id.padEnd(7)} ${scenario.id.padEnd(13)} ${phase.padEnd(8)} ` +
              `p50 ${cell.latency.p50.toFixed(2)}ms  p95 ${cell.latency.p95.toFixed(2)}ms  ` +
              `first ${cell.firstCallMs.toFixed(0)}ms  ${cell.resourceCount} resources`
          );
          if (phase === 'initial') observedResources = observedFrom(measured.response, scenario);
        }
      }
    } finally {
      client.close();
    }

    // A runtime fast enough to finish every loop inside one `docker stats`
    // tick yields no streamed sample; fall back to a single blocking snapshot
    // taken now, with the container warm and idle.
    const sampled = runtimeStats.filter((s) => s.samples > 0);
    if (!sampled.length) {
      const snapshot = snapshotStats(runtime.containerName);
      if (snapshot) sampled.push(snapshot);
    }
    results.runtimes.push({
      id: runtime.id,
      label: runtime.label,
      image: runtime.image,
      imageBytes: info.sizeBytes,
      platform: info.platform,
      emulated,
      pulled,
      coldStartMs,
      stats: {
        samples: sampled.reduce((a, s) => a + s.samples, 0),
        cpuAvgPercent: sampled.length
          ? sampled.reduce((a, s) => a + s.cpuAvgPercent, 0) / sampled.length
          : 0,
        cpuPeakPercent: Math.max(0, ...sampled.map((s) => s.cpuPeakPercent)),
        memAvgBytes: sampled.length
          ? sampled.reduce((a, s) => a + s.memAvgBytes, 0) / sampled.length
          : 0,
        memPeakBytes: Math.max(0, ...sampled.map((s) => s.memPeakBytes)),
        pidsPeak: Math.max(0, ...sampled.map((s) => s.pidsPeak)),
      },
    });
    if (!values.keep) removeContainer(runtime.containerName);
  }

  // Behavioural equivalence: same scenario, same phase, upstream function-kcl
  // as the reference. A runtime is only a drop-in replacement if the desired
  // state matches — modulo the empty metadata maps kclx deliberately drops,
  // which Kubernetes treats as absent and which the report calls out as such.
  for (const cell of results.cells) {
    if (cell.runtime === REFERENCE) continue;
    const reference = results.cells.find(
      (c) => c.runtime === REFERENCE && c.scenario === cell.scenario && c.phase === cell.phase
    );
    if (!reference?.canonical || !cell.canonical) continue;
    const wanted = {
      resources: reference.canonical.resources,
      compositeStatus: reference.canonical.compositeStatus,
    };
    const got = { resources: cell.canonical.resources, compositeStatus: cell.canonical.compositeStatus };
    const diff = diffText(wanted, got);
    const benign =
      diff.lines > 0 &&
      diffText(stripEmptyMetadata(wanted as Json), stripEmptyMetadata(got as Json)).lines === 0;
    cell.equivalence = {
      reference: REFERENCE,
      identical: diff.lines === 0,
      benign,
      note: benign
        ? 'differs only in empty metadata bookkeeping maps (metadata.annotations: {}), which Kubernetes treats as absent'
        : undefined,
      lines: diff.lines,
      diff: diff.text,
    };
  }

  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'results.json'), `${JSON.stringify(results, null, 2)}\n`);
  writeFileSync(join(outDir, 'report.html'), renderHtml(results));
  console.log(`\nwrote ${join(values.out!, 'results.json')} and ${join(values.out!, 'report.html')}`);

  for (const cell of results.cells.filter((c) => c.equivalence?.benign)) {
    console.log(
      `NOTE  ${cell.runtime}/${cell.scenario}/${cell.phase}: ${cell.equivalence!.lines} lines differ ` +
        `from ${REFERENCE} — ${cell.equivalence!.note}`
    );
  }
  const mismatched = results.cells.filter(
    (c) => c.equivalence && !c.equivalence.identical && !c.equivalence.benign
  );
  for (const cell of mismatched) {
    console.error(
      `\nMISMATCH ${cell.runtime}/${cell.scenario}/${cell.phase}: ` +
        `${cell.equivalence!.lines} lines differ from ${REFERENCE}\n${cell.equivalence!.diff}`
    );
  }
  if (mismatched.length && !values['no-gate']) {
    console.error(
      `\n${mismatched.length} cell(s) do not reproduce ${REFERENCE}'s desired state. ` +
        `Pass --no-gate to record the difference instead of failing.`
    );
    return 1;
  }
  return 0;
}

process.exitCode = await main();
