//! Turning rendered `items` into objects that can be applied — all of it
//! pure, so the rules that decide what the cluster gets are testable without
//! a cluster.

use kube::api::{GroupVersionKind, TypeMeta};
use kube::core::DynamicObject;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::crd::{MANAGED_BY, MANAGED_BY_LABEL, MODULE_LABEL, ResourceRef};
use crate::error::Error;

/// A rendered item that has passed the checks an apply depends on.
#[derive(Clone, Debug, PartialEq)]
pub struct Planned {
    pub gvk: GroupVersionKind,
    pub object: DynamicObject,
}

/// Validate every item and stamp the ownership labels on it.
///
/// `module` is `<namespace>.<name>` of the owning `KclModule`; it goes on
/// every object so the fleet a module owns is greppable with `kubectl get -l`
/// even after the module's status has been lost.
pub fn plan(items: &[Value], module: &str) -> Result<Vec<Planned>, Error> {
    let mut planned: Vec<Planned> = Vec::with_capacity(items.len());

    for (index, item) in items.iter().enumerate() {
        let at = |what: &str| Error::Invalid(format!("item {index}: {what}"));

        let map = item
            .as_object()
            .ok_or_else(|| at("is not a Kubernetes object"))?;
        let api_version = map
            .get("apiVersion")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| at("has no apiVersion"))?;
        let kind = map
            .get("kind")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| at("has no kind"))?;
        let name = map
            .get("metadata")
            .and_then(|m| m.get("name"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                at("has no metadata.name; generateName cannot be reconciled, because the \
                    inventory needs a stable identity to re-apply and prune by")
            })?;

        let gvk = gvk_of(api_version, kind)
            .map_err(|e| Error::Invalid(format!("item {index} ({kind} {name}): {e}")))?;

        let mut object: DynamicObject = serde_json::from_value(item.clone())
            .map_err(|e| Error::Invalid(format!("item {index} ({kind} {name}): {e}")))?;
        let labels = object.metadata.labels.get_or_insert_with(Default::default);
        labels.insert(MANAGED_BY_LABEL.to_string(), MANAGED_BY.to_string());
        labels.insert(MODULE_LABEL.to_string(), module.to_string());

        if let Some(clash) = planned.iter().find(|p| {
            p.gvk == gvk
                && p.object.metadata.name == object.metadata.name
                && p.object.metadata.namespace == object.metadata.namespace
        }) {
            let ns = clash.object.metadata.namespace.as_deref().unwrap_or("-");
            return Err(Error::Invalid(format!(
                "item {index}: {kind} {ns}/{name} is rendered twice; the second apply would \
                 silently overwrite the first"
            )));
        }

        planned.push(Planned { gvk, object });
    }

    Ok(planned)
}

/// `apiVersion` is `group/version`, or just `version` for the core group.
pub fn gvk_of(api_version: &str, kind: &str) -> Result<GroupVersionKind, String> {
    match api_version.split_once('/') {
        Some((group, version)) if !group.is_empty() && !version.is_empty() => {
            Ok(GroupVersionKind::gvk(group, version, kind))
        }
        Some(_) => Err(format!("apiVersion {api_version:?} is malformed")),
        None => Ok(GroupVersionKind::gvk("", api_version, kind)),
    }
}

/// Give a namespaced object the module's namespace when it names none, and
/// take the namespace away from a cluster-scoped one — the API server rejects
/// a namespaced request for a cluster-scoped kind, and a KCL package that is
/// used both standalone and here may well set it.
pub fn scope(object: &mut DynamicObject, namespaced: bool, default_namespace: &str) {
    if namespaced {
        if object
            .metadata
            .namespace
            .as_deref()
            .is_none_or(str::is_empty)
        {
            object.metadata.namespace = Some(default_namespace.to_string());
        }
    } else {
        object.metadata.namespace = None;
    }
}

/// How the object is recorded in `status.inventory`. Call after [`scope`].
pub fn reference(object: &DynamicObject) -> ResourceRef {
    let types = object.types.clone().unwrap_or_else(|| TypeMeta {
        api_version: String::new(),
        kind: String::new(),
    });
    ResourceRef {
        api_version: types.api_version,
        kind: types.kind,
        namespace: object.metadata.namespace.clone(),
        name: object.metadata.name.clone().unwrap_or_default(),
    }
}

/// Objects the previous render owned and this one does not.
pub fn stale(previous: &[ResourceRef], current: &[ResourceRef]) -> Vec<ResourceRef> {
    previous
        .iter()
        .filter(|old| !current.contains(old))
        .cloned()
        .collect()
}

/// Content hash of a render. Only used to report "this is the same render as
/// last time" — the apply itself is unconditional, because the cluster can
/// drift while the render does not.
pub fn digest(items: &[Value]) -> String {
    let mut hasher = Sha256::new();
    for item in items {
        hasher.update(serde_json::to_vec(item).unwrap_or_default());
        hasher.update([0]);
    }
    format!("sha256:{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cm(name: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": name},
            "data": {"a": "1"},
        })
    }

    #[test]
    fn every_object_is_labelled_with_its_module() {
        let planned = plan(&[cm("one")], "apps.demo").unwrap();
        let labels = planned[0].object.metadata.labels.clone().unwrap();
        assert_eq!(labels[MANAGED_BY_LABEL], "kclx");
        assert_eq!(labels[MODULE_LABEL], "apps.demo");
        assert_eq!(planned[0].gvk, GroupVersionKind::gvk("", "v1", "ConfigMap"));
        // The payload survives planning.
        assert_eq!(planned[0].object.data["data"]["a"], json!("1"));
    }

    #[test]
    fn a_grouped_api_version_splits_into_group_and_version() {
        let planned = plan(
            &[json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {"name": "web"},
            })],
            "apps.demo",
        )
        .unwrap();
        assert_eq!(
            planned[0].gvk,
            GroupVersionKind::gvk("apps", "v1", "Deployment")
        );
    }

    #[test]
    fn an_item_without_a_name_is_rejected_rather_than_applied() {
        let err = plan(
            &[json!({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {}})],
            "apps.demo",
        )
        .unwrap_err();
        assert!(err.to_string().contains("metadata.name"), "{err}");
    }

    #[test]
    fn an_item_without_a_kind_is_rejected() {
        let err = plan(&[json!({"apiVersion": "v1", "metadata": {"name": "x"}})], "m").unwrap_err();
        assert!(err.to_string().contains("kind"), "{err}");
    }

    #[test]
    fn rendering_the_same_object_twice_is_an_error_not_a_silent_overwrite() {
        let err = plan(&[cm("dup"), cm("dup")], "apps.demo").unwrap_err();
        assert!(err.to_string().contains("rendered twice"), "{err}");
    }

    #[test]
    fn two_objects_of_the_same_kind_with_different_names_are_fine() {
        assert_eq!(plan(&[cm("one"), cm("two")], "m").unwrap().len(), 2);
    }

    #[test]
    fn namespaced_objects_are_defaulted_and_cluster_scoped_ones_stripped() {
        let mut object: DynamicObject = serde_json::from_value(cm("one")).unwrap();
        scope(&mut object, true, "apps");
        assert_eq!(object.metadata.namespace.as_deref(), Some("apps"));
        assert_eq!(reference(&object).namespace.as_deref(), Some("apps"));

        let mut explicit: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": "one", "namespace": "other"},
        }))
        .unwrap();
        scope(&mut explicit, true, "apps");
        assert_eq!(explicit.metadata.namespace.as_deref(), Some("other"));

        let mut cluster_scoped: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1", "kind": "Namespace",
            "metadata": {"name": "team", "namespace": "apps"},
        }))
        .unwrap();
        scope(&mut cluster_scoped, false, "apps");
        assert_eq!(cluster_scoped.metadata.namespace, None);
        assert_eq!(reference(&cluster_scoped).namespace, None);
    }

    #[test]
    fn pruning_keeps_what_the_new_render_still_owns() {
        let one = ResourceRef {
            api_version: "v1".into(),
            kind: "ConfigMap".into(),
            namespace: Some("apps".into()),
            name: "one".into(),
        };
        let two = ResourceRef {
            name: "two".into(),
            ..one.clone()
        };
        let elsewhere = ResourceRef {
            namespace: Some("other".into()),
            ..one.clone()
        };

        assert_eq!(
            stale(&[one.clone(), two.clone()], std::slice::from_ref(&one)),
            vec![two]
        );
        assert!(stale(std::slice::from_ref(&one), std::slice::from_ref(&one)).is_empty());
        // Same name, different namespace: not the same object.
        assert_eq!(
            stale(std::slice::from_ref(&elsewhere), &[one]),
            vec![elsewhere]
        );
    }

    #[test]
    fn the_digest_tracks_content_not_order_of_serialisation() {
        let a = digest(&[cm("one"), cm("two")]);
        assert_eq!(a, digest(&[cm("one"), cm("two")]));
        assert_ne!(a, digest(&[cm("two"), cm("one")]));
        assert_ne!(a, digest(&[cm("one")]));
    }
}
