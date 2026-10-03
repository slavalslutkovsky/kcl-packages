# Landing page

One `LandingPage` XR is a static page **and** the edge that serves it. The HTML
lives in the XR, so a landing page is a reviewable object, not a build
pipeline: no CI job, no artifact, no bucket sync.

```
kubectl -n default apply -f packages/cloud/landing/xrd/examples/landing-onprem.yaml
kubectl -n default get landingpage
NAME                  READY   PROVIDER   URL                     DNS-TARGET
acme-landing-onprem   true    onprem     https://acme.internal
```

Backend selection is a label, not a field — the same rule as every other
module:

```yaml
  crossplane:
    compositionSelector:
      matchLabels:
        provider: aws        # aws | gcp | azure | onprem
```

## The tool map

A static page on a custom domain is never one service. Every cloud needs three
things — somewhere to keep the bytes, something that can terminate TLS in
front of them, and a certificate that thing will accept — and the three are
different products with different names in each cloud. That mapping *is* this
module:

| concern | aws | gcp | azure | onprem |
|---|---|---|---|---|
| content store | S3 `Bucket` | Cloud Storage `Bucket` | `Account` (static website) | `ConfigMap` (in the Release's `extraDeploy`) |
| the files | S3 `Object` per file | `BucketObject` per file | `Blob` per file, in `$web` | ConfigMap keys |
| public read | none — bucket stays private, `BucketPolicy` trusts only the distribution | `BucketIAMMember` `allUsers:objectViewer` | account static website endpoint | the Service |
| origin identity | `OriginAccessControl` (sigv4) | n/a — `BackendBucket` reads the bucket directly | n/a — Front Door reads the public web endpoint | n/a |
| edge / cache | `Distribution` (CloudFront) | `BackendBucket` + `URLMap` + target proxy + `GlobalForwardingRule` + `GlobalAddress` | `FrontdoorProfile` + `FrontdoorEndpoint` + `FrontdoorOriginGroup` + `FrontdoorOrigin` + `FrontdoorRoute` | nginx `Ingress` (chart values) |
| certificate | ACM `Certificate`, DNS-validated, **us-east-1** | `ManagedSSLCertificate` | `FrontdoorCustomDomain` managed certificate | cert-manager, through the Ingress annotation |
| custom domain | distribution `aliases` | certificate `managed.domains` | `FrontdoorCustomDomain.hostName` | `ingress.hostname` |
| what DNS points at | distribution domain (`CNAME`) | global address IP (`A`) | endpoint host (`CNAME`) | the ingress controller's address |
| provider package | `provider-aws-s3`, `provider-aws-cloudfront`, `provider-aws-acm` | `provider-gcp-storage`, `provider-gcp-compute` | `provider-azure-storage`, `provider-azure-cdn` | `provider-helm` |

Two consequences worth stating out loud, because they are the reason the XRD
looks the way it does:

1. **`cdn.enabled: false` costs you the domain.** None of the three clouds can
   put a custom domain or a certificate on a raw bucket endpoint — that is what
   the CDN is for. So all three backends reject `spec.domain` together with
   `cdn.enabled: false` instead of silently serving the page at an address
   nobody asked for.
2. **The onprem backend has no CDN knob at all.** Its `Ingress` *is* the edge.
   `cdn.enabled` is ignored there, and `cdn.ttlSeconds` becomes a
   `Cache-Control` header rather than an edge policy.

## What renders to what

The full per-field tables live next to the code (each backend's `landing.k` is
commented field by field). The shape is the same everywhere:

| `LandingPage` field | aws | gcp | azure | onprem |
|---|---|---|---|---|
| `region` | `Bucket.forProvider.region` | `Bucket.forProvider.location` | `Account.forProvider.location` | ignored |
| `domain` | distribution `aliases` + ACM `domainName` | `ManagedSSLCertificate.managed.domains` | `FrontdoorCustomDomain.hostName` | `ingress.hostname` |
| `resourceGroup` | ignored | ignored | `Account`/`FrontdoorProfile` `resourceGroupName` (**required**) | ignored |
| `content.html` | `Object` at `content.index` | `BucketObject` at `content.index` | `Blob` at `content.index` | ConfigMap key `content.index` |
| `content.index` | `defaultRootObject` (+ website `indexDocument.suffix` with no CDN) | `website.mainPageSuffix` | `staticWebsite.indexDocument` | nginx `index` |
| `content.errorDocument` | `customErrorResponse` (only when the file exists) | `website.notFoundPage` | `staticWebsite.error404Document` | nginx `error_page 404` |
| `content.files[]` | one `Object` each | one `BucketObject` each | one `Blob` each | one ConfigMap key each |
| `cdn.enabled` | Distribution + OAC + policy, or website config | LB stack, or nothing | Front Door stack, or nothing | ignored |
| `cdn.ttlSeconds` | `defaultCacheBehavior.defaultTtl` | `cdnPolicy.defaultTtl`/`clientTtl` + object `cacheControl` | blob `Cache-Control` | `add_header Cache-Control` |
| `cdn.priceClass` | `PriceClass_100` / `_200` / `_All` | ignored | ignored | ignored |
| `tls.enabled` | `viewerCertificate` + `redirect-to-https`; **false with a domain is rejected** | HTTPS proxy on 443 vs HTTP proxy on 80 (no certificate) | route `httpsRedirectEnabled`; the managed certificate stays | `ingress.tls` + the issuer annotation |
| `tls.issuer` | ignored | ignored | ignored | `cert-manager.io/cluster-issuer` annotation |
| `ingressClassName`, `replicas` | ignored | ignored | ignored | `ingress.ingressClassName`, `replicaCount` |
| `deletionPolicy: Orphan` | `managementPolicies` on every MR | same | same | ignored (the Release dies with the XR) |
| `tags` | MR `tags` | bucket `labels` | MR `tags` | `podLabels` |

### Content types are a parity invariant

`content.files[].contentType` is optional: every cloud backend derives it from
the path extension with **the same table** —

```
html htm -> text/html      css -> text/css          js mjs -> text/javascript
json -> application/json   svg -> image/svg+xml     png -> image/png
jpg jpeg -> image/jpeg     gif -> image/gif         webp -> image/webp
ico -> image/x-icon        txt -> text/plain        xml -> application/xml
woff2 -> font/woff2        anything else -> application/octet-stream
```

— and `content.html` is always `text/html`. A drift between two backends is a
bug: the same XR would serve a stylesheet as `text/css` on one cloud and as a
download on another. Each backend's `landing_test.k` pins the table.

Object names are equally load-bearing. Each file becomes a composed resource
named `object-<slug>` (`blob-<slug>` on azure), where `slug` is the path
lowercased with every character outside `[a-z0-9-]` replaced by `-`. Crossplane
answers a renamed composed resource by deleting and recreating it, so that
function is part of the contract, not an implementation detail.

Two honest exceptions live on the onprem backend, both asserted rather than
silently absorbed:

- **`content.files[].path` may not contain `/`.** The content is one ConfigMap
  and a ConfigMap key cannot hold a path separator. Flatten the path
  (`assets/logo.svg` → `assets-logo.svg`) for a page that must render
  everywhere, or keep the asset in a `Bucket` XR.
- **`content.files[].contentType` is ignored.** nginx answers from its own
  `mime.types`, keyed on the same extension the cloud backends derive from, and
  a per-file override would need one `location` block per file.

## The steps no controller performs

**Delegation.** A created edge does not make the domain resolve. Read
`status.dnsTarget` and `status.dnsRecordType` and put that record in the
`DnsZone` (`cloud.example.org/v1alpha1`) that owns the apex — the two XRs are
deliberately separate so deleting a page can never delete a zone:

```yaml
  records:
    - name: www
      type: CNAME                # status.dnsRecordType
      values: ["d111111abcdef8.cloudfront.net"]   # status.dnsTarget
```

**Certificate validation.** On aws and azure the managed certificate is issued
only after an ownership record exists, and the certificate is what the edge
waits on. `status.validationRecords` carries exactly those rows (ACM's
DNS-validation `CNAME`s, Front Door's `_dnsauth` `TXT`) — add them to the same
`DnsZone`. GCP needs none: a Google-managed certificate validates through the
load balancer that serves it, which is why `status.validationRecords` is absent
there.

Until both are in place `status.ready` stays false. `status.certificateStatus`
says why on aws (ACM's `PENDING_VALIDATION` → `ISSUED`); gcp and azure do not
report it, because neither generated schema exposes a certificate state —
`ManagedSSLCertificate` observes only `certificateId`/`expireTime`, and
`FrontdoorCustomDomain` only `validationToken`/`expirationDate`.

## Ordering the backends cannot avoid

Three things cannot be rendered in the first pass. Each appears one reconcile
later, once the value it needs has been observed:

| second pass | needs | why it cannot be a reference |
|---|---|---|
| aws distribution `aliases` + `viewerCertificate` | ACM certificate ARN | `viewerCertificate.acmCertificateArn` is a plain string — the generated schema has no `…ArnRef`/`…ArnSelector`. Until the ARN is known the distribution carries `cloudfrontDefaultCertificate: true` and no alias, because CloudFront rejects an alternate domain name no certificate covers. |
| aws `bucket-policy` | distribution ARN | The policy's `AWS:SourceArn` condition names the distribution. Before then the bucket has no policy at all — the safe state: nothing is readable. |
| azure `frontdoor-origin` (and the `frontdoor-route` that needs it) | the account's static-website host | `FrontdoorOrigin.hostName` is a plain string, and `<account>.z<NN>.web.core.windows.net` carries a region-assigned `z<NN>` segment that cannot be derived. |

This is the same shape as `packages/cloud/cluster/onprem` rendering
`flux2-sync` only once `flux2` is deployed: `render(oxr, ocds)` reads the
observed composed resources, and the extra objects appear on the next
reconcile.

Two asserts exist on aws for the same reason — a field that cannot take effect
must fail loudly, not quietly: `spec.domain` requires `cdn.enabled: true`
(S3's website endpoint answers only on its own name) **and**
`tls.enabled: true` (CloudFront will not take an alias without a certificate).
azure asserts `spec.resourceGroup`, and that the XR name is a legal Storage
Account name (`^[a-z0-9]{3,24}$`) — the account name is pinned to it because
the blob endpoint and the Front Door origin host are derived from it.

## Files

| path | what |
|---|---|
| `packages/cloud/landing/xrd/xrd.yaml` | the API: `landingpages.cloud.example.org`, Namespaced, v1alpha1 |
| `packages/cloud/landing/xrd/models/` | generated schemas (`just xrd-schema landing`) — never hand-edited |
| `packages/cloud/landing/xrd/providers.yaml` | the eight Providers, plus provider-helm's RBAC |
| `packages/cloud/landing/xrd/providerconfigs.yaml` | the helm `ClusterProviderConfig`; cloud credentials are yours to add |
| `packages/cloud/landing/xrd/examples/` | one XR per backend |
| `packages/cloud/landing/aws/landing.k` | S3 + Objects + OAC + Distribution + ACM (+ the second-pass policy) |
| `packages/cloud/landing/gcp/landing.k` | GCS + BucketObjects + BackendBucket + URLMap + proxy + address + forwarding rule |
| `packages/cloud/landing/azure/landing.k` | Account static website + `$web` Blobs + Front Door stack |
| `packages/cloud/landing/onprem/landing.k` | one provider-helm `Release` of the nginx chart |
| `packages/providers/registry.yaml` | the rows `just providers-check` matches against the above (`aws-cloudfront`, `aws-acm`, `azure-cdn` are new; five existing rows gained `landing`) |
| `devkit.toml` | the `landing-*` deps rows: XRD wave 2, providers 3, Compositions 4, examples 5 |

## Commands

```bash
nx run-many -t build test lint --projects=landing-xrd,landing-aws,landing-gcp,landing-azure,landing-onprem
just render landing-onprem                 # render the example XR through function-kcl (docker)
just render landing-aws --example=packages/cloud/landing/xrd/examples/landing-aws.yaml
just xrd-schema landing                    # regenerate xrd/models after an XRD change
just seed-landing-providers                # regenerate the edge schema packages
just workload landing onprem               # XRD + Compositions + providers + example on the kind cluster
kubectl -n default get landingpage,release
```

## Not covered on purpose

- **No build step.** The XR carries text. A page that needs a bundler belongs
  behind a `Component` (Flux artifact) or a `ServerlessApp`, not here.
- **No large or binary assets.** They would live in the XR's YAML and in every
  audit log of it. Put them in a `Bucket` XR and reference them by URL.
- **No WAF, no logging, no cache invalidation, no rule sets.** Each is a
  separate product per cloud with no portable middle ground; adding one would
  make the XRD a union of three vendor APIs.
- **No pricing.** `packages/platform/pricing` has no rate card for CDN traffic
  — egress is deliberately unpriced repo-wide (`docs/pricing.md`).
