# email-stalwart

In-cluster backend for the `EmailDomain` XR (`cloud.example.org/v1alpha1`): one
provider-helm `Release` that installs the Stalwart all-in-one mail server into
the XR's own namespace. No cloud account involved. Typed against the vendored
`helm` schema package ([../../../providers/helm](../../../providers/helm)). The
`email-stalwart` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/email-stalwart`, followed by `function-auto-ready`.

Domain and DKIM setup happen inside Stalwart at runtime (admin UI /
`stalwart-cli`), not through chart values; the XR provisions the server, its
storage and deterministic endpoints. Intended for internal mail, dev/e2e and
on-prem clusters (see the XRD description).

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `Release` (`helm.m.crossplane.io`) | always | composition-resource-name `managed`; chart `stalwart-mail` from `oci://codeberg.org/wrenix/helm-charts`, pinned in `email.k`; `providerConfigRef` `ClusterProviderConfig/default`; `wait: true`, `waitTimeout: 10m`, `rollbackLimit: 3` |

Chart values the backend always sets, and why (comments in `email.k`):

| value | setting | reason |
| --- | --- | --- |
| `fullnameOverride` | XR name | service names, hence `status.smtpHost`, are deterministic |
| `config` | `@type: RocksDb`, `path: /var/lib/stalwart/data`, external-store fields nulled | the chart default `@type: ""` crashes the server at startup |
| `certificate.certmanager.enabled` | `false` | the chart default wants a `letsencrypt-prod` ClusterIssuer; without it the pod hangs in ContainerCreating. Stalwart falls back to a self-signed cert |
| `service.ports.http` | `8080` | the chart probes `/healthz` on this port; Stalwart never listens on the default 80 |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `metadata.namespace` | `Release.forProvider.namespace` (default `default`) |
| `persistenceSizeGb` | `persistence.size` = `<n>Gi`, default `10`; persistence always enabled |
| `adminPasswordSecret` | `set` override `secrets.env.FALLBACK_ADMIN_SECRET` with `valueFrom.secretKeyRef` (`key` default `password`), so the password never lands in the values blob |
| `certificateSecret` | `certificate.secretName` |
| `tags` | `podLabels` (the chart has no common labels) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]`; otherwise the schema default `['*']` |
| `region`, `mailFromSubdomain`, `dkimKeyLength`, `tlsRequired`, `sendingEnabled`, `reputationMetrics`, `suppressedReasons` | ignored: the server runs where the XR lives, the envelope domain is the domain itself, Stalwart manages its own DKIM keys, STARTTLS is always offered, the SES set knobs have no chart equivalent |

`spec.domain` is not read by this backend.

Status written back to the XR (observed values from the `managed` Release's
`atProvider`):

| status | value |
| --- | --- |
| `provider` | `stalwart` |
| `ready` | `true` once `atProvider.state` is `deployed` |
| `verified` | same as `ready`; there is no external verification gate |
| `smtpHost` / `smtpPort` / `smtpEndpoint` | `<xr>.<ns>.svc.cluster.local`, `587`, known before deployment |
| `cloud-url` | `kubernetes://<ns>/deployment/<xr>` |
| `id` | `<ns>/<xr>@<revision>` once a revision is observed |

`dkimTokens` and `dnsRecords` are never set; get the records from the Stalwart
admin UI or `stalwart-cli dns records`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`mail.example.com`, namespace `default`):

```bash
kcl run packages/cloud/email/stalwart
```

The local output also carries the `chart_repository`, `chart_name` and
`chart_version` top-level keys from `email.k` next to `items`.

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`;
`ocds` may be omitted), so a real XR renders like this:

```bash
kcl run packages/cloud/email/stalwart \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/email/xrd/examples/email-stalwart.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/email-stalwart.yaml](../xrd/examples/email-stalwart.yaml)):

```bash
pnpm exec nx run email-stalwart:render
```

On a cluster: `just e2e email` installs provider-helm and the
`ClusterProviderConfig` from [../xrd/providerconfigs.yaml](../xrd/providerconfigs.yaml)
and applies the examples; `just install-module email` applies only the XRD and
Compositions.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `email.k` | chart pin, `render` (the Release and its values), `status` |
| `email_test.k` | `kcl test` cases: shape, namespace, chart values, admin password, deletion policy, status |
| `composition.yaml` | `email-stalwart` Composition (`provider: stalwart` label) |

## Development

```bash
pnpm exec nx run email-stalwart:test     # kcl test
pnpm exec nx run email-stalwart:lint     # kcl lint
pnpm exec nx run email-stalwart:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
