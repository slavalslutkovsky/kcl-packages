import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * `kcl import -m crd` translates a CRD's CEL presence test (`has(self.x)`) into
 * `(x != None)`. An optional attribute that is not set is `Undefined`, not
 * `None`, and `Undefined != None` is true, so every such check fails on an
 * object that leaves the field unset: an HTTPRoute filter of type
 * RequestHeaderModifier is rejected because its unset `responseHeaderModifier`
 * counts as present. Rewrites the test to the presence check the generated
 * schemas use everywhere else, `x not in [None, Undefined]`.
 */
export function fixPresenceChecks(source: string): string {
  return source.replace(/\((\w+) != None\)/g, '($1 not in [None, Undefined])');
}

/** Applies {@link fixPresenceChecks} to every `.k` file under `dir`; returns the files changed. */
export function fixPresenceChecksIn(dir: string): string[] {
  const changed: string[] = [];
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) {
      changed.push(...fixPresenceChecksIn(path));
    } else if (entry.endsWith('.k')) {
      const before = readFileSync(path, 'utf8');
      const after = fixPresenceChecks(before);
      if (after !== before) {
        writeFileSync(path, after);
        changed.push(path);
      }
    }
  }
  return changed;
}
