//! The `KclModule` custom resource: a KCL package plus the inputs to render
//! it with, and the record of what that render put in the cluster.
//!
//! One deliberate asymmetry with the Crossplane path: a Composition renders
//! *desired state* that Crossplane owns and applies, while a `KclModule`
//! applies the rendered objects itself. What it applies is tracked in
//! `status.inventory`, which is the only mechanism for cleanup — see
//! [`crate::apply`] for why owner references are not used.

use std::fmt;
use std::time::Duration;

use k8s_openapi::apimachinery::pkg::apis::meta::v1::{Condition, Time};
use kube::CustomResource;
use schemars::{JsonSchema, Schema, json_schema};
use serde::{Deserialize, Serialize};

/// Applied to every object a module renders, so `kubectl get … -l` finds them
/// even when the status is gone.
pub const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by";
pub const MANAGED_BY: &str = "kclx";
/// `<namespace>.<name>` of the owning module.
pub const MODULE_LABEL: &str = "kclx.example.org/module";
/// Removed only once the inventory is gone from the cluster.
pub const FINALIZER: &str = "kclx.example.org/inventory";
/// Condition type: the render succeeded and every object is applied.
pub const READY: &str = "Ready";

/// Render a KCL package and apply what it produces.
///
/// `spec.source` takes the same three shapes the CLI and the composition
/// function take (`oci://…?tag=…`, a path, or inline KCL), so a package can be
/// rehearsed with `kclx render` and then handed to the operator unchanged.
#[derive(CustomResource, Clone, Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[kube(
    group = "kclx.example.org",
    version = "v1alpha1",
    kind = "KclModule",
    plural = "kclmodules",
    shortname = "kclm",
    namespaced,
    status = "KclModuleStatus",
    derive = "PartialEq",
    // Both the source (a whole KCL program when inline) and the condition
    // message (a multi-line compile error when it fails) are unbounded, and
    // one unbounded column ruins the whole table. `priority: 1` keeps them
    // for `kubectl get -o wide`, and the bounded reason for the default.
    printcolumn = r#"{"name":"Ready","type":"string","jsonPath":".status.conditions[?(@.type==\"Ready\")].status"}"#,
    printcolumn = r#"{"name":"Reason","type":"string","jsonPath":".status.conditions[?(@.type==\"Ready\")].reason"}"#,
    printcolumn = r#"{"name":"Source","type":"string","jsonPath":".spec.source","priority":1}"#,
    printcolumn = r#"{"name":"Status","type":"string","jsonPath":".status.conditions[?(@.type==\"Ready\")].message","priority":1}"#,
    printcolumn = r#"{"name":"Age","type":"date","jsonPath":".metadata.creationTimestamp"}"#
)]
#[serde(rename_all = "camelCase")]
pub struct KclModuleSpec {
    /// `oci://host/repo?tag=x.y.z`, a path inside the operator image, or
    /// inline KCL.
    pub source: String,

    /// Becomes `option("params")` — the input contract every package in this
    /// repo already reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "free_form_object")]
    pub params: Option<serde_json::Value>,

    #[serde(default)]
    pub options: RenderOptions,

    /// How often to re-render and re-apply, which is also how quickly manual
    /// edits to the applied objects are corrected. `30s`, `5m`, `1h`.
    #[serde(default = "default_interval")]
    pub interval: String,

    /// Namespace for rendered namespaced objects that do not name one.
    /// Defaults to the module's own namespace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_namespace: Option<String>,

    /// Delete objects that were in the previous render and are not in this
    /// one. Turning it off leaks objects on purpose (hand-off to another
    /// owner); cleanup on module deletion is unaffected.
    #[serde(default = "default_true")]
    pub prune: bool,

    /// Stop reconciling without deleting anything.
    #[serde(default)]
    pub suspend: bool,
}

/// The `kcl run` flags that make sense for an operator. Deliberately a subset
/// of [`kcl_render::Options`]: `-O`/`-S` rewrite or select part of the plan,
/// which is a rendering trick, not a deployment one, and `vendor` is about a
/// working tree.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", default)]
pub struct RenderOptions {
    /// `-D name=value`, applied after `params`.
    pub arguments: Vec<String>,

    /// `-n`. On by default: KCL emits `null` for every unset optional
    /// attribute, and a server-side apply that carries explicit nulls fails
    /// on typed fields.
    pub disable_none: bool,

    pub sort_keys: bool,
}

/// Hand-written rather than derived, because `derive(Default)` would make
/// `disableNone` false for a spec that omits `options` entirely — the common
/// case — while a spec that writes `options: {}` got true from the field
/// default. One default, both paths.
impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            arguments: Vec::new(),
            disable_none: true,
            sort_keys: false,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", default)]
pub struct KclModuleStatus {
    /// `metadata.generation` of the spec this status describes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed_generation: Option<i64>,

    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub conditions: Vec<Condition>,

    /// Every object the last successful apply owns. The only cleanup and
    /// prune input there is.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub inventory: Vec<ResourceRef>,

    /// SHA-256 of the rendered items, so an unchanged render is visible as
    /// such without diffing the cluster.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_applied_hash: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_applied_time: Option<Time>,
}

/// One applied object, in the form that identifies it uniquely to the API
/// server.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ResourceRef {
    pub api_version: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
}

impl fmt::Display for ResourceRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.namespace {
            Some(ns) => write!(f, "{} {ns}/{}", self.kind, self.name),
            None => write!(f, "{} {}", self.kind, self.name),
        }
    }
}

impl KclModule {
    /// Namespace rendered namespaced objects land in when they name none.
    pub fn target_namespace(&self) -> &str {
        self.spec
            .target_namespace
            .as_deref()
            .or(self.metadata.namespace.as_deref())
            .unwrap_or("default")
    }

    /// `<namespace>.<name>`, the value of [`MODULE_LABEL`].
    pub fn label_value(&self) -> String {
        format!(
            "{}.{}",
            self.metadata.namespace.as_deref().unwrap_or("default"),
            self.metadata.name.as_deref().unwrap_or_default()
        )
    }
}

/// `30s`, `5m`, `1h`, or bare seconds. Deliberately not a full Go duration
/// parser: an interval is one number and one unit, and anything else is more
/// likely a typo than an intent.
pub fn parse_interval(text: &str) -> Result<Duration, String> {
    let text = text.trim();
    let (digits, unit) = match text.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((at, _)) => text.split_at(at),
        None => (text, "s"),
    };
    let value: u64 = digits
        .parse()
        .map_err(|_| format!("interval {text:?} does not start with a number"))?;
    let seconds = match unit {
        "s" => value,
        "m" => value * 60,
        "h" => value * 3600,
        other => return Err(format!("interval {text:?} has unknown unit {other:?}")),
    };
    if seconds == 0 {
        return Err(format!("interval {text:?} must be greater than zero"));
    }
    Ok(Duration::from_secs(seconds))
}

/// Insert or update `new` in `conditions`, keeping the existing
/// `lastTransitionTime` when the status did not change — that timestamp is
/// "since when", and rewriting it every reconcile destroys the only
/// flapping signal an operator has.
pub fn set_condition(conditions: &mut Vec<Condition>, new: Condition) {
    match conditions.iter_mut().find(|c| c.type_ == new.type_) {
        Some(existing) => {
            let transition = if existing.status == new.status {
                existing.last_transition_time.clone()
            } else {
                new.last_transition_time.clone()
            };
            *existing = Condition {
                last_transition_time: transition,
                ..new
            };
        }
        None => conditions.push(new),
    }
}

/// A `Ready` condition stamped now. `status` is `"True"`, `"False"` or
/// `"Unknown"` — the three the convention allows, and `Unknown` is the one a
/// suspended module needs.
pub fn ready_condition(
    status: &str,
    reason: &str,
    message: impl Into<String>,
    observed_generation: Option<i64>,
    now: Time,
) -> Condition {
    let mut message = message.into();
    // The API server rejects a condition message longer than 32768 bytes, and
    // a KCL compile error can be long.
    if message.len() > 32_000 {
        message.truncate(32_000);
        message.push('…');
    }
    Condition {
        type_: READY.to_string(),
        status: status.to_string(),
        reason: reason.to_string(),
        message,
        observed_generation,
        last_transition_time: now,
    }
}

fn default_interval() -> String {
    "5m".to_string()
}

fn default_true() -> bool {
    true
}

/// `params` is whatever the package's schema accepts, so the CRD must not
/// prune it. Structural schemas express that with
/// `x-kubernetes-preserve-unknown-fields`.
fn free_form_object(_: &mut schemars::SchemaGenerator) -> Schema {
    json_schema!({
        "type": "object",
        "x-kubernetes-preserve-unknown-fields": true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn time(secs: i64) -> Time {
        Time(k8s_openapi::jiff::Timestamp::from_second(secs).expect("valid timestamp"))
    }

    #[test]
    fn intervals_accept_a_unit_and_reject_nonsense() {
        assert_eq!(parse_interval("30s").unwrap(), Duration::from_secs(30));
        assert_eq!(parse_interval("5m").unwrap(), Duration::from_secs(300));
        assert_eq!(parse_interval("1h").unwrap(), Duration::from_secs(3600));
        assert_eq!(parse_interval("45").unwrap(), Duration::from_secs(45));
        assert!(parse_interval("5d").is_err());
        assert!(parse_interval("soon").is_err());
        assert!(parse_interval("0s").is_err());
    }

    #[test]
    fn an_unchanged_status_keeps_its_transition_time() {
        let mut conditions = vec![ready_condition(
            "True",
            "Applied",
            "3 objects",
            Some(1),
            time(10),
        )];
        set_condition(
            &mut conditions,
            ready_condition("True", "Applied", "4 objects", Some(2), time(99)),
        );
        assert_eq!(conditions.len(), 1);
        assert_eq!(conditions[0].last_transition_time, time(10));
        assert_eq!(conditions[0].message, "4 objects");
        assert_eq!(conditions[0].observed_generation, Some(2));
    }

    #[test]
    fn a_flip_moves_the_transition_time() {
        let mut conditions = vec![ready_condition("True", "Applied", "ok", Some(1), time(10))];
        set_condition(
            &mut conditions,
            ready_condition("False", "RenderFailed", "boom", Some(1), time(99)),
        );
        assert_eq!(conditions[0].status, "False");
        assert_eq!(conditions[0].last_transition_time, time(99));
    }

    #[test]
    fn a_long_message_is_truncated_to_what_the_api_server_accepts() {
        let condition = ready_condition("False", "RenderFailed", "x".repeat(40_000), None, time(0));
        assert!(condition.message.len() <= 32_004);
    }

    #[test]
    fn target_namespace_prefers_the_spec_then_the_modules_own() {
        let mut module = KclModule::new("demo", KclModuleSpec {
            source: "a = 1".into(),
            params: None,
            options: RenderOptions::default(),
            interval: default_interval(),
            target_namespace: None,
            prune: true,
            suspend: false,
        });
        module.metadata.namespace = Some("apps".into());
        assert_eq!(module.target_namespace(), "apps");
        assert_eq!(module.label_value(), "apps.demo");

        module.spec.target_namespace = Some("elsewhere".into());
        assert_eq!(module.target_namespace(), "elsewhere");
    }
}
