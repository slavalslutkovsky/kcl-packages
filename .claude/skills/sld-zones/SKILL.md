---
name: sld-zones
description: How second-level domains are modelled on this platform — the DnsZone XRD, its AWS Route53 and GCP Cloud DNS backends, the apex/record/TTL rules, backend parity invariants, and the registrar delegation step. Use when adding or changing a domain, a DNS record, packages/cloud/dns, or anything that emits DNS (EmailDomain).
when_to_use: Triggered by requests about domains, zones, DNS records, apex/wildcard names, nameserver delegation, Route53, Cloud DNS, DnsZone, or edits under packages/cloud/dns.
paths:
  - packages/cloud/dns/**
  - packages/cloud/email/**
---

# Second-level domains (SLDs)

One SLD = one `DnsZone` XR = one cloud zone plus every record inside it.

| Piece | Path |
| --- | --- |
| API (XRD) | `packages/cloud/dns/xrd/xrd.yaml` — `dnszones.cloud.example.org`, `cloud.example.org/v1alpha1`, kind `DnsZone`, **Namespaced** (`apiextensions.crossplane.io/v2`) |
| AWS backend | `packages/cloud/dns/aws` (project `dns-aws`) → Route53 `Zone` + one `Record` per `records[]` entry |
| GCP backend | `packages/cloud/dns/gcp` (project `dns-gcp`) → Cloud DNS `ManagedZone` + one `RecordSet` per entry |
| Examples | `packages/cloud/dns/xrd/examples/dns-aws.yaml`, `dns-gcp.yaml` |
| Providers | `packages/cloud/dns/xrd/providers.yaml`; regenerate schemas with `just seed-dns-providers` |

Backend selection is a label, not a field:

```yaml
  crossplane:
    compositionSelector:
      matchLabels:
        provider: aws        # aws | gcp
```

## The spec contract

Required: `region`, `domain`. Everything else defaults.

- `domain` — the apex, **no trailing dot** (`example.com`). gcp `rstrip(".")`s defensively; aws uses it verbatim.
- `region` — provider API region. Route53 and Cloud DNS are both global; the field exists for portability and **is ignored by both backends** (the Route53 models carry no `forProvider.region` at all).
- `records[]` — one entry per `(name, type)` pair; several `values` become one multi-value record set. `name` is relative to the apex, `"@"` or `""` means the apex itself. `ttl` defaults `300` (minimum 1). `type` ∈ `A AAAA CNAME TXT MX SRV CAA NS`. `values` needs `minItems: 1`.
- `deletionPolicy` — `Delete` (default) or `Orphan`. `Orphan` sets `spec.managementPolicies = ["Observe","Create","Update","LateInitialize"]` on **every** composed MR.
- `tags` — zone-level only: Route53 zone tags / Cloud DNS zone labels. Neither cloud's record resource accepts them, so tags never reach records.

Status: `ready` (true once `nameServers` is non-empty), `provider`, `zoneId`, `nameServers`, `arn` (AWS only), `id`, `cloud-url`. Printer columns: READY / PROVIDER / ZONE.

## Invariants — break these and the composition silently misbehaves

1. **Never declare apex `NS`/`SOA` in `records`.** Both clouds create and own them. `NS` entries are only for delegating a *child* zone beneath this SLD.
2. **The two backends must sanitize composition-resource-names identically.** aws `sanitize`/`res_name` (`dns.k`, character-set filter) and gcp `resource_name_for` (`regex.replace`) both produce `record-<name>-<type>` with `""`/`"@"` → `apex`, `*` → `wildcard`, everything outside `[a-z0-9-]` → `-`. A drift renames composed resources, and Crossplane answers a rename by **deleting and recreating the record**.
3. **FQDN shape differs on purpose.** AWS: `name.domain`, no trailing dot. GCP: trailing dot required — `example.com.`, `api.example.com.`.
4. **TXT quoting is GCP-only.** `txt_value` quotes each value once (Cloud DNS splits unquoted rdata on spaces) and leaves pre-quoted values alone. AWS takes rdata verbatim. MX/SRV priority stays inline in the value on both (`"10 mail.example.com"`).
5. **Records bind to their zone by controller ref**, never by id: `zoneIdSelector: {matchControllerRef: true}` (aws) / `managedZoneSelector: {matchControllerRef: true}` (gcp). This is what makes a record wait for its zone instead of racing it.
6. **GCP pins `crossplane.io/external-name` to the XR name**, because `ManagedZone` has no `forProvider.name`; that is why `status.zoneId` is known before creation. AWS reads `zoneId` back from `atProvider`.
7. Both backends emit the desired composite last: `items = dns.render(oxr) + [dns.status(oxr, ocds)]`, and `status()` reads the observed zone from `ocds["managed"]`.

## Delegation: the step no controller performs

A created zone does not make the SLD resolve. `status.nameServers` must be entered **at the registrar** for the apex domain. Report those name servers whenever a zone is created, and treat `status.ready == false` as "delegation not live yet".

Child zones are the mirror image: add an `NS` record in the parent `DnsZone`'s `records` pointing at the child zone's `status.nameServers`.

## Pairing with EmailDomain

`packages/cloud/email`'s `EmailDomain.status.dnsRecords` rows map one-to-one onto `records[]`: join the priority into the MX value, strip the domain suffix off the name.

## Tests

`packages/cloud/dns/gcp/dns_test.k` is the model: top-level `test_<subject> = lambda { assert … , "message" }`, private helpers `_build` (wraps a spec into a `DnsZone` named `demo`), `_recs` (`render(...)[1::]`), `_orphan`. It covers minimal render, record fan-out, empty-name-is-apex, ttl/type, multi-value rdata, TXT quoting, name sanitization, tags-zone-only, deletion policy, and status before/after observation.

**Gap to close, not work around: `packages/cloud/dns/aws` ships no `*_test.k`**, so `nx test dns-aws` asserts nothing. Any change to `dns-aws` must land with `packages/cloud/dns/aws/dns_test.k` mirroring that suite (apex handling, fan-out, `res_name` sanitization, ttl default, Orphan policy, status with and without observed name servers).

## Commands

```bash
nx run-many -t build test lint --projects=dns-aws,dns-gcp   # what CI runs for a DNS change
just render dns-aws                                          # render the example XR through function-kcl (docker)
just render dns-gcp --example=packages/cloud/dns/xrd/examples/dns-gcp.yaml
just seed-dns-providers                                      # regenerate aws-route53 / gcp-dns schema packages
just workload dns aws                                        # XRD + Compositions + providers + example on the kind cluster
```

## Workflows

`/sld-new` authors or changes a zone and proves it renders. `/sld-ship` takes it through the local gate onto the kind cluster and reports the name servers to delegate.
