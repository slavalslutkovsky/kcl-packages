import type { ExecutorContext } from '@nx/devkit';
import { execSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { removeKclModDependency } from '../utils';

export interface KclRemoveExecutorOptions {
  /** Name of the dependency to remove (e.g. "k8s"). */
  name: string;
  /** Set by `nx --dry-run`; when true nothing is written. */
  dryRun?: boolean;
}

/**
 * Remove a dependency from a KCL package. Unlike `kcl mod add`, KCL has no
 * `kcl mod remove`, and no `kcl mod` subcommand prunes a dependency left in
 * kcl.mod.lock. So we edit kcl.mod, delete the lock, and let
 * `kcl mod metadata --update` regenerate it from the remaining dependencies.
 */
export default async function kclRemoveExecutor(
  options: KclRemoveExecutorOptions,
  context: ExecutorContext
) {
  const projectName = context.projectName;
  if (!projectName) {
    throw new Error('The kcl remove executor must be run against a project.');
  }
  const dependency = options.name;
  if (!dependency) {
    throw new Error(
      'Provide the dependency to remove, e.g. `nx run <project>:remove k8s`.'
    );
  }

  const projectRoot = context.projectsConfigurations.projects[projectName].root;
  const kclModPath = join(context.root, projectRoot, 'kcl.mod');
  const { content, removed } = removeKclModDependency(
    readFileSync(kclModPath, 'utf-8'),
    dependency
  );
  if (!removed) {
    throw new Error(
      `Dependency "${dependency}" is not listed in ${projectRoot}/kcl.mod.`
    );
  }

  if (options.dryRun || process.env.NX_DRY_RUN === 'true') {
    console.log(
      `[dry-run] remove "${dependency}" from ${projectRoot}/kcl.mod and reconcile kcl.mod.lock`
    );
    return { success: true };
  }

  writeFileSync(kclModPath, content);
  const lockPath = join(context.root, projectRoot, 'kcl.mod.lock');
  if (existsSync(lockPath)) {
    rmSync(lockPath);
  }
  execSync('kcl mod metadata --update', {
    cwd: join(context.root, projectRoot),
    stdio: 'inherit',
  });
  console.log(`Removed "${dependency}" from ${projectName} and reconciled kcl.mod.lock`);
  return { success: true };
}
