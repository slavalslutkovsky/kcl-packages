import { Tree, logger } from '@nx/devkit';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

export interface KclPackageGeneratorSchema {
  name: string;
  directory?: string;
  /** Dependencies to add after creation, each forwarded to `kcl mod add`. */
  dependencies?: string[];
}

/**
 * KCL imports reference sibling modules by filename, which must be a valid
 * identifier. Derive one from the (possibly hyphenated) package name.
 */
function toModuleId(name: string): string {
  const id = name.replace(/[^a-zA-Z0-9_]/g, '_');
  return /^[0-9]/.test(id) ? `_${id}` : id;
}

/**
 * Scaffold a new KCL package. The manifest itself is created by `kcl mod init`
 * (it stamps the edition for the installed toolchain and writes kcl.mod.lock),
 * so we only author the starter sources — a schema module, an entry point, and a
 * passing test — which bare `kcl mod init` does not provide. `kcl mod init`
 * never clobbers existing files. The package is auto-discovered from its
 * kcl.mod, so there is no project.json to generate.
 */
export default async function kclPackageGenerator(
  tree: Tree,
  options: KclPackageGeneratorSchema
) {
  const { name } = options;
  const directory = options.directory ?? 'packages';
  const projectRoot = join(directory, name);
  const modId = toModuleId(name);

  if (tree.exists(join(projectRoot, 'kcl.mod'))) {
    throw new Error(`A KCL package already exists at "${projectRoot}".`);
  }

  tree.write(
    join(projectRoot, `${modId}.k`),
    [
      `# Schemas for the "${name}" package.`,
      ``,
      `schema Example:`,
      `    """An example schema — replace with your package's real types."""`,
      `    name: str = "example"`,
      `    enabled: bool = True`,
      ``,
    ].join('\n')
  );

  tree.write(
    join(projectRoot, 'main.k'),
    [
      `# Entry point for the "${name}" package.`,
      '# Build with `nx build ' + name + '` (runs `kcl run main.k`).',
      `import .${modId}`,
      ``,
      `items = [${modId}.Example {}]`,
      ``,
    ].join('\n')
  );

  tree.write(
    join(projectRoot, `${modId}_test.k`),
    [
      '# Tests for the "' + name + '" package. Run with `nx test ' + name + '` (`kcl test`).',
      `import .${modId}`,
      ``,
      `test_example = lambda {`,
      `    e = ${modId}.Example {}`,
      `    assert e.name == "example"`,
      `    assert e.enabled == True`,
      `}`,
      ``,
      `test_example()`,
      ``,
    ].join('\n')
  );

  return () => {
    const cwd = join(tree.root, projectRoot);
    // `kcl mod init` (no name) uses the directory name as the package name and
    // creates kcl.mod (with the toolchain's edition) + kcl.mod.lock, leaving the
    // sources above untouched.
    try {
      execFileSync('kcl', ['mod', 'init'], { cwd, stdio: 'inherit' });
    } catch {
      logger.warn(
        `Wrote sources to ${projectRoot}, but \`kcl mod init\` failed. ` +
          `Run \`kcl mod init\` in ${projectRoot} to create kcl.mod.`
      );
      return;
    }

    // Add requested dependencies via `kcl mod add` (each entry may carry flags,
    // e.g. "helloworld --oci https://... --tag 0.1.0").
    const failed: string[] = [];
    for (const dep of options.dependencies ?? []) {
      const spec = dep.trim();
      if (!spec) continue;
      try {
        execFileSync('kcl', ['mod', 'add', ...spec.split(/\s+/)], {
          cwd,
          stdio: 'inherit',
        });
      } catch {
        failed.push(spec);
      }
    }
    if (failed.length > 0) {
      logger.warn(
        `Could not add: ${failed.join(', ')}. ` +
          `Retry with \`nx run ${name}:add <dep>\`.`
      );
    }

    logger.info(`✅ Created KCL package "${name}" at ${projectRoot}`);
    logger.info(`   nx build ${name}   # kcl run main.k`);
    logger.info(`   nx test ${name}    # kcl test`);
  };
}
