//! What the CLI and the HTTP API both do: read and write `KclModule`
//! objects, and render one without touching the cluster.
//!
//! The controller does not go through this layer for the reconcile itself —
//! it owns the apply — but it renders through the same [`render`] function,
//! so a preview and the reconcile that follows it cannot disagree.

use std::sync::Arc;

use kcl_render::{Engine, Rendered, Request, Source};
use kube::api::{Api, DeleteParams, ListParams, Patch, PatchParams};
use kube::Client;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::apply::Applier;
use crate::crd::{KclModule, KclModuleSpec, ResourceRef};
use crate::error::{Error, not_found};
use crate::plan;

/// A render that was not applied: exactly the objects a reconcile would send,
/// and the inventory it would record.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preview {
    pub items: Vec<Value>,
    pub inventory: Vec<ResourceRef>,
    pub digest: String,
    /// KCL `print()` output.
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub log: String,
}

pub struct Service {
    client: Client,
    engine: Arc<Engine>,
    applier: Applier,
    field_manager: String,
}

impl Service {
    pub fn new(client: Client, engine: Arc<Engine>, field_manager: impl Into<String>) -> Self {
        let field_manager = field_manager.into();
        Self {
            applier: Applier::new(client.clone(), field_manager.clone()),
            client,
            engine,
            field_manager,
        }
    }

    pub async fn list(&self, namespace: Option<&str>) -> Result<Vec<KclModule>, Error> {
        Ok(self
            .api(namespace)
            .list(&ListParams::default())
            .await?
            .items)
    }

    pub async fn get(&self, namespace: &str, name: &str) -> Result<KclModule, Error> {
        self.api(Some(namespace))
            .get(name)
            .await
            .map_err(|e| not_found("KclModule", name, e))
    }

    /// Server-side apply, so `kclx module apply -f` and `PUT /v1/modules/…`
    /// create and update with one call and one conflict model.
    pub async fn apply(&self, module: &KclModule) -> Result<KclModule, Error> {
        let name = module
            .metadata
            .name
            .clone()
            .ok_or_else(|| Error::Invalid("KclModule has no metadata.name".into()))?;
        let namespace = module
            .metadata
            .namespace
            .clone()
            .ok_or_else(|| Error::Invalid(format!("KclModule {name} has no metadata.namespace")))?;
        Ok(self
            .api(Some(&namespace))
            .patch(
                &name,
                &PatchParams::apply(&self.field_manager).force(),
                &Patch::Apply(module),
            )
            .await?)
    }

    /// Deleting the module deletes what it applied: the controller's
    /// finalizer runs first, so this returns while the inventory is still
    /// being torn down.
    pub async fn delete(&self, namespace: &str, name: &str) -> Result<(), Error> {
        self.api(Some(namespace))
            .delete(name, &DeleteParams::default())
            .await
            .map_err(|e| not_found("KclModule", name, e))?;
        Ok(())
    }

    /// Render and resolve without writing anything. Kind discovery still
    /// happens — that is what makes the previewed inventory the same one the
    /// controller would record, namespaces and cluster scope included.
    pub async fn preview(
        &self,
        spec: &KclModuleSpec,
        namespace: &str,
        module_label: &str,
    ) -> Result<Preview, Error> {
        let rendered = render(self.engine.clone(), spec.clone()).await?;
        let planned = plan::plan(&rendered.items, module_label)?;
        let targets = self.applier.resolve(planned, namespace).await?;
        Ok(Preview {
            digest: plan::digest(&rendered.items),
            inventory: targets.into_iter().map(|t| t.reference).collect(),
            items: rendered.items,
            log: rendered.log,
        })
    }

    /// Cheap liveness proof for `/readyz`: the API server answered.
    pub async fn apiserver_version(&self) -> Result<String, Error> {
        Ok(self.client.apiserver_version().await?.git_version)
    }

    fn api(&self, namespace: Option<&str>) -> Api<KclModule> {
        match namespace {
            Some(namespace) => Api::namespaced(self.client.clone(), namespace),
            None => Api::all(self.client.clone()),
        }
    }
}

/// The one place a `KclModuleSpec` becomes a render request.
pub fn request(spec: &KclModuleSpec) -> Result<Request, Error> {
    let params: Map<String, Value> = match &spec.params {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(map)) => map.clone(),
        Some(other) => {
            return Err(Error::Invalid(format!(
                "spec.params must be an object, got {}",
                kind_of(other)
            )));
        }
    };

    let mut request = Request::new(Source::parse(&spec.source));
    request.params = params;
    request.options.arguments = spec.options.arguments.clone();
    request.options.disable_none = spec.options.disable_none;
    request.options.sort_keys = spec.options.sort_keys;
    Ok(request)
}

/// KCL execution is synchronous and serialised inside the engine; running it
/// on the reactor would stall every watch in the process for the duration of
/// the render.
pub async fn render(engine: Arc<Engine>, spec: KclModuleSpec) -> Result<Rendered, Error> {
    tokio::task::spawn_blocking(move || {
        let request = request(&spec)?;
        engine.render(&request).map_err(Error::Render)
    })
    .await?
}

fn kind_of(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crd::RenderOptions;
    use serde_json::json;

    fn spec(params: Option<Value>) -> KclModuleSpec {
        KclModuleSpec {
            source: "items = []".into(),
            params,
            options: RenderOptions {
                arguments: vec!["env=dev".into()],
                disable_none: true,
                sort_keys: false,
            },
            interval: "5m".into(),
            target_namespace: None,
            prune: true,
            suspend: false,
        }
    }

    #[test]
    fn params_reach_the_render_request_and_options_map_onto_kcl_flags() {
        let request = request(&spec(Some(json!({"replicas": 2})))).unwrap();
        assert_eq!(request.params["replicas"], json!(2));
        assert_eq!(request.options.arguments, vec!["env=dev".to_string()]);
        assert!(request.options.disable_none);
        assert_eq!(request.source, Source::Inline("items = []".into()));
    }

    #[test]
    fn absent_params_render_as_an_empty_object_not_a_failure() {
        assert!(request(&spec(None)).unwrap().params.is_empty());
        assert!(request(&spec(Some(Value::Null))).unwrap().params.is_empty());
    }

    #[test]
    fn a_non_object_params_is_rejected_before_the_render() {
        let err = request(&spec(Some(json!([1, 2])))).unwrap_err();
        assert!(err.to_string().contains("must be an object"), "{err}");
    }

    #[test]
    fn an_oci_source_is_parsed_the_same_way_the_cli_parses_it() {
        let mut spec = spec(None);
        spec.source = "oci://docker.io/yurikrupnik/app?tag=0.1.4".into();
        assert_eq!(
            request(&spec).unwrap().source,
            Source::Oci {
                url: "oci://docker.io/yurikrupnik/app".into(),
                tag: Some("0.1.4".into()),
            }
        );
    }
}
