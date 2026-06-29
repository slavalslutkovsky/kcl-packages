import type { Tree } from '@nx/devkit';
import { VersionActions } from 'nx/release';
import { join } from 'node:path';
import { parseKclMod, updateKclModVersion } from '../utils';

/**
 * Nx release VersionActions for KCL packages.
 *
 * KCL keeps a package's version in `kcl.mod` (not `package.json`), so this
 * teaches `nx release` to read and write the version there. The semver bump
 * itself (from conventional commits or an explicit specifier) is handled by
 * the inherited `VersionActions.calculateNewVersion()`.
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
    return logMessages;
  }

  // No dependency manifests to update for KCL packages.
  async updateProjectDependencies() {
    return [];
  }
}
