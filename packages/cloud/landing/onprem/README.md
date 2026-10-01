# landing-onprem

Self-hosted backend for the `LandingPage` XR (`cloud.example.org/v1alpha1`,
Composition `landing-onprem`, label `provider: onprem`). Typed against the
`helm` schema package under [packages/providers/](../../../providers/). It
composes one namespaced provider-helm `Release` of the Bitnami nginx chart
(`oci://registry-1.docker.io/bitnamicharts`, chart version pinned in
`landing.k`) whose document root is a ConfigMap carrying the content from the
XR. No cloud account, object storage or CDN. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/landing-onprem`.

Not installed here: cert-manager and an ingress controller — shared cluster
infrastructure this XR only annotates its Ingress for. See
[docs/landing.md](../../../../docs/landing.md).

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `managed` | `Release` (`helm.m.crossplane.io`) | always | external-name and `fullnameOverride` = XR name; `ClusterProviderConfig` `default`; `wait`, `waitTimeout: 10m`, `rollbackLimit: 3` |

Inside the chart values: a ConfigMap `<name>-content` (via `extraDeploy`), a
ClusterIP Service on port 80, a `serverBlock` (listen 8080, root `/app`), and
an Ingress only when `domain` is set.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `metadata.namespace` | Release `forProvider.namespace` (default `default`) |
| `domain` | `ingress.hostname`; unset publishes no Ingress |
| `content.html` / `content.index` | ConfigMap key `content.index` (wins over a `files[]` entry with the same key); nginx `index` |
| `content.errorDocument` | nginx `error_page 404` |
| `content.files[]` | one ConfigMap key each |
| `cdn.ttlSeconds` (default `3600`) | `add_header Cache-Control "public, max-age=<ttl>"` |
| `tls.enabled` (default `true`) | `ingress.tls`, plus the issuer annotation |
| `tls.issuer` (default `letsencrypt-prod`) | `cert-manager.io/cluster-issuer` |
| `ingressClassName` (default `nginx`) | `ingress.ingressClassName` |
| `replicas` (default `2`) | `replicaCount` |
| `tags` | `podLabels` |

Ignored: `region`, `resourceGroup`, `cdn.enabled`, `cdn.priceClass`,
`content.files[].contentType` (nginx uses its own `mime.types`) and
`deletionPolicy` (the Release lives and dies with the XR). Rejected (render
fails): a `content.files[].path` or `content.index` containing `/`.

Status written back: `provider: onprem`, `ready` (Release `state ==
"deployed"`), `host` / `url` (the domain, or
`http://<name>.<namespace>.svc.cluster.local`), `bucketName`
(`<name>-content`), `cdn: false`, `dnsRecordType: CNAME` with a domain,
`cloud-url` (`kubernetes://<ns>/deployment/<name>`), `id`
(`<ns>/<name>@<revision>`). `dnsTarget` is deliberately not set: the record
must point at the ingress controller's address, which this XR does not observe.

## Usage

`kcl run` with no options renders the built-in `_example` XR (no domain, so no
Ingress):

```bash
kcl run packages/cloud/landing/onprem

# a real XR: params is {oxr, ocds}, as function-kcl passes it
kcl run packages/cloud/landing/onprem \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/landing/xrd/examples/landing-onprem.yaml)}"
```

Output is `items:` — the `Release`, then the `LandingPage` carrying status.
`render` reads only the XR; `ocds` feeds `status` alone.

Through function-kcl (needs docker): `pnpm exec nx run landing-onprem:render`.
On a cluster: `just workload landing onprem` (functions, XRD, Compositions,
providers, the helm `ClusterProviderConfig`, then the onprem example), or
`just install-module landing` / `just e2e landing`.

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `landing.k` | chart pin, `server_block`, `render(oxr)` and `status(oxr, ocds)` |
| `landing_test.k` | `kcl test` cases |
| `composition.yaml` | the `landing-onprem` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run landing-onprem:test     # kcl test
pnpm exec nx run landing-onprem:lint     # kcl lint
pnpm exec nx run landing-onprem:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
