/** The shape written to `out/results.json` and embedded in the HTML report. */
import type { Result } from './client.ts';
import type { StatsSummary } from './docker.ts';
import type { Canonical } from './normalize.ts';
import type { Phase, RuntimeId } from './scenarios.ts';

export interface Latency {
  n: number;
  p50: number;
  p95: number;
  p99: number;
  mean: number;
  min: number;
  max: number;
  /** Completed calls per second, derived from the mean of a serial loop. */
  rps: number;
}

export interface Equivalence {
  reference: RuntimeId;
  /** Byte-for-byte equal desired state after key sorting. */
  identical: boolean;
  /**
   * Not identical, but the only difference is metadata bookkeeping Kubernetes
   * treats as absent (an empty `metadata.annotations` map). Reported, not gated.
   */
  benign: boolean;
  note?: string;
  /** Differing lines of pretty-printed, key-sorted desired state. */
  lines: number;
  diff: string;
}

export interface Cell {
  runtime: RuntimeId;
  scenario: string;
  phase: Phase;
  latency: Latency;
  /** Includes module load and dependency resolution; excluded from the loop. */
  firstCallMs: number;
  responseBytes: number;
  resourceCount: number;
  resourceNames: string[];
  ready: string[];
  statusKeys: string[];
  results: Result[];
  /** `docker stats` of the container during this cell's measured loop. */
  footprint: StatsSummary;
  equivalence: Equivalence | null;
  /** Key-sorted desired state; dropped from the HTML copy, kept in the JSON. */
  canonical?: Canonical;
}

export interface RuntimeReport {
  id: RuntimeId;
  label: string;
  image: string;
  imageBytes: number | null;
  platform: string;
  /** The image's platform is not the host's, so every call runs under QEMU. */
  emulated: boolean;
  pulled: boolean;
  coldStartMs: number;
  stats: StatsSummary;
}

export interface Results {
  meta: {
    startedAt: string;
    gitSha: string;
    cpu: string;
    cores: number;
    memGb: number;
    node: string;
    docker: string;
    iterations: number;
    warmup: number;
    hostPlatform: string;
    reference: RuntimeId;
    scenarios: { id: string; label: string; xrPath: string; kclPackage: string; pythonScript?: string }[];
  };
  runtimes: RuntimeReport[];
  cells: Cell[];
}
