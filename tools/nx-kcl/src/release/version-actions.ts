import { readNxJson, type Tree } from '@nx/devkit';
import { VersionActions } from 'nx/release';
import { join } from 'node:path';
import { parseKclMod, pinCompositionSource, updateKclModVersion } from '../utils';

const COMPOSITION_FILE = 'composition.yaml';

/**
 * Nx release VersionActions for KCL packages.
 *
 * KCL keeps a package's version in `kcl.mod` (not `package.json`), so this
 * teaches `nx release` to read and write the version there. The semver bump
 * itself (from conventional commits or an explicit specifier) is handled by
 * the inherited `VersionActions.calculateNewVersion()`.
 *
 * Additionally, if the project has a `composition.yaml` whose KCL `source:`
 * line references this package's OCI image, we rewrite the source to pin the
 * newly published version - so Crossplane consumers of the Composition always
 * render against the exact image we just shipped.
 */
export default class KclVersionActions extends VersionActions {
  validManifestFilenames = ['kcl.mod'];

  async readCurrentVersionFromSourceManifest(tree: Tree) {
    const manifestPath = join(this.projectGraphNode.data.root, 'kcl.mod');
    const contents = tree.read(manifestPath, 'utf-8');
    if (!contents) {
      throw new Error(
        `Unable to read "${manifestPath}" to determine the current version of project "${this.projectGraphNode.name}".`
      );
    }
    return { manifestPath, currentVersion: parseKclMod(contents).version };
  }

  // KCL packages are not resolved from an npm-style registry during versioning.
  async readCurrentVersionFromRegistry() {
    return null;
  }

  // KCL packages in this workspace have no nx-tracked inter-project dependencies.
  async readCurrentVersionOfDependency() {
    return { currentVersion: null, dependencyCollection: null };
  }

  async updateProjectVersion(tree: Tree, newVersion: string) {
    const logMessages: string[] = [];
    for (const { manifestPath } of this.manifestsToUpdate) {
      const contents = tree.read(manifestPath, 'utf-8');
      if (!contents) continue;
      tree.write(manifestPath, updateKclModVersion(contents, newVersion));
      logMessages.push(
        `✍️  New version ${newVersion} written to manifest: ${manifestPath}`
      );
    }

    const projectName = this.projectGraphNode.name;
    const compositionPath = join(this.projectGraphNode.data.root, COMPOSITION_FILE);
    const composition = tree.read(compositionPath, 'utf-8');
    if (composition) {
      const registry = resolveRegistry(tree, projectName);
      const { content, matched } = pinCompositionSource(
        composition,
        projectName,
        registry,
        newVersion
      );
      if (matched) {
        tree.write(compositionPath, content);
        logMessages.push(
          `📌 Pinned ${COMPOSITION_FILE} source to ${projectName}@${newVersion}: ${compositionPath}`
        );
      }
    }

    return logMessages;
  }

  // No dependency manifests to update for KCL packages.
  async updateProjectDependencies() {
    return [];
  }
}

// `KCL_REGISTRY` env var (set in CI) takes precedence so the version-actions
// stays aligned with the publish-executor's actual push target. nx.json's
// `release.registry` is the durable, in-repo default for local `nx release
// --dry-run` and any environment where the env var isn't exported.
function resolveRegistry(tree: Tree, projectName: string): string {
  const fromEnv = process.env.KCL_REGISTRY;
  if (fromEnv) return fromEnv;
  const nxJson = readNxJson(tree) as { release?: { registry?: string } } | null;
  const fromConfig = nxJson?.release?.registry;
  if (fromConfig) return fromConfig;
  throw new Error(
    `Cannot pin composition.yaml for "${projectName}": set release.registry in nx.json or the KCL_REGISTRY env var.`
  );
}
