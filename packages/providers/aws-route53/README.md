# aws-route53

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-route53`.

Source: ghcr.io/crossplane-contrib/provider-aws-route53:v2.6.0 (scope=namespaced; service=route53)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-route53 = { path = "<relative path>/packages/providers/aws-route53" }
```

Then import a model:

```python
import aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_delegation_set as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| DelegationSet | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_delegation_set` |
| HealthCheck | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_health_check` |
| HostedZoneDNSSEC | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_hosted_zone_dns_s_e_c` |
| QueryLog | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_query_log` |
| Record | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_record` |
| ResolverConfig | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_resolver_config` |
| TrafficPolicy | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_traffic_policy` |
| TrafficPolicyInstance | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_traffic_policy_instance` |
| VPCAssociationAuthorization | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_v_p_c_association_authorization` |
| Zone | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_zone` |
| ZoneAssociation | `aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_zone_association` |
