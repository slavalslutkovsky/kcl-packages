import { CreateNodes, CreateNodesContext, ProjectConfiguration } from '@nx/devkit';
import { dirname } from 'path';
import { readKclMod } from './utils';

export interface NxKclPluginOptions {
  /** OCI registry prefix, e.g. "oci://ghcr.io/org" */
  registryPrefix?: string;
}

export const createNodesV2: CreateNodes<NxKclPluginOptions> = [
  '**/kcl.mod',
  (kclModFiles, options, context) => {
    return kclModFiles
      .filter((f) => !f.includes('node_modules'))
      .map((kclModFile) => {
        const projectRoot = dirname(kclModFile);
        const { name } = readKclMod(context.workspaceRoot, kclModFile);

        // Tag by area: the path segment under `packages/` (e.g. "providers",
        // "cloud", "cluster"). Lets release scoping target/exclude groups —
        // schema/provider packages are internal (consumed by relative path) and
        // are excluded from publishing in nx.json.
        const segments = projectRoot.split('/');
        const pkgsIdx = segments.indexOf('packages');
        const area = pkgsIdx >= 0 ? segments[pkgsIdx + 1] : undefined;

        const project: ProjectConfiguration = {
          name,
          root: projectRoot,
          sourceRoot: projectRoot,
          projectType: 'library',
          tags: area ? ['lang:kcl', `area:${area}`] : ['lang:kcl'],
          targets: {
            build: {
              cache: true,
              executor: 'nx:run-commands',
              inputs: [
                '{projectRoot}/**/*.k',
                '{projectRoot}/kcl.mod',
                '{projectRoot}/kcl.mod.lock',
              ],
              options: {
                command: `kcl run {projectRoot}/main.k`,
                cwd: '{workspaceRoot}',
              },
            },
            test: {
              cache: true,
              executor: 'nx:run-commands',
              inputs: [
                '{projectRoot}/**/*.k',
                '{projectRoot}/kcl.mod',
                '{projectRoot}/kcl.mod.lock',
              ],
              options: {
                command: 'kcl test',
                cwd: `{workspaceRoot}/${projectRoot}`,
              },
            },
            lint: {
              cache: true,
              executor: 'nx:run-commands',
              inputs: ['{projectRoot}/**/*.k', '{projectRoot}/kcl.mod'],
              options: {
                command: 'kcl lint',
                cwd: `{workspaceRoot}/${projectRoot}`,
              },
            },
            fmt: {
              executor: 'nx:run-commands',
              options: {
                command: 'kcl fmt',
                cwd: `{workspaceRoot}/${projectRoot}`,
              },
            },
            add: {
              // Wraps `kcl mod add`; forwarded args (e.g. `k8s:1.32.4`, or
              // `--git <url> --tag <tag>`) are appended. Not cached: it mutates
              // kcl.mod and kcl.mod.lock.
              executor: 'nx:run-commands',
              options: {
                command: 'kcl mod add',
                cwd: `{workspaceRoot}/${projectRoot}`,
              },
            },
            remove: {
              // `kcl mod remove` does not exist; the nx-kcl:remove executor
              // edits kcl.mod and regenerates the lock. Usage:
              // `nx run <project>:remove <dep>`.
              executor: 'nx-kcl:remove',
              options: {},
            },
            pkg: {
              cache: true,
              executor: 'nx:run-commands',
              dependsOn: ['test', 'lint'],
              inputs: [
                '{projectRoot}/**/*.k',
                '{projectRoot}/kcl.mod',
                '{projectRoot}/kcl.mod.lock',
              ],
              outputs: ['{projectRoot}/*.tar'],
              options: {
                command: 'kcl mod pkg --target .',
                cwd: `{workspaceRoot}/${projectRoot}`,
              },
            },
            'nx-release-publish': {
              dependsOn: ['test', 'lint'],
              executor: 'nx-kcl:publish',
              options: options?.registryPrefix ? { registry: options.registryPrefix } : {},
            },
          },
        };

        return [kclModFile, { projects: { [projectRoot]: project } }] as const;
      });
  },
];
