//! Rendered KCL items → Crossplane desired state.
//!
//! This is the half of a composition function that has nothing to do with
//! gRPC, so it lives in the library: `kclx render --view desired` prints
//! exactly what `kclx function` puts on the wire, which is the whole point of
//! sharing a crate between the two.
//!
//! The conventions are `function-kcl`'s, because every package in
//! `packages/cloud/**` is already written against them:
//! `krm.kcl.dev/composition-resource-name` names a composed resource,
//! `krm.kcl.dev/ready` forces its readiness, and an item whose GVK equals the
//! composite's is a patch for the composite rather than a composed resource.
//! An item under [`META_API_VERSION`] is not composed at all: it tells the
//! function something, and so far that means declaring required resources.

use std::collections::BTreeMap;

use anyhow::{Result, anyhow, bail};
use serde::Deserialize;
use serde_json::{Map, Value};

pub const ANNOTATION_RESOURCE_NAME: &str = "krm.kcl.dev/composition-resource-name";
pub const ANNOTATION_READY: &str = "krm.kcl.dev/ready";
/// Items under this group are instructions to the function rather than
/// objects to compose (`function-kcl`'s `MetaApiVersion`).
pub const META_API_VERSION: &str = "meta.krm.kcl.dev/v1alpha1";

/// What the rendered items mean. Mirrors `KCLInput.spec.target`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Target {
    /// Items whose GVK matches the composite patch the composite; everything
    /// else is a composed resource.
    #[default]
    Default,
    /// Every item is a composed resource.
    Resources,
    /// Every item patches an already-desired resource with the same name.
    PatchDesired,
    /// Every item patches a resource seeded from `bases`.
    PatchResources,
    /// Every item patches the composite.
    #[serde(rename = "XR")]
    Xr,
}

/// Readiness a KCL package can force on a composed resource.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Ready {
    #[default]
    Unspecified,
    True,
    False,
}

impl Ready {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "True" => Ok(Ready::True),
            "False" => Ok(Ready::False),
            "Unspecified" => Ok(Ready::Unspecified),
            other => bail!("{ANNOTATION_READY} must be True, False or Unspecified, got {other:?}"),
        }
    }
}

/// A composed resource, keyed by its composition resource name (the key of
/// `RunFunctionResponse.desired.resources`, not `metadata.name`).
#[derive(Debug, Clone, PartialEq)]
pub struct Composed {
    pub name: String,
    pub ready: Ready,
    pub resource: Value,
}

/// Desired state being built up. Starts from whatever earlier pipeline steps
/// desired — dropping that would delete their resources.
#[derive(Debug, Clone, Default)]
pub struct Desired {
    pub composite: Value,
    pub resources: Vec<Composed>,
}

impl Desired {
    pub fn get(&self, name: &str) -> Option<&Composed> {
        self.resources.iter().find(|r| r.name == name)
    }

    fn upsert(&mut self, composed: Composed) {
        match self.resources.iter_mut().find(|r| r.name == composed.name) {
            // Same shallow-merge-per-top-level-key rule function-kcl uses for
            // the Resources target: KCL wins on the keys it sets.
            Some(existing) => {
                if let (Value::Object(dst), Value::Object(src)) =
                    (&mut existing.resource, &composed.resource)
                {
                    for (k, v) in src {
                        dst.insert(k.clone(), v.clone());
                    }
                } else {
                    existing.resource = composed.resource;
                }
                if composed.ready != Ready::Unspecified {
                    existing.ready = composed.ready;
                }
            }
            None => self.resources.push(composed),
        }
    }

    /// Patch an existing desired resource. `apiVersion`, `kind` and
    /// `metadata.name` are identity: repointing a desired resource at another
    /// GVK or name orphans the live one, so they survive the patch.
    fn patch(&mut self, name: &str, patch: &Value) -> Result<()> {
        let target = self
            .resources
            .iter_mut()
            .find(|r| r.name == name)
            .ok_or_else(|| anyhow!("no desired resource named {name:?} to patch"))?;
        let identity: Vec<(&str, Option<Value>)> = ["/apiVersion", "/kind", "/metadata/name"]
            .iter()
            .map(|p| (*p, target.resource.pointer(p).cloned()))
            .collect();
        merge_patch(&mut target.resource, patch);
        for (pointer, value) in identity {
            if let (Some(value), Some(slot)) = (value, target.resource.pointer_mut(pointer)) {
                *slot = value;
            }
        }
        Ok(())
    }
}

/// How a required resource is matched. A name wins over labels, and labels
/// with no entries match every resource of the GVK: both are function-kcl's
/// rules (`RequiredResourcesRequirement.ToResourceSelector`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectorMatch {
    Name(String),
    Labels(BTreeMap<String, String>),
}

/// One entry of `RunFunctionResponse.requirements`. Owned and protobuf-free:
/// this crate has no function-sdk dependency, so the conversion to a
/// `ResourceSelector` happens in `kclx`, where the proto already lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequiredResource {
    pub api_version: String,
    pub kind: String,
    /// `None` looks up a cluster-scoped resource — the proto field stays
    /// unset, which is not the same as an empty string.
    pub namespace: Option<String>,
    pub r#match: SelectorMatch,
}

/// What the module asked Crossplane to fetch before the next iteration.
///
/// This is not desired state — it is a sibling field of the response, and
/// Crossplane re-runs the whole step while it keeps changing — so [`apply`]
/// returns it instead of hiding it inside [`Desired`]. `BTreeMap` because the
/// keys are reported in duplicate errors, and a stable order keeps those
/// messages reproducible.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Requirements {
    pub resources: BTreeMap<String, RequiredResource>,
    pub extra_resources: BTreeMap<String, RequiredResource>,
}

impl Requirements {
    pub fn is_empty(&self) -> bool {
        self.resources.is_empty() && self.extra_resources.is_empty()
    }
}

/// One value of a meta item's `requirements` map, in function-kcl's field
/// names (`RequiredResourcesRequirement`). Unknown fields are rejected: a
/// mistyped key would otherwise silently select the wrong resource, and
/// Crossplane reports "not found" as an empty list rather than an error.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Requirement {
    api_version: String,
    kind: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    namespace: String,
    #[serde(default)]
    match_labels: BTreeMap<String, String>,
}

impl Requirement {
    fn into_required(self) -> RequiredResource {
        RequiredResource {
            api_version: self.api_version,
            kind: self.kind,
            namespace: (!self.namespace.is_empty()).then_some(self.namespace),
            r#match: if self.name.is_empty() {
                SelectorMatch::Labels(self.match_labels)
            } else {
                SelectorMatch::Name(self.name)
            },
        }
    }
}

/// An item under [`META_API_VERSION`] is an instruction to the function, not
/// an object to compose. Callers that count composed resources need the same
/// test to keep such items out of the tally.
pub fn is_meta(item: &Value) -> bool {
    gvk(item).0 == Some(META_API_VERSION)
}

/// Fold `items` into `desired`, returning what the module asked Crossplane to
/// fetch before the next iteration.
///
/// `observed_composite` is the observed XR; only its GVK is consulted, to
/// recognise composite patches under [`Target::Default`].
pub fn apply(
    items: &[Value],
    target: Target,
    observed_composite: &Value,
    desired: &mut Desired,
) -> Result<Requirements> {
    let xr_gvk = gvk(observed_composite);
    let mut seen: Vec<String> = Vec::with_capacity(items.len());
    let mut requirements = Requirements::default();

    for item in items {
        let mut item = item.clone();
        if !item.is_object() {
            bail!("rendered item is not an object: {item}");
        }
        // Before naming: a meta item carries no name, and only the default
        // target reads them — the same place function-kcl dispatches them.
        if target == Target::Default && is_meta(&item) {
            collect_meta(&item, &mut requirements)?;
            continue;
        }
        let ready = take_ready(&mut item)?;
        let name = take_name(&mut item)?;

        let is_composite_patch = match target {
            Target::Xr => true,
            Target::Default => gvk(&item) == xr_gvk && xr_gvk != (None, None),
            _ => false,
        };
        if is_composite_patch {
            patch_composite(&mut desired.composite, &item, target)?;
            continue;
        }

        match target {
            Target::PatchDesired | Target::PatchResources => {
                let name = name.ok_or_else(|| {
                    anyhow!("patch items need metadata.name or {ANNOTATION_RESOURCE_NAME}")
                })?;
                desired.patch(&name, &item)?;
            }
            _ => {
                let name = name.ok_or_else(|| {
                    anyhow!(
                        "composed resource needs metadata.name or {ANNOTATION_RESOURCE_NAME}: {item}"
                    )
                })?;
                if seen.contains(&name) {
                    bail!("duplicate composition resource name {name:?}");
                }
                seen.push(name.clone());
                desired.upsert(Composed { name, ready, resource: item });
            }
        }
    }
    Ok(requirements)
}

/// A meta item's `requirements` map into `requirements`. The two kinds differ
/// only in which map they land in: `RequiredResources` is the supported
/// mechanism, `ExtraResources` the deprecated one Crossplane still honours.
fn collect_meta(item: &Value, requirements: &mut Requirements) -> Result<()> {
    let kind = gvk(item).1.unwrap_or_default();
    let (label, into) = match kind {
        "RequiredResources" => ("required resource", &mut requirements.resources),
        "ExtraResources" => ("extra resource", &mut requirements.extra_resources),
        other => bail!(
            "unsupported {META_API_VERSION} kind {other:?}: only RequiredResources and ExtraResources are supported"
        ),
    };
    let field = item
        .get("requirements")
        .ok_or_else(|| anyhow!("{META_API_VERSION} {kind} needs a requirements map: {item}"))?;
    let declared = BTreeMap::<String, Requirement>::deserialize(field)
        .map_err(|e| anyhow!("invalid {META_API_VERSION} {kind} requirements: {e}"))?;
    for (key, requirement) in declared {
        if into.contains_key(&key) {
            bail!("duplicate {label} key {key:?}");
        }
        into.insert(key, requirement.into_required());
    }
    Ok(())
}

/// Seed desired resources from a Composition's `bases` (the `PatchResources`
/// target), leaving anything already desired untouched.
pub fn seed_bases(desired: &mut Desired, bases: &[(String, Value)]) {
    for (name, base) in bases {
        if desired.get(name).is_none() {
            desired
                .resources
                .push(Composed { name: name.clone(), ready: Ready::Unspecified, resource: base.clone() });
        }
    }
}

/// Under `Default`, an item that *is* the composite only contributes its
/// `status` — its spec belongs to the user, and writing it back fights the
/// API server. Under `XR`, the whole item is merged.
fn patch_composite(composite: &mut Value, item: &Value, target: Target) -> Result<()> {
    if target == Target::Xr {
        merge_patch(composite, item);
        return Ok(());
    }
    if let Some(status) = item.get("status") {
        let dst = composite
            .as_object_mut()
            .ok_or_else(|| anyhow!("desired composite is not an object"))?
            .entry("status")
            .or_insert_with(|| Value::Object(Map::new()));
        merge_patch(dst, status);
    }
    Ok(())
}

/// `metadata.annotations["krm.kcl.dev/composition-resource-name"]`, else
/// `metadata.name`. The annotation is stripped: it is Crossplane bookkeeping,
/// not something to send to the API server.
fn take_name(item: &mut Value) -> Result<Option<String>> {
    let from_annotation = take_annotation(item, ANNOTATION_RESOURCE_NAME);
    if let Some(name) = from_annotation {
        return Ok(Some(name));
    }
    Ok(item
        .pointer("/metadata/name")
        .and_then(Value::as_str)
        .map(str::to_string))
}

fn take_ready(item: &mut Value) -> Result<Ready> {
    match take_annotation(item, ANNOTATION_READY) {
        Some(value) => Ready::parse(&value),
        None => Ok(Ready::Unspecified),
    }
}

fn take_annotation(item: &mut Value, key: &str) -> Option<String> {
    let annotations = item.pointer_mut("/metadata/annotations")?.as_object_mut()?;
    let value = annotations.remove(key)?.as_str()?.to_string();
    if annotations.is_empty() {
        // An empty annotations map is noise in the diff Crossplane shows.
        item.pointer_mut("/metadata")?.as_object_mut()?.remove("annotations");
    }
    Some(value)
}

fn gvk(value: &Value) -> (Option<&str>, Option<&str>) {
    (
        value.get("apiVersion").and_then(Value::as_str),
        value.get("kind").and_then(Value::as_str),
    )
}

/// Recursive object merge: `src` wins on leaves, maps are merged, lists and
/// scalars replace. `null` deletes, matching JSON merge patch — a KCL package
/// can therefore remove a field an earlier pipeline step set.
pub fn merge_patch(dst: &mut Value, src: &Value) {
    match (dst, src) {
        (Value::Object(dst), Value::Object(src)) => {
            for (key, value) in src {
                if value.is_null() {
                    dst.remove(key);
                    continue;
                }
                match dst.get_mut(key) {
                    Some(existing) => merge_patch(existing, value),
                    None => {
                        dst.insert(key.clone(), value.clone());
                    }
                }
            }
        }
        (dst, src) => *dst = src.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn xr() -> Value {
        json!({
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "ApiGateway",
            "metadata": {"name": "demo"},
            "spec": {"region": "us-east-1"}
        })
    }

    fn meta(kind: &str, requirements: Value) -> Value {
        json!({"apiVersion": META_API_VERSION, "kind": kind, "requirements": requirements})
    }

    #[test]
    fn annotation_names_the_resource_and_is_stripped() {
        let items = vec![json!({
            "apiVersion": "apigatewayv2.aws.m.upbound.io/v1beta1",
            "kind": "API",
            "metadata": {"annotations": {ANNOTATION_RESOURCE_NAME: "managed", "crossplane.io/external-name": "demo"}}
        })];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        apply(&items, Target::Default, &xr(), &mut desired).unwrap();

        let composed = &desired.resources[0];
        assert_eq!(composed.name, "managed");
        assert_eq!(composed.resource["metadata"]["annotations"], json!({"crossplane.io/external-name": "demo"}));
        assert!(composed.resource["metadata"]["annotations"].get(ANNOTATION_RESOURCE_NAME).is_none());
    }

    #[test]
    fn metadata_name_is_the_fallback_and_annotations_map_is_dropped_when_emptied() {
        let items = vec![json!({
            "apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": "cm", "annotations": {ANNOTATION_READY: "True"}}
        })];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        apply(&items, Target::Resources, &xr(), &mut desired).unwrap();

        assert_eq!(desired.resources[0].name, "cm");
        assert_eq!(desired.resources[0].ready, Ready::True);
        assert!(desired.resources[0].resource["metadata"].get("annotations").is_none());
    }

    #[test]
    fn composite_items_contribute_only_status() {
        let items = vec![json!({
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "ApiGateway",
            "spec": {"region": "eu-west-1"},
            "status": {"endpoint": "https://x"}
        })];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        apply(&items, Target::Default, &xr(), &mut desired).unwrap();

        assert!(desired.resources.is_empty(), "the XR is not a composed resource");
        assert_eq!(desired.composite["status"]["endpoint"], "https://x");
        assert_eq!(desired.composite["spec"]["region"], "us-east-1", "spec must not be written back");
    }

    #[test]
    fn xr_target_merges_the_whole_item() {
        let items = vec![json!({"spec": {"region": "eu-west-1"}, "status": {"ok": true}})];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        apply(&items, Target::Xr, &xr(), &mut desired).unwrap();
        assert_eq!(desired.composite["spec"]["region"], "eu-west-1");
        assert_eq!(desired.composite["status"]["ok"], true);
    }

    #[test]
    fn bad_ready_annotation_is_an_error() {
        let items = vec![json!({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "cm", "annotations": {ANNOTATION_READY: "yes"}}})];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        assert!(apply(&items, Target::Resources, &xr(), &mut desired).is_err());
    }

    #[test]
    fn patch_desired_requires_an_existing_resource() {
        let mut desired = Desired {
            composite: xr(),
            resources: vec![Composed {
                name: "managed".into(),
                ready: Ready::Unspecified,
                resource: json!({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "cm"}, "data": {"a": "1"}}),
            }],
        };
        let items = vec![json!({"metadata": {"annotations": {ANNOTATION_RESOURCE_NAME: "managed"}}, "data": {"b": "2"}})];
        apply(&items, Target::PatchDesired, &xr(), &mut desired).unwrap();
        assert_eq!(desired.resources[0].resource["data"], json!({"a": "1", "b": "2"}));

        let missing = vec![json!({"metadata": {"name": "nope"}, "data": {}})];
        assert!(apply(&missing, Target::PatchDesired, &xr(), &mut desired).is_err());
    }

    #[test]
    fn merge_patch_deletes_on_null() {
        let mut dst = json!({"a": {"b": 1, "c": 2}, "list": [1]});
        merge_patch(&mut dst, &json!({"a": {"b": null, "d": 3}, "list": [2, 3]}));
        assert_eq!(dst, json!({"a": {"c": 2, "d": 3}, "list": [2, 3]}));
    }

    #[test]
    fn required_resources_become_selectors_and_not_composed_resources() {
        let items = vec![
            meta(
                "RequiredResources",
                json!({"entitlement": {"apiVersion": "platform.example.org/v1alpha1", "kind": "Entitlement", "name": "team-a"}}),
            ),
            meta(
                "ExtraResources",
                json!({"quota": {"apiVersion": "v1", "kind": "ConfigMap", "name": "quota", "namespace": "kube-system"}}),
            ),
        ];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        let requirements = apply(&items, Target::Default, &xr(), &mut desired).unwrap();

        assert!(desired.resources.is_empty(), "meta items are not composed: {:?}", desired.resources);
        assert_eq!(
            requirements.resources["entitlement"],
            RequiredResource {
                api_version: "platform.example.org/v1alpha1".into(),
                kind: "Entitlement".into(),
                namespace: None,
                r#match: SelectorMatch::Name("team-a".into()),
            },
            "an absent namespace is a cluster-scoped lookup"
        );
        assert_eq!(requirements.extra_resources["quota"].namespace.as_deref(), Some("kube-system"));
        assert!(!requirements.resources.contains_key("quota"), "the two maps stay separate");
    }

    #[test]
    fn a_nameless_requirement_matches_labels() {
        let items = vec![meta(
            "RequiredResources",
            json!({"ents": {"apiVersion": "platform.example.org/v1alpha1", "kind": "Entitlement", "matchLabels": {"team": "a"}}}),
        )];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        let requirements = apply(&items, Target::Default, &xr(), &mut desired).unwrap();

        let labels = BTreeMap::from([("team".to_string(), "a".to_string())]);
        assert_eq!(requirements.resources["ents"].r#match, SelectorMatch::Labels(labels));
    }

    #[test]
    fn a_duplicate_requirement_key_is_an_error() {
        let one = json!({"apiVersion": "v1", "kind": "ConfigMap", "name": "a"});
        let items = vec![
            meta("RequiredResources", json!({"cfg": one})),
            meta("RequiredResources", json!({"cfg": {"apiVersion": "v1", "kind": "Secret", "name": "b"}})),
        ];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        let err = apply(&items, Target::Default, &xr(), &mut desired).unwrap_err().to_string();
        assert!(err.contains("duplicate required resource key \"cfg\""), "unexpected error: {err}");
    }

    #[test]
    fn an_unknown_meta_kind_is_rejected_by_name() {
        let items = vec![json!({"apiVersion": META_API_VERSION, "kind": "Conditions", "conditions": []})];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        let err = apply(&items, Target::Default, &xr(), &mut desired).unwrap_err().to_string();
        assert!(err.contains("Conditions") && err.contains("RequiredResources"), "unexpected error: {err}");
    }

    #[test]
    fn a_mistyped_requirement_field_is_rejected() {
        let items = vec![meta("RequiredResources", json!({"ents": {"apiVersion": "v1", "kind": "ConfigMap", "nmae": "a"}}))];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        assert!(apply(&items, Target::Default, &xr(), &mut desired).is_err());
    }

    #[test]
    fn only_the_default_target_reads_meta_items() {
        let items = vec![json!({
            "apiVersion": META_API_VERSION, "kind": "RequiredResources",
            "metadata": {"name": "meta"},
            "requirements": {"ents": {"apiVersion": "v1", "kind": "ConfigMap", "name": "a"}}
        })];
        let mut desired = Desired { composite: xr(), resources: vec![] };
        let requirements = apply(&items, Target::Resources, &xr(), &mut desired).unwrap();

        assert!(requirements.is_empty(), "function-kcl only dispatches meta items under Default");
        assert_eq!(desired.resources[0].name, "meta");
    }
}
