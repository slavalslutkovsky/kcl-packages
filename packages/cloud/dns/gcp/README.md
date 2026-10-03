# dns-gcp

GCP backend for the `DnsZone` XR (`cloud.example.org/v1alpha1`): a public
Cloud DNS managed zone plus one multi-value record set per `spec.records[]`
entry. Typed against the vendored `gcp-dns` schema package
([../../../providers/gcp-dns](../../../providers/gcp-dns)). The `dns-gcp`
Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/dns-gcp`, followed by `function-auto-ready`.

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `ManagedZone` (`dns.gcp.m.upbound.io`) | always | composition-resource-name `managed`; the zone name is the `crossplane.io/external-name`, pinned to the XR name; description `DnsZone <xr> (managed by Crossplane)` |
| `RecordSet` (`dns.gcp.m.upbound.io`) | one per `spec.records[]` entry | binds the zone with `managedZoneSelector.matchControllerRef`, so it waits for the zone. Resource name `record-<name>-<type>` (see below) |

Record resource names are lowercased; `@`/`""` become `apex`, `*` becomes
`wildcard`, anything else outside `[a-z0-9-]` becomes `-`
(`_dmarc` TXT → `record--dmarc-txt`). The same rule lives in
[../aws/](../aws/); keep them in lockstep.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `domain` | `ManagedZone.forProvider.dnsName` with the trailing dot Cloud DNS requires (a trailing dot in the input is stripped first); record names become FQDNs with a trailing dot (`api` → `api.example.com.`, `@`/`""` → `example.com.`) |
| `records[].name` / `.type` | `RecordSet.forProvider.name` / `.type` |
| `records[].ttl` | `RecordSet.forProvider.ttl`, `300` when unset |
| `records[].values` | `RecordSet.forProvider.rrdatas`; TXT values are wrapped in quotes once (already-quoted values are left alone), everything else passes verbatim |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR; otherwise the schema default `['*']` |
| `tags` | `ManagedZone.forProvider.labels` only; `RecordSet` has no labels field |
| `region` | ignored: Cloud DNS is global |

Status written back to the XR:

| status | value |
| --- | --- |
| `provider` | `gcp` |
| `ready` | `true` once the zone reports `nameServers` |
| `zoneId` | the XR name (the zone name), set before the zone exists |
| `nameServers` | delegation set to put at the registrar; `[]` until observed |
| `cloud-url` | Cloud DNS console link for the zone, with `?project=<p>` once `atProvider.project` is observed |
| `id` | `atProvider.id` once observed |

`arn` is never set (AWS only).

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`example.com`, no records):

```bash
kcl run packages/cloud/dns/gcp
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`;
`ocds` may be omitted), so a real XR renders like this:

```bash
kcl run packages/cloud/dns/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/dns/xrd/examples/dns-gcp.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/dns-gcp.yaml](../xrd/examples/dns-gcp.yaml)):

```bash
pnpm exec nx run dns-gcp:render
```

On a cluster: `just e2e dns` (Kind, Crossplane, local registry, providers,
examples), or `just install-module dns` to apply the XRD and both Compositions
repointed at the local registry.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `dns.k` | `render` (ManagedZone + RecordSets), `status`, helpers `resource_name_for` / `fqdn_for` / `txt_value` |
| `dns_test.k` | `kcl test` cases: record fan-out, FQDNs, TXT quoting, name sanitization, labels, deletion policy, status |
| `composition.yaml` | `dns-gcp` Composition (`provider: gcp` label) |

## Development

```bash
pnpm exec nx run dns-gcp:test     # kcl test
pnpm exec nx run dns-gcp:lint     # kcl lint
pnpm exec nx run dns-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
