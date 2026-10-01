# gcp-pubsub

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-pubsub`.

Source: ghcr.io/crossplane-contrib/provider-gcp-pubsub:v2.6.0 (scope=namespaced; service=pubsub)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-pubsub = { path = "<relative path>/packages/providers/gcp-pubsub" }
```

Then import a model:

```python
import gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_lite_reservation as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| LiteReservation | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_lite_reservation` |
| LiteSubscription | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_lite_subscription` |
| LiteTopic | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_lite_topic` |
| Schema | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_schema` |
| Subscription | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_subscription` |
| SubscriptionIAMMember | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_subscription_i_a_m_member` |
| Topic | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_topic` |
| TopicIAMMember | `gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_topic_i_a_m_member` |
