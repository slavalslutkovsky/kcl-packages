# aws-rds

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-rds`.

Source: ghcr.io/crossplane-contrib/provider-aws-rds:v2.6.0 (scope=namespaced; service=rds)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-rds = { path = "<relative path>/packages/providers/aws-rds" }
```

Then import a model:

```python
import aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Cluster | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster` |
| ClusterActivityStream | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster_activity_stream` |
| ClusterEndpoint | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster_endpoint` |
| ClusterInstance | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster_instance` |
| ClusterParameterGroup | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster_parameter_group` |
| ClusterRoleAssociation | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster_role_association` |
| ClusterSnapshot | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_cluster_snapshot` |
| DBInstanceAutomatedBackupsReplication | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_d_b_instance_automated_backups_replication` |
| DBSnapshotCopy | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_d_b_snapshot_copy` |
| EventSubscription | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_event_subscription` |
| GlobalCluster | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_global_cluster` |
| Instance | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_instance` |
| InstanceRoleAssociation | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_instance_role_association` |
| InstanceState | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_instance_state` |
| OptionGroup | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_option_group` |
| ParameterGroup | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_parameter_group` |
| Proxy | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_proxy` |
| ProxyDefaultTargetGroup | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_proxy_default_target_group` |
| ProxyEndpoint | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_proxy_endpoint` |
| ProxyTarget | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_proxy_target` |
| Snapshot | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_snapshot` |
| SubnetGroup | `aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_subnet_group` |
