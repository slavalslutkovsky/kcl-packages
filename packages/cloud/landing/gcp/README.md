# landing-gcp

GCP backend for the `LandingPage` XR (`cloud.example.org/v1alpha1`,
Composition `landing-gcp`, label `provider: gcp`). Typed against the
`gcp-storage` and `gcp-compute` schema packages under
[packages/providers/](../../../providers/). It composes a public GCS bucket
with one `BucketObject` per document and, with the CDN on, a global external
Application Load Balancer (`BackendBucket` with Cloud CDN → `URLMap` → target
proxy → `GlobalForwardingRule` on a `GlobalAddress`) with a Google-managed
certificate for the custom domain. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/landing-gcp`.

DNS is not composed: `status.dnsTarget` is the global address IP and
`status.dnsRecordType` is `A`. No validation records are needed — the
certificate validates through the load balancer. See
[docs/landing.md](../../../../docs/landing.md).

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `managed` | `Bucket` (`storage.gcp.m.upbound.io`) | always | external-name pinned to the XR name; `uniformBucketLevelAccess`, `forceDestroy`, `website.mainPageSuffix` / `notFoundPage` |
| `iam-public` | `BucketIAMMember` | always | `allUsers` → `roles/storage.objectViewer` |
| `object-index` | `BucketObject` | always | `content.html` at `content.index`, `text/html` |
| `object-<slug>` | `BucketObject` | per `content.files[]` | slug: path lowercased, `[^a-z0-9-]` → `-`; renaming deletes and recreates |
| `backend-bucket` | `BackendBucket` (`compute.gcp.m.upbound.io`) | `cdn.enabled` | `enableCdn`, `CACHE_ALL_STATIC`, `maxTtl` 86400 |
| `url-map` | `URLMap` | `cdn.enabled` | every path to the backend bucket |
| `address` | `GlobalAddress` | `cdn.enabled` | `EXTERNAL`; the A-record target |
| `certificate` | `ManagedSSLCertificate` | `cdn.enabled`, `domain`, `tls.enabled` | `managed.domains: [domain]` |
| `https-proxy` | `TargetHTTPSProxy` | same as `certificate` | |
| `http-proxy` | `TargetHTTPProxy` | `cdn.enabled` without domain or with `tls.enabled: false` | plain HTTP |
| `forwarding-rule` | `GlobalForwardingRule` | `cdn.enabled` | port `443` with HTTPS, else `80`; `EXTERNAL_MANAGED` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `metadata.name` | bucket name |
| `region` | `Bucket.forProvider.location` |
| `domain` | `ManagedSSLCertificate.managed.domains` |
| `content.html` / `content.index` | index object; `website.mainPageSuffix` |
| `content.errorDocument` | `website.notFoundPage` |
| `content.files[]` | one `BucketObject` each; `contentType` explicit or derived from the extension (shared table, `application/octet-stream` otherwise) |
| `cdn.enabled` (default `true`) | load balancer stack, or the bucket endpoint only |
| `cdn.ttlSeconds` (default `3600`) | `cdnPolicy.defaultTtl` / `clientTtl`; object `cacheControl: public, max-age=<ttl>` |
| `tls.enabled` (default `true`) | HTTPS proxy on 443 vs HTTP proxy on 80 |
| `deletionPolicy: Orphan` | `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | bucket `labels` |

Ignored: `resourceGroup`, `cdn.priceClass`, `tls.issuer`, `ingressClassName`,
`replicas`. Rejected (render fails): `domain` with `cdn.enabled: false`.

Status written back: `provider: gcp`, `bucketName`, `cdn`, `cloud-url`;
`ready` once the forwarding rule has an IP (bucket exists, without CDN);
`host` / `url` (custom domain, the address, or
`https://storage.googleapis.com/<bucket>/<index>` without CDN); with the CDN
`dnsRecordType: A`, `dnsTarget` (observed address) and `id` (forwarding rule).
`validationRecords` and `certificateStatus` are never set.

## Usage

`kcl run` with no options renders the built-in `_example` XR (no domain, so
`http-proxy` on port 80):

```bash
kcl run packages/cloud/landing/gcp

# a real XR: params is {oxr, ocds}, as function-kcl passes it
kcl run packages/cloud/landing/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/landing/xrd/examples/landing-gcp.yaml)}"
```

Output is `items:` — the managed resources, then the `LandingPage` carrying
status. `render` reads only the XR; `ocds` feeds `status` alone.

Through function-kcl (needs docker): `pnpm exec nx run landing-gcp:render`.
On a cluster: `just install-module landing`, `just e2e landing` (needs GCP
credentials in a ProviderConfig of your own).

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `landing.k` | `render(oxr)` and `status(oxr, ocds)` |
| `landing_test.k` | `kcl test` cases |
| `composition.yaml` | the `landing-gcp` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run landing-gcp:test     # kcl test
pnpm exec nx run landing-gcp:lint     # kcl lint
pnpm exec nx run landing-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
