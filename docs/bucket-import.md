# Moving buckets from Terraform or Pulumi to Crossplane

Crossplane has no state file to import into. What it has is an annotation:
a managed resource whose `crossplane.io/external-name` names a bucket that
already exists is **observed** rather than created. `spec.import` on the
`Bucket` XR is that annotation, spread over every managed resource a
backend composes, plus the two switches that make adoption safe: a
read-only mode and a deletion policy that keeps the bucket.

The migration is therefore three states, in order, and a bucket can sit in
any of them for as long as you like:

| state | who writes to the bucket | what Crossplane does | how you get there |
|---|---|---|---|
| **old tool** | Terraform / Pulumi | nothing | where you start |
| **observe** | Terraform / Pulumi | reads it: `status` fills in, `READY` goes true, nothing is changed | apply the XR `just bucket-import` wrote |
| **managed** | Crossplane | reconciles the spec onto it, exactly as for a bucket it created | `import.mode: manage`, then remove the bucket from the old state |

`just bucket-import` reads the old tool's state and writes one XR per bucket
that lands it in **observe**. The rest of this page is the walk, then what
each field does, then what the reader cannot carry over.

## The walk

```sh
# 1. Get the state as JSON. Any of the three shapes works.
terraform show -json > state.json          # remote backends included
cp terraform.tfstate state.json            # or the raw file
pulumi stack export > state.json

# 2. See what is in it before writing anything.
just bucket-import-report state.json

# 3. Write the XRs, one per bucket, into a namespace. Read them.
just bucket-import state.json prod > buckets.yaml

# 4. Apply. In observe mode this changes nothing in the cloud.
kubectl apply -f buckets.yaml
kubectl -n prod get buckets                # READY true, MODE observe

# 5. Compare. status is what the provider sees; spec is what the old tool said.
kubectl -n prod get bucket legacy-assets-8f3a1c -o yaml

# 6. Hand over: Crossplane starts writing, the old tool must stop.
kubectl -n prod patch bucket legacy-assets-8f3a1c --type merge \
  -p '{"spec":{"import":{"mode":"manage"}}}'
terraform state rm aws_s3_bucket.assets aws_s3_bucket_versioning.assets ...   # every address the report listed
pulumi state delete 'urn:pulumi:prod::infra::aws:s3/bucketV2:BucketV2::assets' # same, per URN

# 7. Decide what deleting the XR should do. The import defaults to Orphan.
```

Step 5 is the one that matters. Every XR the importer writes carries the
old tool's view of the bucket in the portable fields — versioning, public
access, encryption, retention, lifecycle, cors, logging, website, tags —
and in `manage` mode Crossplane will make the cloud bucket match that spec.
If the state was stale, or the bucket was changed by hand since the last
`apply`, the spec is wrong and `manage` would "fix" the bucket back. In
observe mode nothing is written, so this is the moment to diff
`status` (what the provider observed) against `spec` and edit the XR until
they agree. `status.mode` and the `MODE` column say which state a bucket is
in, so a `kubectl get buckets -A` shows how far the migration has got.

Step 6 is two halves that must both happen. Flipping the mode without
removing the state leaves two writers; the old tool's next `apply` reverts
whatever Crossplane changed, and vice versa. Removing the state without
flipping the mode leaves a bucket nobody manages — harmless, but `observe`
was meant to be temporary. `terraform state rm` and `pulumi state delete`
never touch the cloud; they only forget. Take every companion address the
report lists, not just the bucket's: an `aws_s3_bucket_versioning` left in
the state is still a writer.

The import defaults to `deletionPolicy: Orphan`, so during the whole
migration deleting the XR — by mistake, by a wrong `kubectl delete -f`, by
a GitOps prune — deletes nothing in the cloud. Set it to `Delete` only once
the bucket is fully Crossplane's and you mean it.

## What `spec.import` does

| field | effect |
|---|---|
| `existingName` | The real cloud name (`legacy-assets-8f3a1c`, not `legacy-assets`). Becomes `crossplane.io/external-name` on every managed resource the backend composes. Terraform and Pulumi usually suffix names, so it rarely equals `metadata.name`. Required. |
| `mode: observe` (default) | `managementPolicies: [Observe]` on every managed resource. Crossplane reads and reports; it never creates, updates or deletes. `deletionPolicy` is moot. |
| `mode: manage` | The managed resources get the policies a created bucket would: `["*"]`, or the orphan set when `deletionPolicy: Orphan`. Crossplane now owns writes. |
| `source`, `address` | Provenance, as annotations `cloud.example.org/imported-from` and `cloud.example.org/import-address` on the managed resources. Nothing reads them; a human doing step 6 does. |
| `resourceGroup` | Azure only. The storage account's ARM id needs it, so an adopted account cannot be observed without it. Ignored elsewhere. |

Per backend:

| backend | pinned to `existingName` | notes |
|---|---|---|
| `aws` | the `Bucket` **and every companion** (versioning, public-access-block, ownership, encryption, lifecycle, object-lock, cors, logging, website, request-payment) | Each S3 companion API is keyed by bucket name, so the name is every companion's external name too. Companions name the bucket directly (`forProvider.bucket`) instead of resolving `bucketSelector`, so nothing waits on a reference in observe mode. |
| `gcp` | the one `Bucket` | GCS expresses everything inline; the name is the whole identity. |
| `azure` | the `Account` | Plus `resourceGroupName` from `import.resourceGroup`. The lifecycle `ManagementPolicy` is **not** rendered in observe mode (it has no identity of its own to observe) and is not pinned in manage mode (the provider derives its id from the account). |
| `rustfs` | the `Bucket` and its lifecycle companion | As `aws`, through the `rustfs` ProviderConfig. |

A bucket the XR adopts and a bucket it creates render the same managed
resources with the same `forProvider`; the only differences are the
annotation and the policies. That is what makes step 6 a one-field patch.

## What the reader carries over

`packages/cloud/bucket/import` is a KCL package: `just bucket-import` runs
it with `-D state=<path>`. It reads the three JSON shapes by their outline
(`values.root_module` is `terraform show -json`, `resources[]` is a raw
tfstate, `deployment` is a Pulumi export), walks child modules, and joins
S3 companions to their bucket on the `bucket` attribute. Terraform's
snake_case blocks-as-lists and Pulumi's camelCase objects are read by one
mapper; the output is typed against the generated `Bucket` schema, so a
value the XRD would reject fails in the terminal instead of at the API
server.

| `Bucket` field | Terraform (aws) | Pulumi (aws) | Terraform / Pulumi (gcp) | azure |
|---|---|---|---|---|
| `region` | `region` | `region` | `location` | `location` |
| `storageClass` | — (S3 has no bucket tier) | — | `storage_class` → standard/nearline/cold/archive | `access_tier` Hot/Cool/Cold → standard/nearline/cold |
| `versioning` | `aws_s3_bucket_versioning` status, else inline `versioning.enabled`, else false | `BucketVersioning(V2)` | `versioning.enabled` | — |
| `blockPublicAccess` | `aws_s3_bucket_public_access_block`: all four flags | same | `public_access_prevention == enforced` | — |
| `uniformAccess` | `aws_s3_bucket_ownership_controls` == BucketOwnerEnforced | same | `uniform_bucket_level_access` | — |
| `encryptionKmsKeyId` | SSE config with `aws:kms` and a key; `AES256` means no key | same | `encryption.default_kms_key_name` | — |
| `requesterPays` | request-payment `payer == Requester` | same | `requester_pays` | — |
| `retention` | object-lock default retention (`years` × 365) | same | `retention_policy` seconds ÷ 86400; `is_locked` → compliance | — |
| `logging` | `aws_s3_bucket_logging`, else inline `logging` | same | `logging` | — |
| `website` | website configuration, else inline `website` | same | `website` | — |
| `cors` | cors configuration, else inline `cors_rule` | same | `cors` | — |
| `lifecycleRules` | lifecycle configuration, else inline `lifecycle_rule`; S3 classes map back to tiers | same | one abstract rule per native rule; the tier's own age-0 rule folds into `storageClass` | — |
| `tags` | `tags` | `tags` | `labels` | `tags` |
| `forceDestroy` | `force_destroy` | `forceDestroy` | `force_destroy` | — |
| `import.resourceGroup` | | | | `resource_group_name` |

A field the state does not speak for is left out, and the XRD default
applies — which is what the API server would have done. A field the state
does speak for is written even when it equals the default, so the XR says
what the old tool said.

Metadata: `metadata.name` is the cloud name made DNS-1123 (dots and
underscores to dashes, lowercased, 63 characters); `namespace` and `mode`
are the recipe's arguments; `deletionPolicy` is `Orphan`; the composition
selector is the provider the state named. `-D deletionPolicy=Delete` and
`-D source=` exist for the rare case.

## What it drops, and says so

Anything the portable schema cannot express is dropped **and named**, in a
`cloud.example.org/import-notes` annotation on the XR and in the report.
The rule is that a silent drop looks like a clean migration and is a wrong
one.

- A lifecycle rule that is disabled, or whose only conditions are
  noncurrent-version counts, dates, object sizes or tags.
- A transition to a class no tier maps to: `INTELLIGENT_TIERING`,
  `GLACIER` flexible retrieval keeps `cold`, everything else is dropped.
- A GCS rule with no `age` condition, or with several prefixes (the first
  is kept).
- A public-access block with some flags set: `blockPublicAccess` is
  all-or-nothing, so it becomes `false` with a note.
- A GCS retention period that is not whole days (rounded down).
- Azure: everything but tier and tags. The `azure` backend maps no more
  than that today.

The report's `skipped` list is bucket-family resources the reader
recognised and will not fold: `aws_s3_bucket_policy`, `_acl`,
`_notification`, objects, Pulumi `BucketObject`s. They stay in the old
tool, or become something else; a bucket policy is IAM, not a bucket
property. Resources of other kinds (an IAM member, the provider itself,
`azure-native` accounts) are not read at all.

## Where it stops

- **`manage` reconciles the spec, not the bucket.** Anything true of the
  bucket that the spec does not say — a policy, an ACL, a notification, a
  replication rule — is neither managed nor removed. Crossplane touches
  only the managed resources it composes.
- **`forceDestroy` is carried over.** A Terraform bucket with
  `force_destroy = true` adopts as `forceDestroy: true`; with `manage` +
  `deletionPolicy: Delete` that empties the bucket on XR deletion, exactly
  as it did on `terraform destroy`. The default `Orphan` is what keeps step
  7 a decision rather than an accident.
- **`prevent_destroy` / `protect` are not read.** They are the old tool's
  guard, not a property of the bucket; `Orphan` is the equivalent here.
- **Names are not portable across clouds.** An adopted bucket stays on
  its provider; the composition selector follows the state.
- **RustFS state is not read.** Terraform's `aws_s3_bucket` against a
  custom endpoint reads as `aws`; edit the selector to `rustfs` by hand.

## Tests

| file | pins |
|---|---|
| `packages/cloud/bucket/import/import_test.k` | both Terraform shapes (modules, `for_each` addresses), Pulumi with and without `V2` tokens, every aws companion, the legacy inline blocks, tier folding on GCS, the drop notes, the XR shape and its defaults |
| `packages/cloud/bucket/{aws,gcp,azure,rustfs}/bucket_test.k` | external-name on every pinned resource, `[Observe]` in observe mode, the orphan set in manage + Orphan, the selector-vs-name switch on companions, `status.mode` |
| `packages/cloud/bucket/xrd/xrd_test.k` | `examples/bucket-import.yaml` is a valid `Bucket`; `mode` defaults to `observe` |
