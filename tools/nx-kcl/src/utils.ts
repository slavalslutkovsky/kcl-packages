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
