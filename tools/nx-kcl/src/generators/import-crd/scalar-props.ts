import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';

/**
 * Some CRDs describe a string map as `additionalProperties: {type: string,
 * properties: {key, value}}` (Litmus ChaosEngine's runnerLabels, nodeSelector,
 * experimentAnnotations). A scalar type cannot have properties — the API
 * server only ever stores the strings — but `kcl import -m crd` sees the
 * `properties` and emits a schema named after the type, `schema str:`, which
 * breaks the whole package. Dropping `properties` from every node whose
 * `type` is a scalar leaves exactly what the API server validates.
 */
const SCALAR_PROPS =
  'del(.. | select(tag == "!!map" and (.type == "string" or .type == "integer" or .type == "number" or .type == "boolean") and has("properties")) | .properties)';

/**
 * Applies the fix above to copies of `files` in a fresh temp dir (a local
 * `--from` source is never rewritten in place); returns the copies.
 */
export function dropScalarProperties(files: string[]): string[] {
  const dir = mkdtempSync(join(tmpdir(), 'nx-kcl-crd-fixed-'));
  return files.map((file, i) => {
    const copy = join(dir, `${i}-${basename(file)}`);
    copyFileSync(file, copy);
    execFileSync('yq', ['-i', SCALAR_PROPS, copy], { stdio: 'inherit' });
    return copy;
  });
}
