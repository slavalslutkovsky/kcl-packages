# landing-azure

Azure backend for the `LandingPage` XR (`cloud.example.org/v1alpha1`,
Composition `landing-azure`, label `provider: azure`). Typed against the
`azure-storage` and `azure-cdn` schema packages under
[packages/providers/](../../../providers/). It composes a StorageV2 account
with the static website enabled, one `Blob` per document in `$web`, and a
Front Door Standard profile, endpoint, origin group, origin, route and (with a
domain) custom domain with a managed certificate. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/landing-azure`.

Not composed: the resource group (`spec.resourceGroup` must already exist),
the `$web` container (Azure creates it), DNS records, WAF policies and rule
sets. `status.dnsTarget` (`CNAME`) and `status.validationRecords` (the
`_dnsauth` TXT) say what a `DnsZone` must carry. See
[docs/landing.md](../../../../docs/landing.md).

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `managed` | `Account` (`storage.azure.m.upbound.io`) | always | external-name = XR name; `Standard` / `LRS` / `StorageV2`, `staticWebsite`, `allowNestedItemsToBePublic` |
| `blob-index` | `Blob` | always | `content.html` at `content.index` in `$web`, `text/html` |
| `blob-<slug>` | `Blob` | per `content.files[]` | slug: path lowercased, `[^a-z0-9-]` → `-`; blob key is the external-name |
| `frontdoor-profile` | `FrontdoorProfile` (`cdn.azure.m.upbound.io`) | `cdn.enabled` | `Standard_AzureFrontDoor` |
| `frontdoor-endpoint` | `FrontdoorEndpoint` | `cdn.enabled` | the `*.azurefd.net` host |
| `frontdoor-origin-group` | `FrontdoorOriginGroup` | `cdn.enabled` | HTTPS `HEAD /` probe |
| `custom-domain` | `FrontdoorCustomDomain` | `cdn.enabled` and `domain` | `ManagedCertificate`, `TLS12` |
| `frontdoor-origin` | `FrontdoorOrigin` | `cdn.enabled` and the account's `primaryWebHost` is observed | second pass: the host carries a region-assigned `z<NN>` segment |
| `frontdoor-route` | `FrontdoorRoute` | same as `frontdoor-origin` | `/*`, `HttpsOnly` forwarding, binds the custom domain |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `metadata.name` | Storage Account name; must match `^[a-z0-9]{3,24}$` |
| `region` | `Account.forProvider.location` |
| `resourceGroup` | `resourceGroupName` on the account and the profile (required) |
| `domain` | `FrontdoorCustomDomain.hostName` |
| `content.index` / `content.errorDocument` | `staticWebsite.indexDocument` / `error404Document` |
| `content.html`, `content.files[]` | one `Blob` each; `contentType` explicit or derived from the extension (shared table, `application/octet-stream` otherwise) |
| `cdn.enabled` (default `true`) | Front Door stack, or the account's own web endpoint only |
| `cdn.ttlSeconds` (default `3600`) | `cacheControl: public, max-age=<ttl>` on every blob (Front Door Standard caches by rule set only) |
| `tls.enabled` (default `true`) | route `httpsRedirectEnabled`; the managed certificate stays either way |
| `deletionPolicy: Orphan` | `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | account and profile `tags` |

Ignored: `cdn.priceClass`, `tls.issuer`, `ingressClassName`, `replicas`.
Rejected (render fails): missing `resourceGroup`, `domain` with
`cdn.enabled: false`, and an XR name that is not a valid Storage Account name.

Status written back: `provider: azure`, `bucketName` (account name), `cdn`,
`cloud-url`; `ready` once the endpoint has a host and, with a domain, the route
exists (without CDN: once `primaryWebHost` is observed); `host` / `url`
(`https://` on the domain, endpoint host or web host); `dnsTarget` (endpoint
host) with `dnsRecordType: CNAME`; `validationRecords`
`[{name: _dnsauth.<domain>, type: TXT, value: <validationToken>}]`; `id`.
`certificateStatus` is never set.

## Usage

`kcl run` with no options renders the built-in `_example` XR (no domain, first
pass):

```bash
kcl run packages/cloud/landing/azure

# a real XR: params is {oxr, ocds}, as function-kcl passes it
kcl run packages/cloud/landing/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/landing/xrd/examples/landing-azure.yaml)}"

# second pass: the observed web host adds frontdoor-origin and frontdoor-route
kcl run packages/cloud/landing/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/landing/xrd/examples/landing-azure.yaml), \"ocds\": {\"managed\": {\"Resource\": {\"status\": {\"atProvider\": {\"primaryWebHost\": \"acmelanding.z6.web.core.windows.net\"}}}}}}"
```

Output is `items:` — the managed resources, then the `LandingPage` carrying
status.

Through function-kcl (needs docker): `pnpm exec nx run landing-azure:render`.
On a cluster: `just install-module landing`, `just e2e landing` (needs Azure
credentials in a ProviderConfig of your own).

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `landing.k` | `render(oxr, ocds)` and `status(oxr, ocds)` |
| `landing_test.k` | `kcl test` cases |
| `composition.yaml` | the `landing-azure` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run landing-azure:test     # kcl test
pnpm exec nx run landing-azure:lint     # kcl lint
pnpm exec nx run landing-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
