//! `Bucket` composites (`buckets.cloud.example.org/v1alpha1`, see
//! `packages/cloud/bucket/xrd`) in whatever cluster the kubeconfig points at.

use kube::api::{Api, ApiResource, DynamicObject, GroupVersionKind, ListParams};
use kube::config::Kubeconfig;
use kube::Client;
use serde_json::Value;

use crate::model::{Bucket, Composite, Failure, Source};

const GROUP: &str = "cloud.example.org";
const VERSION: &str = "v1alpha1";
const KIND: &str = "Bucket";
const PLURAL: &str = "buckets";

pub struct Cluster {
    client: Result<Client, String>,
    /// `context <name>` from the kubeconfig, or `in-cluster`.
    pub label: String,
}

impl Cluster {
    /// Never fails: a missing kubeconfig is reported per request as an
    /// unavailable source, so the clouds still answer.
    pub async fn connect() -> Self {
        let label = Kubeconfig::read()
            .ok()
            .and_then(|config| config.current_context)
            .map_or_else(|| "in-cluster".to_string(), |context| format!("context {context}"));
        let client = Client::try_default().await.map_err(|e| e.to_string());
        Cluster { client, label }
    }

    pub async fn buckets(&self) -> Result<Vec<Bucket>, Failure> {
        let client = self
            .client
            .as_ref()
            .map_err(|e| Failure::Unavailable(format!("no cluster: {e}")))?;
        let resource = ApiResource::from_gvk_with_plural(
            &GroupVersionKind::gvk(GROUP, VERSION, KIND),
            PLURAL,
        );
        let api: Api<DynamicObject> = Api::all_with(client.clone(), &resource);
        let list = api.list(&ListParams::default()).await.map_err(|error| match error {
            kube::Error::Api(response) if response.code == 404 => Failure::Unavailable(format!(
                "the {PLURAL}.{GROUP} XRD is not installed (packages/cloud/bucket/xrd)"
            )),
            other => Failure::Error(chain(&other)),
        })?;
        list.items
            .iter()
            .map(|xr| serde_json::to_value(xr).map(|value| from_xr(&value)))
            .collect::<Result<_, _>>()
            .map_err(|e| Failure::Error(format!("decoding a Bucket: {e}")))
    }
}

/// One row per composite. The cloud name is what every backend names the
/// bucket: `status.bucketName`, else `spec.import.existingName`, else
/// `metadata.name`.
pub fn from_xr(xr: &Value) -> Bucket {
    let meta = &xr["metadata"];
    let spec = &xr["spec"];
    let status = &xr["status"];
    let namespace = text(&meta["namespace"]).unwrap_or_default();
    let name = text(&meta["name"]).unwrap_or_default();

    let provider = text(&status["provider"])
        .or_else(|| text(&spec["crossplane"]["compositionSelector"]["matchLabels"]["provider"]))
        .or_else(|| {
            text(&spec["crossplane"]["compositionRef"]["name"])
                .and_then(|composition| composition.strip_prefix("bucket-").map(str::to_string))
        })
        .unwrap_or_else(|| "unknown".to_string());

    let conditions = status["conditions"].as_array().map(Vec::as_slice).unwrap_or_default();
    let condition = |kind: &str| {
        conditions
            .iter()
            .find(|c| c["type"] == kind)
            .and_then(|c| c["status"].as_str())
            .map(|s| s == "True")
    };
    let message = conditions.iter().find(|c| c["status"] != "True").map(|c| {
        let reason = c["reason"].as_str().unwrap_or("NotReady");
        match c["message"].as_str() {
            Some(message) if !message.is_empty() => format!("{reason}: {message}"),
            _ => reason.to_string(),
        }
    });

    Bucket {
        id: format!("xr:{namespace}/{name}"),
        name: text(&status["bucketName"])
            .or_else(|| text(&spec["import"]["existingName"]))
            .unwrap_or_else(|| name.clone()),
        provider,
        region: text(&status["region"]).or_else(|| text(&spec["region"])),
        storage_class: text(&status["storageClass"]).or_else(|| text(&spec["storageClass"])),
        created: text(&meta["creationTimestamp"]),
        url: text(&status["url"]),
        console_url: text(&status["cloud-url"]),
        seen_in: vec![Source::K8s],
        composite: Some(Composite {
            ready: status["ready"].as_bool().or_else(|| condition("Ready")),
            synced: condition("Synced"),
            mode: text(&status["mode"]),
            message,
            namespace,
            name,
        }),
    }
}

/// kube's top-level message for a dead API server is `ServiceError: client
/// error (Connect)`; the cause (`connection refused`, a TLS failure) is
/// further down the source chain.
fn chain(error: &dyn std::error::Error) -> String {
    let mut message = error.to_string();
    let mut cause = error.source();
    while let Some(next) = cause {
        let text = next.to_string();
        if !message.contains(&text) {
            message = format!("{message}: {text}");
        }
        cause = next.source();
    }
    message
}

fn text(value: &Value) -> Option<String> {
    value.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn adopted_bucket_without_status_uses_spec() {
        let bucket = from_xr(&json!({
            "metadata": {"namespace": "team-a", "name": "logs", "creationTimestamp": "2026-02-01T10:00:00Z"},
            "spec": {
                "region": "europe-west1",
                "import": {"existingName": "logs-7f3a", "mode": "observe"},
                "crossplane": {"compositionRef": {"name": "bucket-gcp"}}
            },
            "status": {"conditions": [
                {"type": "Synced", "status": "True", "reason": "ReconcileSuccess"},
                {"type": "Ready", "status": "False", "reason": "Creating", "message": "waiting for the provider"}
            ]}
        }));

        assert_eq!(bucket.id, "xr:team-a/logs");
        assert_eq!(bucket.name, "logs-7f3a");
        assert_eq!(bucket.provider, "gcp");
        assert_eq!(bucket.region.as_deref(), Some("europe-west1"));
        let composite = bucket.composite.unwrap();
        assert_eq!(composite.ready, Some(false));
        assert_eq!(composite.synced, Some(true));
        assert_eq!(composite.message.as_deref(), Some("Creating: waiting for the provider"));
    }

    #[test]
    fn status_written_by_the_backend_wins() {
        let bucket = from_xr(&json!({
            "metadata": {"namespace": "default", "name": "assets"},
            "spec": {
                "region": "us-east-1",
                "crossplane": {"compositionSelector": {"matchLabels": {"provider": "aws"}}}
            },
            "status": {
                "ready": true, "provider": "aws", "mode": "created",
                "bucketName": "assets", "region": "us-east-1",
                "url": "s3://assets",
                "cloud-url": "https://s3.console.aws.amazon.com/s3/buckets/assets?region=us-east-1"
            }
        }));

        assert_eq!(bucket.url.as_deref(), Some("s3://assets"));
        assert!(bucket.console_url.unwrap().starts_with("https://s3.console.aws.amazon.com/"));
        let composite = bucket.composite.unwrap();
        assert_eq!(composite.ready, Some(true));
        assert_eq!(composite.mode.as_deref(), Some("created"));
        assert_eq!(composite.message, None);
    }
}
