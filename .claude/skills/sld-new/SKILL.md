---
name: sld-new
description: Author or change a second-level domain (DnsZone XR) and prove it renders on the chosen backend before it reaches a cluster.
argument-hint: "<domain> [aws|gcp] [manifest-path]"
arguments: domain backend manifest
disable-model-invocation: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash(just render:*)
  - Bash(just yaml-check:*)
  - Bash(node_modules/.bin/nx run-many:*)
  - Bash(node_modules/.bin/nx run:*)
  - Bash(yq:*)
---

# Add / change a second-level domain

Domain: `$domain` · backend: `$backend` (default `aws`) · manifest: `$manifest` (default `packages/cloud/dns/xrd/examples/dns-$backend.yaml`).

Read the `sld-zones` skill before editing — the apex, sanitization and TXT-quoting rules there are the ones that break silently.

## Current DNS surface

!`ls packages/cloud/dns packages/cloud/dns/xrd/examples 2>/dev/null`

## Steps

1. **Resolve the target manifest.** If `$manifest` was given, edit that file. Otherwise work in `packages/cloud/dns/xrd/examples/dns-$backend.yaml`, and if the request describes a *new, separate* zone rather than a change to the example, create `packages/cloud/dns/xrd/examples/dns-$backend-<zone-slug>.yaml` — the render executor resolves any `dns-<backend>*` name, and `just e2e-apply dns` applies the whole examples directory.

2. **Write the XR.** Required shape:

   ```yaml
   apiVersion: cloud.example.org/v1alpha1
   kind: DnsZone
   metadata:
     namespace: default
     name: <rfc-1123 label, becomes the GCP zone name>
   spec:
     region: <api region; ignored by both backends, still required by the XRD>
     domain: $domain          # apex, no trailing dot
     records: []              # one entry per (name, type)
     deletionPolicy: Delete   # Orphan keeps the cloud zone on XR deletion
     tags: {}
     crossplane:
       compositionSelector:
         matchLabels:
           provider: $backend
   ```

   Rules to apply while writing records, not after:
   - `"@"` or `""` = apex. No apex `NS`/`SOA` entries — the cloud owns them.
   - One entry per `(name, type)`; multiple `values` = one multi-value record set.
   - MX/SRV priority is inline in the value: `"10 mail.example.com"`.
   - TXT values go in unquoted; the gcp backend quotes them, aws passes them verbatim.
   - `ttl` only when it differs from the 300 default.

3. **Parse-check** the file: `just yaml-check <path>` (the PostToolUse hook already did this if you wrote it with Edit/Write — do not repeat it then).

4. **Render it through the real Composition** (needs docker; starts/reuses the `nx-kcl-render` function container):

   ```bash
   just render dns-$backend --example=<path>
   ```

   Verify in the output: one zone resource annotated `krm.kcl.dev/composition-resource-name: managed`, one record resource per entry named `record-<sanitized>-<type>`, the FQDN form matching the backend (trailing dot on gcp only), and the desired composite carrying `status.provider`.

5. **Run the unit suites** for whatever you touched in `dns.k`:

   ```bash
   node_modules/.bin/nx run-many -t build test lint --projects=dns-aws,dns-gcp
   ```

   If you changed `packages/cloud/dns/aws/dns.k`, that package has no test file — add `packages/cloud/dns/aws/dns_test.k` mirroring `packages/cloud/dns/gcp/dns_test.k` for the behaviour you changed. Do not ship an aws logic change without it.

6. **Keep the backends in lockstep.** If you changed name sanitization, FQDN construction, the record fan-out or the status shape on one backend, diff it against the other and state explicitly whether the divergence is intentional (trailing dots and TXT quoting are; resource names are not).

7. **Report** the rendered record set and the delegation step: the zone only answers once `status.nameServers` is entered at the registrar for `$domain`. Do not claim the domain works.

Do not apply anything to a cluster here — that is `/sld-ship`.
