import type { ExecutorContext } from '@nx/devkit';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { localizeCompositionSource, readFunctionPackage, withDevelopmentRuntime } from '../utils';

export interface KclRenderExecutorOptions {
  /** Example XR to render; bare name resolves inside <xrdDir>/examples. */
  example?: string;
  /** Module `xrd/` dir; defaults to the sibling `xrd` dir of the package. */
  xrdDir?: string;
  /** Functions manifest; defaults to <xrdDir>/functions.yaml. */
  functions?: string;
  /** function-kcl image; defaults to the pin in the functions manifest. */
  image?: string;
  port?: number;
  containerName?: string;
  keepContainer?: boolean;
  functionResults?: boolean;
  fullXr?: boolean;
}

/** The function name whose source we redirect at the working tree. */
const KCL_FUNCTION = 'function-kcl';
/** Where the workspace is mounted inside the function container. */
const MOUNT = '/workspace';
const CONTAINER_PORT = 9443;

/**
 * Run docker, capturing stderr rather than letting it through: `inspect` on a
 * missing container is a normal control-flow signal here, not something to
 * print. Failures are rethrown with the captured stderr attached.
 */
function docker(args: string[]): string {
  try {
    return execFileSync('docker', args, {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (err) {
    const { code, stderr, message } = err as { code?: string; stderr?: string; message: string };
    if (code === 'ENOENT') {
      throw new Error('Could not run `docker`. Rendering needs a working Docker installation.');
    }
    throw new Error(`\`docker ${args.join(' ')}\` failed: ${(stderr || message).trim()}`);
  }
}

/** `docker inspect` a container, or null when it does not exist. */
function inspectContainer(
  name: string
): { running: boolean; image: string; mounts: string[]; hostPort: string } | null {
  let raw: string;
  try {
    raw = docker([
      'inspect',
      name,
      '--format',
      '{{.State.Running}}\t{{.Config.Image}}\t{{range .Mounts}}{{.Source}},{{end}}\t' +
        `{{range $p := index .NetworkSettings.Ports "${CONTAINER_PORT}/tcp"}}{{$p.HostPort}}{{end}}`,
    ]);
  } catch {
    return null; // no such container
  }
  const [running, image, mounts, hostPort] = raw.split('\t');
  return {
    running: running === 'true',
    image,
    mounts: mounts.split(',').filter(Boolean),
    hostPort,
  };
}

/** Resolve once the function is accepting connections, or throw after `timeoutMs`. */
async function waitForPort(port: number, timeoutMs = 30_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const open = await new Promise<boolean>((res) => {
      const socket = connect({ host: '127.0.0.1', port })
        .on('connect', () => {
          socket.destroy();
          res(true);
        })
        .on('error', () => res(false));
      socket.setTimeout(1_000, () => {
        socket.destroy();
        res(false);
      });
    });
    if (open) return;
    if (Date.now() >= deadline) {
      throw new Error(
        `function-kcl did not start listening on 127.0.0.1:${port} within ${timeoutMs / 1000}s.`
      );
    }
    await new Promise((res) => setTimeout(res, 250));
  }
}

/**
 * Start the function container, reusing an existing one when it already serves
 * this workspace from the same image and port. Returns true when a new
 * container was created (so the caller can tell the user how to stop it).
 */
async function ensureFunctionContainer(opts: {
  name: string;
  image: string;
  port: number;
  workspaceRoot: string;
}): Promise<boolean> {
  const existing = inspectContainer(opts.name);
  const usable =
    existing?.running &&
    existing.image === opts.image &&
    existing.mounts.includes(opts.workspaceRoot) &&
    existing.hostPort === String(opts.port);
  if (usable) {
    await waitForPort(opts.port);
    return false;
  }
  if (existing) docker(['rm', '-f', opts.name]);

  console.log(`Starting ${opts.image} as ${opts.name} (workspace mounted read-only at ${MOUNT})`);
  docker([
    'run',
    '--detach',
    '--name',
    opts.name,
    '--publish',
    `127.0.0.1:${opts.port}:${CONTAINER_PORT}`,
    '--volume',
    `${opts.workspaceRoot}:${MOUNT}:ro`,
    opts.image,
    '--insecure',
  ]);
  try {
    await waitForPort(opts.port);
  } catch (err) {
    console.error(docker(['logs', '--tail', '20', opts.name]));
    throw err;
  }
  return true;
}

/** Resolve the example XR to render, with a listing of the alternatives on miss. */
function resolveExample(
  option: string | undefined,
  examplesDir: string,
  projectName: string
): string {
  const available = existsSync(examplesDir)
    ? readdirSync(examplesDir).filter((f) => /\.ya?ml$/.test(f))
    : [];
  const listing = available.length
    ? `Available in ${examplesDir}: ${available.join(', ')}`
    : `No examples found in ${examplesDir}`;

  const candidates = option
    ? [
        isAbsolute(option) ? option : resolve(option),
        join(examplesDir, option),
        join(examplesDir, `${option}.yaml`),
      ]
    : // Examples are scaffolded as <project>.yaml by the composition generator.
      [join(examplesDir, `${projectName}.yaml`), join(examplesDir, `${projectName}.yml`)];

  const found = candidates.find((c) => existsSync(c));
  if (!found) {
    throw new Error(
      option
        ? `Example "${option}" not found. ${listing}`
        : `No example XR for "${projectName}". Pass one with --example. ${listing}`
    );
  }
  return found;
}

export default async function kclRenderExecutor(
  options: KclRenderExecutorOptions,
  context: ExecutorContext
) {
  const projectName = context.projectName;
  if (!projectName) {
    throw new Error('The kcl render executor must be run against a project.');
  }
  const projectRoot = context.projectsConfigurations.projects[projectName].root;
  const absProjectRoot = join(context.root, projectRoot);

  const compositionPath = join(absProjectRoot, 'composition.yaml');
  if (!existsSync(compositionPath)) {
    throw new Error(
      `"${projectName}" has no composition.yaml, so there is nothing to render. ` +
        `The render target is only meaningful for Composition packages.`
    );
  }

  // Compositions live at <module>/<provider>/, their XRD and examples at <module>/xrd/.
  const xrdDir = options.xrdDir
    ? join(context.root, options.xrdDir)
    : join(dirname(absProjectRoot), 'xrd');
  const functionsPath = options.functions
    ? join(context.root, options.functions)
    : join(xrdDir, 'functions.yaml');
  if (!existsSync(functionsPath)) {
    throw new Error(`Functions manifest not found: ${functionsPath}`);
  }
  const examplePath = resolveExample(options.example, join(xrdDir, 'examples'), projectName);

  const functionsYaml = readFileSync(functionsPath, 'utf-8');
  const image = options.image ?? readFunctionPackage(functionsYaml, KCL_FUNCTION);
  if (!image) {
    throw new Error(
      `Could not read the "${KCL_FUNCTION}" image from ${functionsPath}. Pass one with --image.`
    );
  }

  // Point the Composition at the mounted working tree instead of the published
  // OCI image, so what renders is what is on disk right now. Relative path deps
  // (the provider schema packages) resolve because the whole workspace is mounted.
  const { content: composition, matched } = localizeCompositionSource(
    readFileSync(compositionPath, 'utf-8'),
    projectName,
    `${MOUNT}/${projectRoot}`
  );
  if (!matched) {
    throw new Error(
      `No KCL \`source:\` line referencing "${projectName}" in ${compositionPath}. ` +
        `Rendering it would pull a published image rather than the working tree.`
    );
  }

  // The Development runtime lets us serve the mounted tree from a container we
  // control; the default Docker runtime would give us no way to mount it.
  const { content: functions, matched: annotated } = withDevelopmentRuntime(
    functionsYaml,
    KCL_FUNCTION
  );
  if (!annotated) {
    throw new Error(
      `No Function named "${KCL_FUNCTION}" with a metadata: block in ${functionsPath}.`
    );
  }

  const port = options.port ?? 9443;
  const containerName = options.containerName ?? 'nx-kcl-render';
  const started = await ensureFunctionContainer({
    name: containerName,
    image,
    port,
    workspaceRoot: context.root,
  });

  const staging = mkdtempSync(join(tmpdir(), 'kcl-render-'));
  try {
    const stagedComposition = join(staging, 'composition.yaml');
    const stagedFunctions = join(staging, 'functions.yaml');
    writeFileSync(stagedComposition, composition);
    writeFileSync(stagedFunctions, functions);

    const args = [
      'render',
      examplePath,
      stagedComposition,
      stagedFunctions,
      ...(options.functionResults ? ['--include-function-results'] : []),
      ...(options.fullXr ? ['--include-full-xr'] : []),
    ];
    console.log(`Rendering ${projectName} with ${basename(examplePath)}\n`);
    const result = spawnSync('crossplane', args, { cwd: context.root, stdio: 'inherit' });
    if (result.error) {
      throw new Error(
        `Could not run \`crossplane\`: ${result.error.message}. ` +
          `Install the Crossplane CLI: https://docs.crossplane.io/latest/cli/`
      );
    }
    if (result.status !== 0) return { success: false };
  } finally {
    rmSync(staging, { recursive: true, force: true });
    if (options.keepContainer === false) {
      docker(['rm', '-f', containerName]);
    } else if (started) {
      console.log(
        `\nfunction-kcl left running as "${containerName}" for faster reruns ` +
          `(\`docker rm -f ${containerName}\` to stop it).`
      );
    }
  }
  return { success: true };
}
