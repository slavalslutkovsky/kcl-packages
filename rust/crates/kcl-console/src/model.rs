//! The inventory the console serves, and how rows from different sources
//! become one row per real bucket.

use std::fmt;
use std::str::FromStr;

use serde::Serialize;

/// Where a row was seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// `Bucket` composites (`buckets.cloud.example.org`) in the kubeconfig's cluster.
    K8s,
    /// `aws s3api list-buckets`.
    Aws,
    /// `gcloud storage buckets list`.
    Gcp,
    /// `az storage account list` (the XRD's Azure backend is a storage account).
    Azure,
}

impl Source {
    pub const ALL: [Source; 4] = [Source::K8s, Source::Aws, Source::Gcp, Source::Azure];

    pub fn as_str(self) -> &'static str {
        match self {
            Source::K8s => "k8s",
            Source::Aws => "aws",
            Source::Gcp => "gcp",
            Source::Azure => "azure",
        }
    }
}

impl fmt::Display for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for Source {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Source::ALL
            .into_iter()
            .find(|source| source.as_str() == s)
            .ok_or_else(|| format!("unknown source {s:?}; expected one of k8s, aws, gcp, azure"))
    }
}

/// One bucket, however many sources reported it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    /// Stable row key: `xr:<namespace>/<name>` for a composite, `<cloud>:<name>`
    /// for a bucket only a cloud listing knows about.
    pub id: String,
    /// The cloud's name for the bucket (S3/GCS bucket, Azure storage account).
    pub name: String,
    /// `aws` | `gcp` | `azure` | `rustfs`, or `unknown` for a composite whose
    /// backend cannot be told from its spec or status.
    pub provider: String,
    pub region: Option<String>,
    pub storage_class: Option<String>,
    /// RFC 3339 creation time as reported by the cloud, else the composite's.
    pub created: Option<String>,
    /// Native URI (`s3://…`, `gs://…`, blob endpoint).
    pub url: Option<String>,
    pub console_url: Option<String>,
    /// Every source that reported this bucket, in [`Source::ALL`] order.
    pub seen_in: Vec<Source>,
    /// The Crossplane composite managing it; `None` means unmanaged — an
    /// import candidate for `packages/cloud/bucket/import`.
    pub composite: Option<Composite>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Composite {
    pub namespace: String,
    pub name: String,
    pub ready: Option<bool>,
    pub synced: Option<bool>,
    /// `status.mode`: `created` | `observe` | `managed`.
    pub mode: Option<String>,
    /// Reason and message of the first condition that is not `True`.
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceState {
    Ok,
    /// Not set up here: CLI not on PATH, no kubeconfig, XRD not installed.
    Unavailable,
    /// Set up, but the call failed (expired credentials, timeout, bad output).
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceReport {
    pub source: Source,
    /// What was asked: kube context, CLI invocation.
    pub label: String,
    pub state: SourceState,
    pub detail: Option<String>,
    pub count: usize,
    pub millis: u64,
}

/// Why a source produced no rows; becomes [`SourceReport::state`] and `detail`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    Unavailable(String),
    Error(String),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Inventory {
    pub sources: Vec<SourceReport>,
    pub buckets: Vec<Bucket>,
}

/// Folds cloud listings into the composites that manage them.
///
/// A cloud bucket belongs to a composite when the provider matches and the
/// cloud name equals the composite's cloud name (`status.bucketName`, else
/// `spec.import.existingName`, else `metadata.name` — what every backend
/// names the bucket). The composite row keeps its own fields and only fills
/// gaps from the cloud row; unmatched cloud buckets stay as unmanaged rows.
pub fn merge(composites: Vec<Bucket>, cloud: Vec<Bucket>) -> Vec<Bucket> {
    let mut rows = composites;
    for found in cloud {
        let owner = rows.iter_mut().find(|row| {
            row.composite.is_some() && row.provider == found.provider && row.name == found.name
        });
        match owner {
            Some(row) => absorb(row, found),
            None => rows.push(found),
        }
    }
    for row in &mut rows {
        row.seen_in.sort_by_key(|source| Source::ALL.iter().position(|s| s == source));
        row.seen_in.dedup();
    }
    rows.sort_by(|a, b| (&a.provider, &a.name, &a.id).cmp(&(&b.provider, &b.name, &b.id)));
    rows
}

fn absorb(row: &mut Bucket, found: Bucket) {
    row.seen_in.extend(found.seen_in);
    row.region = row.region.take().or(found.region);
    row.storage_class = row.storage_class.take().or(found.storage_class);
    // The cloud knows when the bucket was made; an adopted bucket predates its XR.
    row.created = found.created.or(row.created.take());
    row.url = row.url.take().or(found.url);
    row.console_url = row.console_url.take().or(found.console_url);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, name: &str, provider: &str, source: Source, managed: bool) -> Bucket {
        Bucket {
            id: id.into(),
            name: name.into(),
            provider: provider.into(),
            region: None,
            storage_class: None,
            created: None,
            url: None,
            console_url: None,
            seen_in: vec![source],
            composite: managed.then(|| Composite {
                namespace: "default".into(),
                name: id.into(),
                ready: Some(true),
                synced: Some(true),
                mode: Some("created".into()),
                message: None,
            }),
        }
    }

    #[test]
    fn cloud_bucket_folds_into_its_composite() {
        let mut xr = row("xr:default/assets", "assets", "aws", Source::K8s, true);
        xr.region = Some("us-east-1".into());
        xr.created = Some("2026-01-01T00:00:00Z".into());
        let mut s3 = row("aws:assets", "assets", "aws", Source::Aws, false);
        s3.region = Some("eu-west-1".into());
        s3.created = Some("2024-05-05T00:00:00Z".into());
        s3.url = Some("s3://assets".into());

        let rows = merge(vec![xr], vec![s3]);

        assert_eq!(rows.len(), 1);
        let merged = &rows[0];
        assert_eq!(merged.id, "xr:default/assets");
        assert_eq!(merged.seen_in, vec![Source::K8s, Source::Aws]);
        assert_eq!(merged.region.as_deref(), Some("us-east-1"), "composite wins");
        assert_eq!(merged.created.as_deref(), Some("2024-05-05T00:00:00Z"), "cloud wins");
        assert_eq!(merged.url.as_deref(), Some("s3://assets"), "gap filled");
    }

    #[test]
    fn same_name_on_another_cloud_stays_unmanaged() {
        let xr = row("xr:default/assets", "assets", "aws", Source::K8s, true);
        let gcs = row("gcp:assets", "assets", "gcp", Source::Gcp, false);

        let rows = merge(vec![xr], vec![gcs]);

        assert_eq!(rows.len(), 2);
        let gcs = rows.iter().find(|r| r.provider == "gcp").unwrap();
        assert!(gcs.composite.is_none());
        assert_eq!(gcs.seen_in, vec![Source::Gcp]);
    }
}
