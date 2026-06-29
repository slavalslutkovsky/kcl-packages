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
