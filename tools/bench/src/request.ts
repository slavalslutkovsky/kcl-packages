/**
 * Builds the RunFunctionRequest for a (runtime, scenario, phase) triple.
 *
 * Both KCL runtimes get the same `KCLInput` a Composition would carry, with
 * `spec.source` repointed at the module inside the read-only mount — the same
 * rewrite `nx run <project>:render` performs (see `localizeCompositionSource`).
 * function-python gets the ported script inline, which is how its `Script`
 * input works.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parse } from 'yaml';
import { MOUNT } from './docker.ts';
import { fromStruct, toStruct } from './struct.ts';
import type { Json } from './struct.ts';
import type { RunFunctionRequest, RunFunctionResponse, State } from './client.ts';
import type { Phase, Runtime, Scenario } from './scenarios.ts';

export function readXr(repoRoot: string, scenario: Scenario): Record<string, unknown> {
  return parse(readFileSync(join(repoRoot, scenario.xrPath), 'utf-8')) as Record<string, unknown>;
}

function inputFor(repoRoot: string, runtime: Runtime, scenario: Scenario): Record<string, unknown> {
  if (runtime.flavour === 'kcl') {
    return {
      apiVersion: 'krm.kcl.dev/v1alpha1',
      kind: 'KCLInput',
      spec: { source: `${MOUNT}/${scenario.kclPackage}` },
    };
  }
  if (!scenario.pythonScript) {
    throw new Error(`Scenario "${scenario.id}" has no python port to run on ${runtime.id}.`);
  }
  return {
    apiVersion: 'python.fn.crossplane.io/v1beta1',
    kind: 'Script',
    script: readFileSync(join(repoRoot, scenario.pythonScript), 'utf-8'),
  };
}

/**
 * Turn a first-reconcile response into the observed composed state of the next
 * reconcile, the way Crossplane would after applying it: every desired resource
 * comes back as observed, and the managed resource additionally carries the
 * provider status the Composition reads (`ocds[...].Resource.status`).
 */
export function observedFrom(
  response: RunFunctionResponse,
  scenario: Scenario
): State['resources'] {
  const resources: NonNullable<State['resources']> = {};
  for (const [name, entry] of Object.entries(response.desired?.resources ?? {})) {
    const object = fromStruct(entry.resource);
    if (name === 'managed' && scenario.observedStatus) {
      object.status = scenario.observedStatus as Json;
    }
    resources[name] = { resource: toStruct(object) };
  }
  return resources;
}

export interface RequestSpec {
  repoRoot: string;
  runtime: Runtime;
  scenario: Scenario;
  phase: Phase;
  xr: Record<string, unknown>;
  observedResources?: State['resources'];
}

export function buildRequest(spec: RequestSpec): RunFunctionRequest {
  return {
    meta: { tag: `${spec.runtime.id}-${spec.scenario.id}-${spec.phase}` },
    observed: {
      composite: { resource: toStruct(spec.xr) },
      resources: spec.phase === 'observed' ? (spec.observedResources ?? {}) : {},
    },
    desired: {},
    input: toStruct(inputFor(spec.repoRoot, spec.runtime, spec.scenario)),
    context: { fields: {} },
  };
}
