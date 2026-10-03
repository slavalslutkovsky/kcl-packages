# landing-aws

AWS backend for the `LandingPage` XR (`cloud.example.org/v1alpha1`,
Composition `landing-aws`, label `provider: aws`). Typed against the
`aws-s3`, `aws-cloudfront` and `aws-acm` schema packages under
[packages/providers/](../../../providers/). It composes an S3 bucket holding
the page, one `Object` per document, and a CloudFront `Distribution` that
reads the private bucket through an Origin Access Control; a custom domain
gets a DNS-validated ACM certificate in us-east-1. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/landing-aws`.

DNS is not composed: `status.dnsTarget` / `status.dnsRecordType` say which
record must point at the distribution, `status.validationRecords` which records
ACM needs before it issues the certificate. See
[docs/landing.md](../../../../docs/landing.md).

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `managed` | `Bucket` (`s3.aws.m.upbound.io`) | always | external-name pinned to the XR name, so the XR name must be a globally unique bucket name |
| `public-access-block` | `BucketPublicAccessBlock` | always | all four blocks on with the CDN, off without |
| `ownership` | `BucketOwnershipControls` | always | `BucketOwnerEnforced` (ACLs disabled) |
| `object-index` | `Object` | always | `content.html` at `content.index`, `text/html` |
| `object-<slug>` | `Object` | per `content.files[]` | slug: path lowercased, `[^a-z0-9-]` → `-`; renaming deletes and recreates |
| `oac` | `OriginAccessControl` (`cloudfront.aws.m.upbound.io`) | `cdn.enabled` | sigv4, `always` |
| `certificate` | `Certificate` (`acm.aws.m.upbound.io`) | `cdn.enabled` and `domain` | region `us-east-1`, `validationMethod: DNS` |
| `distribution` | `Distribution` | `cdn.enabled` | aliases + ACM viewer certificate only once the certificate ARN is observed (second pass); before that `cloudfrontDefaultCertificate: true`. `waitForDeployment: false` |
| `bucket-policy` | `BucketPolicy` (`s3.aws.m.upbound.io`) | `cdn.enabled` and the distribution ARN is observed | `s3:GetObject` for `cloudfront.amazonaws.com` conditioned on `AWS:SourceArn` |
| `website` | `BucketWebsiteConfiguration` | `cdn.enabled: false` | `indexDocument`, `errorDocument` |
| `bucket-policy` | `BucketPolicy` | `cdn.enabled: false` | public `s3:GetObject` for the website endpoint |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `metadata.name` | bucket name; OAC name `<name>-oac`; origin id `s3-<name>` |
| `region` | `forProvider.region` on the bucket and every bucket-bound MR; origin `<bucket>.s3.<region>.amazonaws.com` |
| `domain` | distribution `aliases`, ACM `domainName` |
| `content.html` / `content.index` | index `Object`; `defaultRootObject`; website `indexDocument.suffix` without CDN |
| `content.errorDocument` | `customErrorResponse` 404 only when a file with that path exists; website `errorDocument.key` without CDN |
| `content.files[]` | one `Object` each; `contentType` explicit or derived from the extension (shared table, `application/octet-stream` otherwise) |
| `cdn.enabled` (default `true`) | CloudFront path vs. S3 website path |
| `cdn.ttlSeconds` (default `3600`) | `defaultCacheBehavior.defaultTtl`; `maxTtl` fixed at one year |
| `cdn.priceClass` | `cheapest`/`most`/`all` → `PriceClass_100`/`_200`/`_All` |
| `tls.enabled` (default `true`) | `redirect-to-https` vs `allow-all` |
| `deletionPolicy: Orphan` | `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | bucket, certificate and distribution `tags` |

Ignored: `resourceGroup`, `tls.issuer`, `ingressClassName`, `replicas`.
Rejected (render fails): `domain` with `cdn.enabled: false`, and `domain` with
`tls.enabled: false`.

Status written back: `provider: aws`, `bucketName`, `cdn`; with the CDN,
`ready` (distribution `status == "Deployed"`), `host` / `dnsTarget` (distribution
domain, `CNAME`), `url`, `arn`, `id`, `cloud-url`; without it, the
`<bucket>.s3-website-<region>.amazonaws.com` endpoint over `http://`.
`validationRecords` from ACM's `domainValidationOptions`; `certificateStatus`
from the observed ACM status.

## Usage

`kcl run` with no options renders the built-in `_example` XR (no domain):

```bash
kcl run packages/cloud/landing/aws

# a real XR: params is {oxr, ocds}, as function-kcl passes it
kcl run packages/cloud/landing/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/landing/xrd/examples/landing-aws.yaml)}"
```

Output is `items:` — the managed resources, then the `LandingPage` carrying
status. Add `"ocds": {...}` (observed composed resources keyed by
composition-resource-name) to `params` to render the second pass.

Through function-kcl (needs docker): `pnpm exec nx run landing-aws:render`.
On a cluster: `just install-module landing`, `just e2e landing` (needs AWS
credentials in a ProviderConfig, valid in us-east-1 too).

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `landing.k` | `render(oxr, ocds)` and `status(oxr, ocds)` |
| `landing_test.k` | `kcl test` cases: resource set, OAC, cache behaviour, second passes, content types, slugs |
| `composition.yaml` | the `landing-aws` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run landing-aws:test     # kcl test
pnpm exec nx run landing-aws:lint     # kcl lint
pnpm exec nx run landing-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
