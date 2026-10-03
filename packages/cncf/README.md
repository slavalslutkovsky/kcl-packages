# cncf

The application-management layer of one local developer cluster: ingress-nginx,
cert-manager, an offline CA chain and a trusted wildcard certificate for the dev
domain, from one values file. Delivery goes through [`manager`](../manager/):
the charts render as Flux `HelmRepository` + `HelmRelease` pairs and the issuers
as `manager.Issuer` rows, so Flux (source-controller + helm-controller) must
already be on the cluster. The `cncf-*` recipes in the `justfile` consume it.

`runner` decides how ingress reaches the host:

| runner | ingress | wildcard certificate |
| --- | --- | --- |
| `kind` | ingress-nginx with hostPort 80/443 on the `ingress-ready` control-plane node ([`cluster`](../cluster/) binds them when `ingress = true`) | `ingress-nginx`'s `--default-ssl-certificate` |
| `k3d` | ingress-nginx as a `LoadBalancer` Service; k3s servicelb + the k3d serverlb publish 80/443 (traefik disabled) | same |
| `openshift` | OpenShift Local (CRC) router; ingress-nginx is not rendered | the router's default certificate, via a partial `IngressController` |

## Usage

`-D values=<path>` (like `helm -f`), or `values.yaml` in the current directory.
`-D env=<name>` deep-merges `<stem>.<name>.yaml` over it (right wins; lists
replace). The merged result is validated against the `Cncf` schema. With no
values file the package renders a built-in `runner: kind` demo.

```bash
kcl run packages/cncf -D values=packages/cncf/examples/values.yaml -q
kcl run packages/cncf -D values=packages/cncf/examples/values.yaml -D env=k3d -q
kcl run packages/cncf -D values=packages/cncf/examples/values.yaml -D env=openshift -q

just cncf                                               # examples/values.yaml
just cncf packages/cncf/examples/values.yaml openshift  # same, with the overlay
```

From the published package: `kcl run oci://docker.io/yurikrupnik/cncf -D values=… -q`.
In code: `import cncf.lib as cncf; cncf.render(cncf.Cncf {**values})`.

On a bare cluster apply the stream twice: the ClusterIssuers and Certificates
are instances of the CRDs the cert-manager chart installs. The cluster
recipes (need docker, or `crc` for openshift):

| recipe | does |
| --- | --- |
| `just cncf-up [kind\|k3d\|openshift]` | Create the `kcl-cncf` cluster and install flux2. kind runs devkit from [`manifests/cncf`](../../manifests/cncf/devkit.toml); k3d uses the CLI with traefik off; openshift runs `crc start` |
| `just cncf-apply [values] [env]` | Pass 1: HelmRepository/HelmRelease, wait for every HelmRelease Ready. Pass 2: everything. On openshift also trusts the CA cluster-wide (`proxy/cluster.spec.trustedCA`) |
| `just cncf-ca [values] [env]` | Export the CA to `tmp/cncf/ca.crt` and print the macOS trust command |
| `just cncf-check [values] [env]` | Assert HelmReleases, ClusterIssuers, both Certificates Ready and `https://hello.<domain>/` served with the local chain |
| `just cncf-status` | HelmReleases, ClusterIssuers, Certificates |
| `just cncf-dev [values] [env]` | Tilt loop over [`manifests/cncf/Tiltfile`](../../manifests/cncf/Tiltfile) |
| `just cncf-e2e [runner]` | `cncf-up` + `cncf-apply` + `cncf-check` + `cncf-status`; k3d/openshift use their overlay |
| `just cncf-down [runner]` | Delete the cluster |

Every recipe that touches the cluster refuses any context but
`kind-kcl-cncf`, `k3d-kcl-cncf` or `crc-admin` (`just cncf-context`).

## Inputs

`Cncf` (`lib.k`):

| key | default | meaning |
| --- | --- | --- |
| `name` | `cncf` | Manager name; `app.kubernetes.io/part-of` on the Certificates; CA common name `<name> local CA` |
| `runner` | required | `kind`, `k3d` or `openshift` |
| `domain` | `localtest.me` | Bare DNS name the wildcard covers (`*.<domain>` and `<domain>`). On openshift it must be the apps domain (`apps-crc.testing` on CRC) |
| `namespace` | `flux-system` | Where the HelmRepository / HelmRelease objects live |
| `ingress` | `{}` | `version` (chart), `namespace` (`ingress-nginx`), `className` (`nginx`), `default` (`true`: default IngressClass), `values` deep-merged over the runner preset. `values` must stay empty on openshift |
| `certs` | `{}` | `version` (chart), `namespace` (`cert-manager`, also where the CA secret lives), `rootIssuer` (`local-root`), `caIssuer` (`local-ca`), `caSecret` (`local-ca-tls`), `values` merged over `crds.enabled: true`. `rootIssuer` and `caIssuer` must differ |
| `dependencies` | `[]` | Extra charts, any `manager.Dependency`; each must be `type: application` and must not be named `ingress-nginx` or `cert-manager` |

## Outputs

In order:

1. From `manager.render` (Manager `role: workload`): `HelmRepository` +
   `HelmRelease` for `ingress-nginx` (not on openshift), `cert-manager` and
   each extra dependency; `ClusterIssuer` `<rootIssuer>` (self-signed) and
   `<caIssuer>` (CA from `caSecret`).
2. `Certificate` `<caIssuer>` in `certs.namespace`: `isCA`, ECDSA P-256, ten
   years, issued by `rootIssuer` into `caSecret`.
3. `Certificate` `wildcard` → secret `wildcard-tls`, issued by `caIssuer`, in
   `ingress.namespace` (`openshift-ingress` on openshift).
4. openshift only: `operator.openshift.io/v1` `IngressController` `default` in
   `openshift-ingress-operator`, setting `defaultCertificate.name: wildcard-tls`
   (untyped; `kubectl apply` merges it into the existing singleton).

## Examples

| file | content |
| --- | --- |
| `examples/values.yaml` | `name: dev`, `runner: kind`, `localtest.me`, default issuers; the default for every `cncf*` recipe |
| `examples/values.k3d.yaml` | `-D env=k3d`: `runner: k3d` |
| `examples/values.openshift.yaml` | `-D env=openshift`: `runner: openshift`, `domain: apps-crc.testing` |

## Layout

| file | content |
| --- | --- |
| `main.k` | values file + env overlay loading, demo fallback, `render` to a YAML stream |
| `lib.k` | `Cncf`, `Ingress`, `Certs` schemas, the per-runner ingress-nginx presets, the composed `manager.Manager`, Certificates and the IngressController |
| `cncf_test.k` | `kcl test` cases per runner, CA chain, overrides, extra dependencies, the example file |

## Development

```bash
pnpm exec nx run cncf:test     # kcl test
pnpm exec nx run cncf:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
