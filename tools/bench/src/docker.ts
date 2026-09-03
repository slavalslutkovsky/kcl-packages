/**
 * Container lifecycle for the benchmarked function runtimes.
 *
 * Deliberately close to `tools/nx-kcl/src/render/render-executor.ts`, but not
 * shared with it: that module's helpers are private, it *reuses* a running
 * container, and it never measures anything. Here a cold start is one of the
 * numbers being reported, so every run starts from `docker rm -f`.
 */
import { execFileSync, spawn } from 'node:child_process';
import { connect } from 'node:net';

/** Where the workspace is mounted inside every function container. */
export const MOUNT = '/workspace';
/** Every crossplane function serves gRPC on this port. */
export const CONTAINER_PORT = 9443;

/**
 * Run docker, capturing stderr rather than letting it through: `inspect` on a
 * missing image is a normal control-flow signal here, not something to print.
 */
export function docker(args: string[]): string {
  try {
    return execFileSync('docker', args, {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (err) {
    const { code, stderr, message } = err as { code?: string; stderr?: string; message: string };
    if (code === 'ENOENT') {
      throw new Error('Could not run `docker`. The benchmark needs a working Docker installation.');
    }
    throw new Error(`\`docker ${args.join(' ')}\` failed: ${(stderr || message).trim()}`);
  }
}

/** Resolve once the function is accepting connections, or throw after `timeoutMs`. */
async function waitForPort(port: number, label: string, timeoutMs = 120_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const attempt = Promise.withResolvers<boolean>();
    const socket = connect({ host: '127.0.0.1', port })
      .on('connect', () => {
        socket.destroy();
        attempt.resolve(true);
      })
      .on('error', () => attempt.resolve(false));
    socket.setTimeout(1_000, () => {
      socket.destroy();
      attempt.resolve(false);
    });
    if (await attempt.promise) return;
    if (Date.now() >= deadline) {
      throw new Error(
        `${label} did not start listening on 127.0.0.1:${port} within ${timeoutMs / 1000}s.`
      );
    }
    const pause = Promise.withResolvers<void>();
    setTimeout(pause.resolve, 20);
    await pause.promise;
  }
}

export interface ImageInfo {
  /** Compressed-on-disk size docker reports for the image. */
  sizeBytes: number | null;
  /** `linux/arm64`, `linux/amd64`, ... — an amd64 image on this host is emulated. */
  platform: string;
}

export function imageInfo(image: string): ImageInfo {
  const raw = docker(['image', 'inspect', image, '--format', '{{.Size}}\t{{.Os}}/{{.Architecture}}']);
  const [size, platform] = raw.split('\t');
  return { sizeBytes: Number.isFinite(Number(size)) ? Number(size) : null, platform };
}

/** Pull `image` unless it is already in the local store. Returns true if pulled. */
export function pullIfMissing(image: string, platform?: string): boolean {
  try {
    docker(['image', 'inspect', image, '--format', '{{.Id}}']);
    return false;
  } catch {
    console.log(`pulling ${image}${platform ? ` (${platform})` : ''}`);
    docker(['pull', ...(platform ? ['--platform', platform] : []), image]);
    return true;
  }
}

export interface StatsSummary {
  samples: number;
  cpuAvgPercent: number;
  cpuPeakPercent: number;
  memAvgBytes: number;
  memPeakBytes: number;
  pidsPeak: number;
}

const UNITS: Record<string, number> = {
  b: 1,
  kb: 1e3,
  mb: 1e6,
  gb: 1e9,
  kib: 1024,
  mib: 1024 ** 2,
  gib: 1024 ** 3,
};

/**
 * Follow `docker stats` for one container until `stop()`.
 *
 * Streaming, not `--no-stream` polling: one `--no-stream` call blocks for over
 * a second, and doing that from inside the measured loop would land squarely in
 * the latency numbers it is supposed to annotate.
 */
export function collectStats(name: string): { stop: () => StatsSummary } {
  const child = spawn('docker', ['stats', '--format', '{{json .}}', name], {
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const cpu: number[] = [];
  const mem: number[] = [];
  let pidsPeak = 0;
  let pending = '';

  child.stdout.setEncoding('utf-8');
  child.stdout.on('data', (chunk: string) => {
    pending += chunk;
    const lines = pending.split('\n');
    pending = lines.pop() ?? '';
    for (const line of lines) {
      // Docker wraps each streamed row in cursor-control sequences even when
      // stdout is a pipe: `\x1b[H{"CPUPerc":...}\x1b[K`.
      const start = line.indexOf('{');
      const end = line.lastIndexOf('}');
      if (start === -1 || end <= start) continue;
      let row: { CPUPerc?: string; MemUsage?: string; PIDs?: string };
      try {
        row = JSON.parse(line.slice(start, end + 1));
      } catch {
        continue;
      }
      // MemUsage looks like `12.34MiB / 7.653GiB`; only the left operand is usage.
      const used = /^([\d.]+)\s*([a-zA-Z]+)/.exec((row.MemUsage ?? '0B').trim());
      cpu.push(Number((row.CPUPerc ?? '0%').replace('%', '')) || 0);
      mem.push(used ? Number(used[1]) * (UNITS[used[2].toLowerCase()] ?? 1) : 0);
      pidsPeak = Math.max(pidsPeak, Number(row.PIDs ?? '0') || 0);
    }
  });
  child.on('error', () => {
    /* no stats is not a benchmark failure */
  });

  return {
    stop() {
      child.kill('SIGKILL');
      const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
      return {
        samples: cpu.length,
        cpuAvgPercent: mean(cpu),
        cpuPeakPercent: cpu.length ? Math.max(...cpu) : 0,
        memAvgBytes: mean(mem),
        memPeakBytes: mem.length ? Math.max(...mem) : 0,
        pidsPeak,
      };
    },
  };
}

/**
 * One blocking `docker stats --no-stream` sample. Used only as a floor when a
 * runtime is fast enough that the streamed collector never got a tick (docker
 * emits roughly one row per second); it costs over a second, so it never runs
 * anywhere near a measured loop.
 */
export function snapshotStats(name: string): StatsSummary | null {
  let raw: string;
  try {
    raw = docker(['stats', '--no-stream', '--format', '{{json .}}', name]);
  } catch {
    return null;
  }
  const start = raw.indexOf('{');
  const end = raw.lastIndexOf('}');
  if (start === -1 || end <= start) return null;
  const row = JSON.parse(raw.slice(start, end + 1)) as {
    CPUPerc?: string;
    MemUsage?: string;
    PIDs?: string;
  };
  const used = /^([\d.]+)\s*([a-zA-Z]+)/.exec((row.MemUsage ?? '0B').trim());
  const memBytes = used ? Number(used[1]) * (UNITS[used[2].toLowerCase()] ?? 1) : 0;
  const cpuPercent = Number((row.CPUPerc ?? '0%').replace('%', '')) || 0;
  return {
    samples: 1,
    cpuAvgPercent: cpuPercent,
    cpuPeakPercent: cpuPercent,
    memAvgBytes: memBytes,
    memPeakBytes: memBytes,
    pidsPeak: Number(row.PIDs ?? '0') || 0,
  };
}

export interface StartOptions {
  name: string;
  image: string;
  port: number;
  workspaceRoot: string;
  args?: string[];
  env?: Record<string, string>;
  platform?: string;
}

/** Remove a container if it exists; safe when it does not. */
export function removeContainer(name: string): void {
  try {
    docker(['rm', '-f', name]);
  } catch {
    /* never existed */
  }
}

/**
 * Start a function container from scratch. The workspace is mounted read-only
 * at {@link MOUNT} so the KCL runtimes can read the Composition packages (and
 * their relative-path provider schema dependencies) straight out of the working
 * tree.
 *
 * Returns the instant `docker run` was issued. Cold start is only complete once
 * gRPC answers, and docker publishes the port before the process behind it
 * listens, so the caller finishes the measurement with `waitForReady`.
 */
export async function startFunction(opts: StartOptions): Promise<{ startedAt: bigint }> {
  removeContainer(opts.name);
  const env = Object.entries(opts.env ?? {}).flatMap(([k, v]) => ['--env', `${k}=${v}`]);
  const startedAt = process.hrtime.bigint();
  docker([
    'run',
    '--detach',
    '--name',
    opts.name,
    ...(opts.platform ? ['--platform', opts.platform] : []),
    '--publish',
    `127.0.0.1:${opts.port}:${CONTAINER_PORT}`,
    '--volume',
    `${opts.workspaceRoot}:${MOUNT}:ro`,
    ...env,
    opts.image,
    ...(opts.args ?? []),
  ]);
  try {
    await waitForPort(opts.port, opts.name);
  } catch (err) {
    console.error(logs(opts.name));
    throw err;
  }
  return { startedAt };
}

/** Tail of a container's log, for error reporting. */
export function logs(name: string, lines = 40): string {
  try {
    return docker(['logs', '--tail', String(lines), name]);
  } catch {
    return '';
  }
}

export function serverVersion(): string {
  try {
    return docker(['version', '--format', '{{.Server.Version}}']);
  } catch {
    return 'unknown';
  }
}
