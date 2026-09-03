import {
  CreateDependencies,
  DependencyType,
  RawProjectGraphDependency,
  validateDependency,
} from '@nx/devkit';
import { readFileSync } from 'fs';
import { dirname, join, normalize, posix } from 'path';
import { parseKclModPathDeps } from './utils';
import type { NxKclPluginOptions } from './create-nodes';

/**
 * Project-graph edges for KCL packages: every `path = "…"` dependency in a
 * kcl.mod is a static edge from the declaring package to the package at that
 * path. Registry dependencies (`k8s = "1.32.4"`) resolve outside the workspace
 * and add no edge.
 *
 * Only kcl.mod files that changed since the last run are re-read
 * (`filesToProcess`); Nx keeps the edges of untouched projects.
 */
export const createDependencies: CreateDependencies<NxKclPluginOptions> = (_options, context) => {
  // Reverse index: project root -> project name, so a resolved path maps to a node.
  const byRoot = new Map<string, string>();
  for (const [name, project] of Object.entries(context.projects)) {
    if (project.root) byRoot.set(normalize(project.root), name);
  }

  const deps: RawProjectGraphDependency[] = [];
  for (const [source, files] of Object.entries(context.filesToProcess.projectFileMap)) {
    for (const { file } of files) {
      if (posix.basename(file) !== 'kcl.mod') continue;
      const content = readFileSync(join(context.workspaceRoot, file), 'utf-8');
      for (const rel of parseKclModPathDeps(content)) {
        const target = byRoot.get(normalize(join(dirname(file), rel)));
        // Dangling paths are `just mod-check`'s job to report, not the graph's.
        if (!target || target === source) continue;
        const dep: RawProjectGraphDependency = {
          source,
          target,
          type: DependencyType.static,
          sourceFile: file,
        };
        validateDependency(dep, context);
        deps.push(dep);
      }
    }
  }
  return deps;
};
