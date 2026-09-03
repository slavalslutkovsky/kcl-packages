import { readFileSync } from 'fs';
import { join } from 'path';

export interface KclModInfo {
  name: string;
  version: string;
  edition: string;
}

/**
 * Parse a kcl.mod file and extract package metadata.
 */
export function parseKclMod(content: string): KclModInfo {
  const name = content.match(/^name\s*=\s*"(.+)"/m)?.[1] ?? 'unknown';
  const version = content.match(/^version\s*=\s*"(.+)"/m)?.[1] ?? '0.0.0';
  const edition = content.match(/^edition\s*=\s*"(.+)"/m)?.[1] ?? '';
  return { name, version, edition };
}

/**
 * Read and parse a kcl.mod file from disk.
 */
export function readKclMod(workspaceRoot: string, kclModPath: string): KclModInfo {
  const content = readFileSync(join(workspaceRoot, kclModPath), 'utf-8');
  return parseKclMod(content);
}

/**
 * Relative `path = "…"` dependencies declared in a kcl.mod `[dependencies]`
 * table. These are the only intra-workspace edges KCL knows about (registry
 * dependencies point outside the repo), so they are what the Nx project graph
 * is built from.
 */
export function parseKclModPathDeps(content: string): string[] {
  const deps: string[] = [];
  for (const line of content.split('\n')) {
    const path = line.match(/^[A-Za-z0-9_-]+\s*=\s*\{[^}]*\bpath\s*=\s*"([^"]+)"/)?.[1];
    if (path) deps.push(path);
  }
  return deps;
}

/**
 * Update the version in a kcl.mod file content string.
 */
export function updateKclModVersion(content: string, newVersion: string): string {
  return content.replace(/^(version\s*=\s*)".*"/m, `$1"${newVersion}"`);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Remove a dependency from the `[dependencies]` table of a kcl.mod file.
 * Also drops the `[dependencies]` header if it becomes empty. Returns the
 * updated content and whether the dependency was actually present.
 */
export function removeKclModDependency(
  content: string,
  dependency: string
): { content: string; removed: boolean } {
  const lines = content.split('\n');
  const depPattern = new RegExp(`^\\s*${escapeRegExp(dependency)}\\s*=`);
  const isHeader = (line: string) => /^\s*\[.+\]\s*$/.test(line);

  let inDeps = false;
  let removed = false;
  const kept: string[] = [];
  for (const line of lines) {
    if (isHeader(line)) {
      inDeps = line.trim() === '[dependencies]';
      kept.push(line);
      continue;
    }
    if (inDeps && depPattern.test(line)) {
      removed = true;
      continue;
    }
    kept.push(line);
  }

  // Drop a now-empty [dependencies] section (header with no `key = value` rows
  // before the next header or EOF), plus a single trailing blank line.
  for (let i = 0; i < kept.length; i++) {
    if (kept[i].trim() !== '[dependencies]') continue;
    let hasEntry = false;
    let j = i + 1;
    for (; j < kept.length && !isHeader(kept[j]); j++) {
      if (kept[j].trim() !== '') hasEntry = true;
    }
    if (!hasEntry) {
      const removeCount = kept[i + 1]?.trim() === '' ? 2 : 1;
      kept.splice(i, removeCount);
    }
    break;
  }

  return { content: kept.join('\n'), removed };
}

/**
 * Rewrite the `source: oci://...` line in a Crossplane Composition's KCL input
 * to pin a specific package version. Only lines whose OCI path ends with the
 * given project name are touched, so cross-project references in the same file
 * are preserved.
 *
 * Idempotent: an existing `?tag=...` or `:tag` suffix is replaced.
 */
export function pinCompositionSource(
  yaml: string,
  projectName: string,
  registry: string,
  version: string
): { content: string; matched: boolean } {
  const escapedName = escapeRegExp(projectName);
  // ^(<indent>source: )oci://<host-and-path>/<projectName>(<optional tag suffix>)$
  const lineRe = new RegExp(
    `^(\\s*source:\\s*)oci://\\S+?/${escapedName}(?:[?:][^\\s]*)?\\s*$`,
    'gm'
  );
  let matched = false;
  const content = yaml.replace(lineRe, (_full, prefix) => {
    matched = true;
    return `${prefix}oci://${registry}/${projectName}?tag=${version}`;
  });
  return { content, matched };
}

/** Annotation that tells `crossplane render` to call a locally running Function. */
const RUNTIME_ANNOTATION = 'render.crossplane.io/runtime';

/**
 * Split a multi-document YAML string, rewrite documents via `fn` (returning
 * `null` leaves a document untouched), and rejoin it byte-for-byte. The
 * separators are captured so comments and spacing survive the round trip.
 */
function mapYamlDocuments(
  yaml: string,
  fn: (doc: string) => string | null
): { content: string; matched: boolean } {
  const parts = yaml.split(/^(---[ \t]*(?:\r?\n|$))/m);
  let matched = false;
  for (let i = 0; i < parts.length; i += 2) {
    const updated = fn(parts[i]);
    if (updated !== null) {
      parts[i] = updated;
      matched = true;
    }
  }
  return { content: parts.join(''), matched };
}

/** Does this YAML document declare `name: <resourceName>`? */
function declaresName(doc: string, resourceName: string): boolean {
  return new RegExp(`^\\s*name:\\s*["']?${escapeRegExp(resourceName)}["']?\\s*$`, 'm').test(doc);
}

/**
 * Read the `spec.package` image of a named Function from a Crossplane functions
 * manifest, so a local render runs the same pinned image the cluster would.
 */
export function readFunctionPackage(
  functionsYaml: string,
  functionName: string
): string | undefined {
  for (const doc of functionsYaml.split(/^---[ \t]*$/m)) {
    if (!declaresName(doc, functionName)) continue;
    const pkg = doc.match(/^\s*package:\s*(\S+)\s*$/m)?.[1];
    if (pkg) return pkg.replace(/^["']|["']$/g, '');
  }
  return undefined;
}

/**
 * Repoint a Composition's KCL `source:` at a local directory instead of an OCI
 * image. The inverse of `pinCompositionSource`: that one pins what consumers
 * pull, this one makes a local render read the working tree.
 *
 * Only lines whose OCI path ends with the given project name are touched.
 */
export function localizeCompositionSource(
  yaml: string,
  projectName: string,
  localPath: string
): { content: string; matched: boolean } {
  const lineRe = new RegExp(
    `^(\\s*source:\\s*)oci://\\S+?/${escapeRegExp(projectName)}(?:[?:][^\\s]*)?\\s*$`,
    'gm'
  );
  let matched = false;
  const content = yaml.replace(lineRe, (_full, prefix) => {
    matched = true;
    return `${prefix}${localPath}`;
  });
  return { content, matched };
}

/**
 * Annotate a named Function with the Development runtime, so `crossplane render`
 * dials a Function we started ourselves rather than running one in Docker with
 * no way to mount the working tree. Idempotent.
 */
export function withDevelopmentRuntime(
  functionsYaml: string,
  functionName: string
): { content: string; matched: boolean } {
  return mapYamlDocuments(functionsYaml, (doc) => {
    if (!declaresName(doc, functionName)) return null;
    if (new RegExp(`^\\s*${escapeRegExp(RUNTIME_ANNOTATION)}:`, 'm').test(doc)) return doc;

    const lines = doc.split('\n');
    const metaIdx = lines.findIndex((l) => /^\s*metadata:\s*$/.test(l));
    if (metaIdx === -1) return null;
    const metaIndent = lines[metaIdx].match(/^\s*/)![0];
    const fieldIndent = `${metaIndent}  `;

    // Stay inside the metadata block: stop at the first line indented no
    // further than `metadata:` itself.
    let end = metaIdx + 1;
    while (end < lines.length) {
      const line = lines[end];
      if (line.trim() !== '' && !line.startsWith(fieldIndent)) break;
      end++;
    }
    const existing = lines
      .slice(metaIdx + 1, end)
      .findIndex((l) => new RegExp(`^${fieldIndent}annotations:\\s*$`).test(l));

    if (existing === -1) {
      lines.splice(metaIdx + 1, 0, `${fieldIndent}annotations:`, `${fieldIndent}  ${RUNTIME_ANNOTATION}: Development`);
    } else {
      lines.splice(metaIdx + 1 + existing + 1, 0, `${fieldIndent}  ${RUNTIME_ANNOTATION}: Development`);
    }
    return lines.join('\n');
  });
}
