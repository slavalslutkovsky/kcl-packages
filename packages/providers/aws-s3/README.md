# aws-s3

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-s3`.

Source: ghcr.io/crossplane-contrib/provider-aws-s3:v2.6.0 (scope=namespaced; service=s3)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-s3 = { path = "<relative path>/packages/providers/aws-s3" }
```

Then import a model:

```python
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Bucket | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket` |
| BucketAbac | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_abac` |
| BucketAccelerateConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_accelerate_configuration` |
| BucketACL | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_acl` |
| BucketAnalyticsConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_analytics_configuration` |
| BucketCorsConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_cors_configuration` |
| BucketIntelligentTieringConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_intelligent_tiering_configuration` |
| BucketInventory | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_inventory` |
| BucketLifecycleConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_lifecycle_configuration` |
| BucketLogging | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_logging` |
| BucketMetric | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_metric` |
| BucketNotification | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_notification` |
| BucketObject | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_object` |
| BucketObjectLockConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_object_lock_configuration` |
| BucketOwnershipControls | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_ownership_controls` |
| BucketPolicy | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_policy` |
| BucketPublicAccessBlock | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_public_access_block` |
| BucketReplicationConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_replication_configuration` |
| BucketRequestPaymentConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_request_payment_configuration` |
| BucketServerSideEncryptionConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_server_side_encryption_configuration` |
| BucketVersioning | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_versioning` |
| BucketWebsiteConfiguration | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_website_configuration` |
| DirectoryBucket | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_directory_bucket` |
| Object | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_object` |
| ObjectCopy | `aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_object_copy` |

### unknown

Import the directory as one package — `import aws_s3.models.unknown as m` — and use `m.<kind>`.

- Bucket
- BucketAbac
- BucketAccelerateConfiguration
- BucketACL
- BucketAnalyticsConfiguration
- BucketCorsConfiguration
- BucketIntelligentTieringConfiguration
- BucketInventory
- BucketLifecycleConfiguration
- BucketLogging
- BucketMetric
- BucketNotification
- BucketObject
- BucketObjectLockConfiguration
- BucketOwnershipControls
- BucketPolicy
- BucketPublicAccessBlock
- BucketReplicationConfiguration
- BucketRequestPaymentConfiguration
- BucketServerSideEncryptionConfiguration
- BucketVersioning
- BucketWebsiteConfiguration
- DirectoryBucket
- Object
- ObjectCopy
