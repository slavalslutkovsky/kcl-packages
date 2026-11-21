//! Buckets straight from the clouds, through each cloud's own CLI.
//!
//! The CLIs, not the SDKs: they already carry the operator's login (SSO,
//! `gcloud auth`, `az login`), profiles and regions, so the console needs no
//! credentials of its own and lists exactly what the person running it can.

use std::io::ErrorKind;
use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;
use tokio::process::Command;

use crate::model::{Bucket, Failure, Source};

/// The program and arguments that list one cloud's buckets as JSON.
pub fn command(source: Source) -> (&'static str, &'static [&'static str]) {
    match source {
        Source::Aws => ("aws", &["s3api", "list-buckets", "--output", "json"]),
        Source::Gcp => ("gcloud", &["storage", "buckets", "list", "--format=json"]),
        Source::Azure => ("az", &["storage", "account", "list", "--output", "json"]),
        Source::K8s => unreachable!("k8s is listed through the API server, not a CLI"),
    }
}

pub fn label(source: Source) -> String {
    let (program, args) = command(source);
    format!("{program} {}", args.join(" "))
}

pub async fn list(source: Source, timeout: Duration) -> Result<Vec<Bucket>, Failure> {
    let (program, args) = command(source);
    let run = Command::new(program)
        .args(args)
        // Never wait on a login or a pager: fail and say so instead.
        .env("CLOUDSDK_CORE_DISABLE_PROMPTS", "1")
        .env("AWS_PAGER", "")
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = match tokio::time::timeout(timeout, run).await {
        Err(_) => return Err(Failure::Error(format!("{program} timed out after {timeout:?}"))),
        Ok(Err(e)) if e.kind() == ErrorKind::NotFound => {
            return Err(Failure::Unavailable(format!("`{program}` is not on PATH")));
        }
        Ok(Err(e)) => return Err(Failure::Error(format!("running {program}: {e}"))),
        Ok(Ok(output)) => output,
    };
    if !output.status.success() {
        return Err(Failure::Error(first_line(&output.stderr).unwrap_or_else(|| {
            format!("{program} exited with {}", output.status)
        })));
    }
    parse(source, &output.stdout).map_err(Failure::Error)
}

pub fn parse(source: Source, stdout: &[u8]) -> Result<Vec<Bucket>, String> {
    if stdout.iter().all(u8::is_ascii_whitespace) {
        return Ok(Vec::new());
    }
    let value: Value =
        serde_json::from_slice(stdout).map_err(|e| format!("unreadable {source} output: {e}"))?;
    let items = match source {
        Source::Aws => &value["Buckets"],
        _ => &value,
    };
    let items = items.as_array().map(Vec::as_slice).unwrap_or_default();
    Ok(items
        .iter()
        .filter_map(|item| match source {
            Source::Aws => aws(item),
            Source::Gcp => gcp(item),
            Source::Azure => azure(item),
            Source::K8s => None,
        })
        .collect())
}

/// `aws s3api list-buckets`: `Name`, `CreationDate`, and `BucketRegion`
/// (CLI v2.22+).
fn aws(item: &Value) -> Option<Bucket> {
    let name = text(&item["Name"])?;
    let region = text(&item["BucketRegion"]);
    let console = match &region {
        Some(region) => format!("https://s3.console.aws.amazon.com/s3/buckets/{name}?region={region}"),
        None => format!("https://s3.console.aws.amazon.com/s3/buckets/{name}"),
    };
    Some(Bucket {
        id: format!("aws:{name}"),
        url: Some(format!("s3://{name}")),
        console_url: Some(console),
        region,
        storage_class: None,
        created: text(&item["CreationDate"]),
        name,
        provider: "aws".into(),
        seen_in: vec![Source::Aws],
        composite: None,
    })
}

/// `gcloud storage buckets list --format=json`: `name`, `location`
/// (upper-case), `default_storage_class`, `storage_url`, `creation_time`.
fn gcp(item: &Value) -> Option<Bucket> {
    let name = text(&item["name"])?;
    Some(Bucket {
        id: format!("gcp:{name}"),
        region: text(&item["location"]).map(|l| l.to_lowercase()),
        storage_class: text(&item["default_storage_class"]),
        created: text(&item["creation_time"]),
        url: Some(
            text(&item["storage_url"])
                .map_or_else(|| format!("gs://{name}"), |url| url.trim_end_matches('/').to_string()),
        ),
        console_url: Some(format!("https://console.cloud.google.com/storage/browser/{name}")),
        name,
        provider: "gcp".into(),
        seen_in: vec![Source::Gcp],
        composite: None,
    })
}

/// `az storage account list`: the Azure backend of the Bucket XRD is a
/// storage account, so that is the unit listed. `accessTier` is the closest
/// thing to a storage class; premium accounts have none and fall back to
/// the SKU.
fn azure(item: &Value) -> Option<Bucket> {
    let name = text(&item["name"])?;
    Some(Bucket {
        id: format!("azure:{name}"),
        region: text(&item["location"]),
        storage_class: text(&item["accessTier"]).or_else(|| text(&item["sku"]["name"])),
        created: text(&item["creationTime"]),
        url: text(&item["primaryEndpoints"]["blob"]),
        console_url: text(&item["id"]).map(|id| format!("https://portal.azure.com/#resource{id}")),
        name,
        provider: "azure".into(),
        seen_in: vec![Source::Azure],
        composite: None,
    })
}

fn text(value: &Value) -> Option<String> {
    value.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

/// The CLIs put the actionable part first (`ERROR: … Please run gcloud auth
/// login`, `An error occurred (ExpiredToken) …`).
fn first_line(stderr: &[u8]) -> Option<String> {
    String::from_utf8_lossy(stderr)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| line.chars().take(300).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aws_listing() {
        let rows = parse(
            Source::Aws,
            br#"{"Buckets":[
                {"Name":"assets","CreationDate":"2024-05-05T00:00:00+00:00","BucketRegion":"eu-west-1"},
                {"Name":"legacy","CreationDate":"2019-01-01T00:00:00+00:00"}
            ],"Owner":{"ID":"x"}}"#,
        )
        .unwrap();

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].region.as_deref(), Some("eu-west-1"));
        assert_eq!(
            rows[0].console_url.as_deref(),
            Some("https://s3.console.aws.amazon.com/s3/buckets/assets?region=eu-west-1")
        );
        assert_eq!(rows[1].region, None);
        assert_eq!(rows[1].url.as_deref(), Some("s3://legacy"));
    }

    #[test]
    fn gcp_listing() {
        let rows = parse(
            Source::Gcp,
            br#"[{"name":"logs-7f3a","location":"EUROPE-WEST1","default_storage_class":"STANDARD",
                  "storage_url":"gs://logs-7f3a/","creation_time":"2026-02-01T10:00:00+0000"}]"#,
        )
        .unwrap();

        assert_eq!(rows[0].region.as_deref(), Some("europe-west1"));
        assert_eq!(rows[0].url.as_deref(), Some("gs://logs-7f3a"));
        assert_eq!(rows[0].storage_class.as_deref(), Some("STANDARD"));
    }

    #[test]
    fn azure_listing() {
        let rows = parse(
            Source::Azure,
            br#"[{"name":"releaseartifactsaz","location":"westeurope","accessTier":"Hot",
                  "sku":{"name":"Standard_LRS"},"creationTime":"2026-03-01T00:00:00Z",
                  "primaryEndpoints":{"blob":"https://releaseartifactsaz.blob.core.windows.net/"},
                  "id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/releaseartifactsaz"}]"#,
        )
        .unwrap();

        assert_eq!(rows[0].storage_class.as_deref(), Some("Hot"));
        assert_eq!(
            rows[0].console_url.as_deref(),
            Some("https://portal.azure.com/#resource/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/releaseartifactsaz")
        );
    }

    #[test]
    fn empty_output_is_no_buckets() {
        assert_eq!(parse(Source::Gcp, b"\n").unwrap(), Vec::new());
        assert!(parse(Source::Aws, b"not json").is_err());
    }
}
