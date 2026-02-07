import { Tree, readJson, ProjectGraphProjectNode } from '@nx/devkit';
import * as semver from 'semver';
import { parseKclMod, updateKclModVersion } from '../utils';
import { join } from 'path';

interface VersionGeneratorSchema {
  projects: Record<string, ProjectGraphProjectNode>;
  projectGraph: { nodes: Record<string, ProjectGraphProjectNode> };
  specifier: string;
  preid?: string;
  releaseGroup: {
    name: string;
    projectsRelationship: 'fixed' | 'independent';
  };
  currentVersionResolver?: 'disk' | 'git-tag' | 'registry';
  firstRelease?: boolean;
}

interface VersionData {
  currentVersion: string;
  newVersion: string | null;
}

/**
 * Custom Nx release version generator for KCL packages.
 * Reads/writes version from kcl.mod instead of package.json.
 */
export default async function versionGenerator(
  tree: Tree,
  options: VersionGeneratorSchema
) {
  const versionData: Record<string, VersionData> = {};

  for (const [projectName, project] of Object.entries(options.projects)) {
    const projectRoot = project.data.root;
    const kclModPath = join(projectRoot, 'kcl.mod');

    // Read current version from kcl.mod
    const kclModContent = tree.read(kclModPath, 'utf-8');
    if (!kclModContent) {
      throw new Error(`Could not read ${kclModPath}`);
    }

    const { version: currentVersion } = parseKclMod(kclModContent);

    // Calculate new version
    let newVersion: string | null = null;

    if (['patch', 'minor', 'major', 'premajor', 'preminor', 'prepatch', 'prerelease'].includes(options.specifier)) {
      newVersion = semver.inc(
        currentVersion,
        options.specifier as semver.ReleaseType,
        options.preid
      );
    } else if (semver.valid(options.specifier)) {
      newVersion = options.specifier;
    } else if (options.specifier === '') {
      // No specifier means no version change (e.g., from conventional commits with no relevant changes)
      newVersion = null;
    } else {
      throw new Error(
        `Invalid version specifier: "${options.specifier}". Use patch, minor, major, or an exact semver version.`
      );
    }

    versionData[projectName] = { currentVersion, newVersion };
  }

  // Return data + callback that updates files
  return {
    data: versionData,
    callback: async (
      tree: Tree,
      opts: { dryRun?: boolean; verbose?: boolean }
    ): Promise<string[]> => {
      const changedFiles: string[] = [];

      for (const [projectName, data] of Object.entries(versionData)) {
        if (!data.newVersion) continue;

        const project = options.projects[projectName];
        const kclModPath = join(project.data.root, 'kcl.mod');
        const content = tree.read(kclModPath, 'utf-8');

        if (!content) continue;

        const updated = updateKclModVersion(content, data.newVersion);

        if (!opts.dryRun) {
          tree.write(kclModPath, updated);
        }

        if (opts.verbose) {
          console.log(
            `  ${projectName}: ${data.currentVersion} → ${data.newVersion} (${kclModPath})`
          );
        }

        changedFiles.push(kclModPath);
      }

      return changedFiles;
    },
  };
}
