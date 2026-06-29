import type { ExecutorContext } from '@nx/devkit';
import { execSync } from 'node:child_process';

export interface KclPublishExecutorOptions {
  /**
   * OCI registry prefix the package is published under, e.g.
   * "oci://docker.io/<namespace>". Environment variables (e.g. $KCL_REGISTRY)
   * are expanded at runtime. Defaults to "oci://$KCL_REGISTRY".
   */
  registry?: string;
  /** Set by `nx release --dry-run`; when true the push is skipped. */
  dryRun?: boolean;
}

export default async function kclPublishExecutor(
  options: KclPublishExecutorOptions,
  context: ExecutorContext
) {
  const projectName = context.projectName;
  if (!projectName) {
    throw new Error('The kcl publish executor must be run against a project.');
  }
  const projectRoot = context.projectsConfigurations.projects[projectName].root;

  const registry = (options.registry ?? 'oci://$KCL_REGISTRY').replace(
    /\$\{?(\w+)\}?/g,
    (_, name) => {
      const value = process.env[name];
      if (!value) {
        throw new Error(
          `Cannot publish "${projectName}": environment variable $${name} is not set. ` +
            `Set it to your OCI namespace, e.g. KCL_REGISTRY=docker.io/<namespace>.`
        );
      }
      return value;
    }
  );
  const target = `${registry}/${projectName}`;

  // `nx release --dry-run` sets both the option and the env var (the latter
  // reaches executors triggered indirectly via dependsOn).
  if (options.dryRun || process.env.NX_DRY_RUN === 'true') {
    console.log(`[dry-run] kcl mod push ${target}  (cwd: ${projectRoot})`);
    return { success: true };
  }

  console.log(`Publishing ${projectName} to ${target}`);
  execSync(`kcl mod push ${target}`, { cwd: projectRoot, stdio: 'inherit' });
  return { success: true };
}
