/**
 * Refactoring findings over the scanned workspace.
 *
 * Every rule here is DETERMINISTIC and evidence-backed: it names a file that
 * proves it, and re-running the scan on an unchanged tree produces the same
 * list in the same order. That is the whole reason the portal can show these
 * next to an entity — a suggestion a reviewer cannot check is noise, and a
 * suggestion that changes between two runs of the same commit is worse.
 *
 * Judgement calls that need a human (is this abstraction right? should these
 * two modules merge?) are deliberately NOT here. An assistant can ask for them
 * through the MCP server, which hands it this same model plus the sources;
 * what gets committed is only what a rule can prove.
 */
import type { Finding, Severity, Workspace } from "./scan.ts";

/** The three public clouds a capability module can have a backend for. A
 *  module that implements two of them and skips the third is the parity gap
 *  this platform's XRDs exist to prevent; in-cluster backends (cnpg, velero,
 *  knative, rustfs…) are alternatives, not gaps. */
const clouds = ["aws", "azure", "gcp"];

const severityRank: Record<Severity, number> = { high: 0, medium: 1, low: 2 };

export function computeFindings(ws: Workspace): Finding[] {
  const out: Finding[] = [];
  const usageByKind = new Map(ws.usage.map((u) => [u.xrKind, u]));
  const xrdByKind = new Map(ws.xrds.map((x) => [x.xrKind, x]));

  // An API nobody implements cannot be claimed: the XRD installs, the claim
  // stays pending forever with no Composition to select.
  for (const xrd of ws.xrds) {
    const usage = usageByKind.get(xrd.xrKind)!;
    if (usage.compositions.length === 0) {
      out.push({
        rule: "xrd-without-composition",
        severity: "high",
        subject: xrd.xrKind,
        detail: `${xrd.xrKind} has an XRD but no Composition implements it; a claim would stay pending. Add a backend package or delete the XRD.`,
        evidence: xrd.file,
      });
    }
  }

  for (const comp of ws.compositions) {
    // The Composition's compositeTypeRef must resolve, or Crossplane rejects it.
    if (!xrdByKind.has(comp.compositeKind)) {
      out.push({
        rule: "composition-without-xrd",
        severity: "high",
        subject: comp.package,
        detail: `${comp.package} composes ${comp.compositeApiVersion} ${comp.compositeKind}, which has no XRD in this repo; Crossplane will not accept the Composition.`,
        evidence: comp.file,
      });
    }

    // The version invariant: composition.yaml's ?tag= and kcl.mod's version are
    // written together by nx release (tools/nx-kcl/src/release/version-actions.ts).
    // Drift means the cluster renders older code than the directory contains.
    if (comp.pinnedTag && comp.packageVersion && comp.pinnedTag !== comp.packageVersion) {
      out.push({
        rule: "composition-pin-drift",
        severity: "high",
        subject: comp.package,
        detail: `composition.yaml pins ?tag=${comp.pinnedTag} but kcl.mod is ${comp.packageVersion}; the cluster renders the older image. Let nx release rewrite both.`,
        evidence: comp.file,
      });
    }

    if (!comp.pinnedTag && comp.sourceImage.startsWith("oci://")) {
      out.push({
        rule: "composition-unpinned",
        severity: "medium",
        subject: comp.package,
        detail: `${comp.package} pulls ${comp.sourceImage} with no ?tag=, so every reconcile can pick up a different image. Pin the published version.`,
        evidence: comp.file,
      });
    }
  }

  // A backend with no example is a backend nobody rendered: `nx render` has
  // nothing to point at and the first user is the first test.
  const exampleBackends = new Set(ws.examples.map((e) => `${e.kind}/${e.backend}`));
  const exampleKinds = new Set(ws.examples.map((e) => e.kind));
  for (const comp of ws.compositions) {
    if (!comp.backend) continue;
    if (exampleBackends.has(`${comp.compositeKind}/${comp.backend}`)) continue;
    out.push({
      rule: "backend-without-example",
      severity: "medium",
      subject: comp.package,
      detail: `no example XR selects provider=${comp.backend} for ${comp.compositeKind}; add one under the module's xrd/examples/ so \`nx render ${comp.package}\` and the devkit examples row cover it.`,
      evidence: comp.file,
    });
  }
  for (const xrd of ws.xrds) {
    if (exampleKinds.has(xrd.xrKind)) continue;
    if (usageByKind.get(xrd.xrKind)!.compositions.length === 0) continue; // already reported, harder
    out.push({
      rule: "xrd-without-example",
      severity: "medium",
      subject: xrd.xrKind,
      detail: `${xrd.xrKind} has Compositions but no example XR; nothing renders it locally or in the devkit examples wave.`,
      evidence: `${xrd.root}/examples/`,
    });
  }

  // Backend parity: the portable XRD is the promise that a claim moves between
  // clouds. Two of three implemented is a promise the third cloud cannot keep.
  for (const xrd of ws.xrds) {
    const backends = new Set(usageByKind.get(xrd.xrKind)!.backends);
    const present = clouds.filter((c) => backends.has(c));
    const missing = clouds.filter((c) => !backends.has(c));
    if (present.length >= 2 && missing.length > 0) {
      out.push({
        rule: "backend-parity-gap",
        severity: "medium",
        subject: xrd.xrKind,
        detail: `${xrd.xrKind} is implemented on ${present.join(", ")} but not ${missing.join(", ")}; a claim that moves clouds stops working there.`,
        evidence: xrd.file,
      });
    }
  }

  // An XRD the cluster never installs is unreachable, however good it is.
  for (const xrd of ws.xrds) {
    if (usageByKind.get(xrd.xrKind)!.devkitRows > 0) continue;
    out.push({
      rule: "module-not-installed",
      severity: "medium",
      subject: xrd.xrKind,
      detail: `no devkit.toml row installs packages/*/${xrd.module}/; the XRD and its Compositions never reach the e2e cluster. Add the xrd/providers/composition/examples rows.`,
      evidence: "devkit.toml",
    });
  }

  // Generated provider schema packages are free to keep but not free to read:
  // one nobody imports is dead weight in the graph and in every release scan.
  for (const pkg of ws.packages) {
    if (pkg.kind !== "provider" || pkg.dependents.length > 0) continue;
    out.push({
      rule: "unused-provider-package",
      severity: "low",
      subject: pkg.name,
      detail: `no package imports ${pkg.name}; drop it from packages/providers or the registry.yaml row that regenerates it.`,
      evidence: `${pkg.root}/kcl.mod`,
    });
  }

  // Composition logic with no tests is logic whose only check is a cluster.
  for (const pkg of ws.packages) {
    if (pkg.kind !== "function" || pkg.hasTests) continue;
    out.push({
      rule: "composition-without-tests",
      severity: "medium",
      subject: pkg.name,
      detail: `${pkg.name} renders Kubernetes objects with no *_test.k; \`kcl test\` passes vacuously and nx caches that pass.`,
      evidence: `${pkg.root}/`,
    });
  }

  // Sorted by severity, then rule, then subject: the file is committed, so a
  // stable order keeps the diff to what actually changed.
  return out.sort(
    (a, b) =>
      severityRank[a.severity] - severityRank[b.severity] ||
      a.rule.localeCompare(b.rule) ||
      a.subject.localeCompare(b.subject),
  );
}
