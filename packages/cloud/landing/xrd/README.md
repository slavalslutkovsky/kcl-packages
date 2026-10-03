# landing-xrd

The `LandingPage` XRD (`landingpages.cloud.example.org`, group
`cloud.example.org`, version `v1alpha1`, `Namespaced`): a static page plus
the edge that serves it. The HTML lives in the XR, so there is no build
pipeline, artifact or bucket sync. `models/` holds the KCL schemas generated
from `xrd.yaml` by `just xrd-schema landing`; do not edit them by hand.
Import the composite type as
`landing_xrd.models.v1alpha1.cloud_example_org_v1alpha1_landing_page`.

The XR picks its backend with a label, not a spec field:
`spec.crossplane.compositionSelector.matchLabels.provider: aws | gcp | azure | onprem`.
The per-cloud tool map and the reasoning behind it are in
[docs/landing.md](../../../../docs/landing.md).

## Spec

| field | type | required | default | meaning |
| --- | --- | :-: | --- | --- |
| `region` | string | ✓ | | Region of the content store (S3 bucket / GCS location / Storage Account location). The aws ACM certificate is always us-east-1. Ignored by onprem |
| `domain` | string | | | Custom FQDN. Unset: the backend's own endpoint is the only address, and onprem publishes no Ingress |
| `resourceGroup` | string | | | azure only, required there: existing resource group for the Storage Account and Front Door profile |
| `content` | object | ✓ | | `html` (required, index document verbatim), `index` (`index.html`), `errorDocument` (`404.html`, served only if a file with that path exists), `files[]` of `{path, content, contentType?}` |
| `cdn` | object | | | `enabled` (`true`), `ttlSeconds` (`3600`), `priceClass` (`cheapest` \| `most` \| `all`, default `cheapest`; aws only). `enabled: false` on a cloud backend rejects `domain` |
| `tls` | object | | | `enabled` (`true`), `issuer` (`letsencrypt-prod`, onprem cert-manager ClusterIssuer). Ignored without `domain` |
| `ingressClassName` | string | | `nginx` | onprem only |
| `replicas` | integer ≥ 1 | | `2` | onprem only: nginx replicas |
| `deletionPolicy` | `Delete` \| `Orphan` | | `Delete` | `Orphan` sets `managementPolicies` on every MR; ignored by onprem |
| `tags` | map | | | AWS/Azure tags, GCP bucket labels, onprem pod labels |

`content.files[].contentType` defaults to a type derived from the path
extension, with the same table on every cloud backend; onprem ignores it and
rejects a `path` containing `/`.

An absent `cdn` or `tls` object gets no XRD defaults (the API server only fills
fields of a block that is present), so each backend re-applies them itself;
`xrd_test.k` pins this.

Status: `ready`, `provider`, `url`, `host`, `dnsTarget`, `dnsRecordType`,
`validationRecords[]` (`name`, `type`, `value`), `certificateStatus`,
`bucketName`, `cdn`, `cloud-url`, `arn` (aws), `id`. Printer columns: READY,
PROVIDER, URL, DNS-TARGET. DNS is not part of this XR: put `dnsTarget` /
`dnsRecordType` and any `validationRecords` into a `DnsZone` XR.

## Backends

| dir | Composition | composes |
| --- | --- | --- |
| [`../aws/`](../aws/) | `landing-aws` | S3 Bucket + Objects, Origin Access Control, CloudFront Distribution, ACM Certificate (us-east-1) |
| [`../gcp/`](../gcp/) | `landing-gcp` | GCS Bucket + BucketObjects, public IAM member, BackendBucket + URLMap + proxy + GlobalAddress + GlobalForwardingRule, ManagedSSLCertificate |
| [`../azure/`](../azure/) | `landing-azure` | Storage Account static website + `$web` Blobs, Front Door profile/endpoint/origin group/origin/route/custom domain |
| [`../onprem/`](../onprem/) | `landing-onprem` | one provider-helm `Release` of the Bitnami nginx chart serving a ConfigMap |

## Manifests

| file | content |
| --- | --- |
| `xrd.yaml` | the `CompositeResourceDefinition` |
| `providers.yaml` | `provider-aws-s3`, `provider-aws-cloudfront`, `provider-aws-acm`, `provider-gcp-storage`, `provider-gcp-compute`, `provider-azure-storage`, `provider-azure-cdn`, `provider-helm`, plus provider-helm's ServiceAccount, `cluster-admin` ClusterRoleBinding and DeploymentRuntimeConfig. Versions match the schema packages from `just seed-landing-providers` |
| `functions.yaml` | `function-kcl` and `function-auto-ready`, pinned |
| `providerconfigs.yaml` | helm `ClusterProviderConfig` `default` (`InjectedIdentity`). Apply after the Providers are Healthy. Cloud credentials for aws/gcp/azure are yours to add; aws credentials must also be valid in us-east-1 |
| `examples/landing-aws.yaml` | `acme-landing`: domain, two companion files, CloudFront + ACM |
| `examples/landing-gcp.yaml` | `acme-landing-gcp`: domain on a global HTTPS load balancer |
| `examples/landing-azure.yaml` | `acmelanding`: name obeys the Storage Account rule, `resourceGroup: platform-rg` |
| `examples/landing-onprem.yaml` | `acme-landing-onprem`: Ingress host `acme.internal`, cert-manager issuer, 2 replicas |

## Usage

```bash
just install-module landing     # xrd.yaml + every backend composition.yaml, repointed at the local registry
just workload landing onprem    # functions, XRD, Compositions, providers, providerconfigs, then the onprem example
just e2e landing                # local cluster + registry, publish, install, providers, providerconfigs, every example XR
kubectl -n default apply -f packages/cloud/landing/xrd/examples/landing-onprem.yaml
kubectl -n default get landingpage
```

These need a cluster (`just e2e` creates one with `devkit cluster create`). The aws, gcp and
azure examples also need cloud credentials in a ProviderConfig of your own.
After changing `xrd.yaml`, regenerate `models/` with `just xrd-schema landing`.

## Development

```bash
pnpm exec nx run landing-xrd:test     # kcl test
pnpm exec nx run landing-xrd:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
