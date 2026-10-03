# email-aws

AWS backend for the `EmailDomain` XR (`cloud.example.org/v1alpha1`): an SESv2
sending domain identity bound to its own configuration set, plus custom MAIL
FROM attributes when asked for. Typed against the vendored `aws-sesv2` schema
package ([../../../providers/aws-sesv2](../../../providers/aws-sesv2)). The
`email-aws` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/email-aws`, followed by `function-auto-ready`.

The identity is only half of email: the records in `status.dnsRecords` have to
be published in the domain's zone (a `DnsZone` from [../../dns/](../../dns/))
before SES verifies it.

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `ConfigurationSet` (`sesv2.aws.m.upbound.io`) | always | composition-resource-name `config`; external-name `<xr>-config` |
| `EmailIdentity` (`sesv2.aws.m.upbound.io`) | always | composition-resource-name `identity`; external-name `spec.domain`; binds the set with `configurationSetNameSelector.matchControllerRef` |
| `EmailIdentityMailFromAttributes` (`sesv2.aws.m.upbound.io`) | `spec.mailFromSubdomain` set | composition-resource-name `mailfrom`; external-name `spec.domain` (the identity it attaches to); `mailFromDomain` = `<sub>.<domain>`; `behaviorOnMxFailure` left to the provider default |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on every MR; also the SMTP host and console URL |
| `domain` | identity external-name, MAIL FROM parent, DKIM record names |
| `mailFromSubdomain` | adds the MAIL FROM MR and its MX + SPF rows in `status.dnsRecords` |
| `dkimKeyLength` | `EmailIdentity.dkimSigningAttributes.nextSigningKeyLength`: `1024` → `RSA_1024_BIT`, anything else (default `2048`) → `RSA_2048_BIT` |
| `tlsRequired` | `ConfigurationSet.deliveryOptions.tlsPolicy`: `REQUIRE` (default) / `OPTIONAL` |
| `sendingEnabled` | `ConfigurationSet.sendingOptions.sendingEnabled`, default `true` |
| `reputationMetrics` | `ConfigurationSet.reputationOptions.reputationMetricsEnabled`, default `false` |
| `suppressedReasons` | `ConfigurationSet.suppressionOptions.suppressedReasons`; absent → `[BOUNCE, COMPLAINT]`, an explicit `[]` is sent as-is and disables suppression |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR; otherwise the schema default `['*']` |
| `tags` | `forProvider.tags` on the set and the identity; the MAIL FROM model has no tags field |
| `persistenceSizeGb`, `adminPasswordSecret`, `certificateSecret` | ignored (in-cluster only) |

Status written back to the XR (observed values come from the `identity` MR's
`atProvider`):

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once the identity reports an `arn` or `id`, not once DNS is verified |
| `verified` | `atProvider.verifiedForSendingStatus`, else `false` |
| `verificationStatus`, `arn`, `id` | copied when observed |
| `dkimTokens` | observed Easy-DKIM tokens, `[]` until reported |
| `dnsRecords` | one `CNAME` `<token>._domainkey.<domain>` → `<token>.dkim.amazonses.com` per token; with `mailFromSubdomain`, an `MX` (priority 10, `feedback-smtp.<region>.amazonses.com`) and an SPF `TXT` for `<sub>.<domain>`, published before the identity exists |
| `smtpHost` / `smtpPort` / `smtpEndpoint` | `email-smtp.<region>.amazonaws.com`, `587` |
| `configurationSet` | `<xr>-config` |
| `cloud-url` | SES console link for the identity |

The region in status is the observed `atProvider.region` when present, else
`spec.region`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`mail.example.com` in `us-east-1`, no MAIL FROM):

```bash
kcl run packages/cloud/email/aws
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`;
`ocds` may be omitted), so a real XR renders like this:

```bash
kcl run packages/cloud/email/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/email/xrd/examples/email-aws.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/email-aws.yaml](../xrd/examples/email-aws.yaml)):

```bash
pnpm exec nx run email-aws:render
```

On a cluster: `just e2e email`, or `just install-module email` for the XRD
and Compositions alone. The SES MRs need a real AWS ProviderConfig of your own;
[../xrd/providerconfigs.yaml](../xrd/providerconfigs.yaml) only ships the helm
one.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `email.k` | `render` (ConfigurationSet, EmailIdentity, MAIL FROM), `status`, `key_length_for` |
| `email_test.k` | `kcl test` cases: shape, MAIL FROM, DKIM, set options, deletion policy, tags, status |
| `composition.yaml` | `email-aws` Composition (`provider: aws` label) |

## Development

```bash
pnpm exec nx run email-aws:test     # kcl test
pnpm exec nx run email-aws:lint     # kcl lint
pnpm exec nx run email-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
