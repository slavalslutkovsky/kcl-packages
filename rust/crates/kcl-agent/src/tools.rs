//! The only way the agent reaches the cluster.
//!
//! Ten tools, split by whether the caller approved the run: eight that read or
//! dry-run are always offered, and `apply_resource`/`delete_resource` are
//! added only under approval. The gate is enforced twice — the write specs are
//! not advertised, and [`Toolbox::call`] refuses them anyway, because a model
//! will happily invent a tool it was not given.
//!
//! Everything here delegates: kinds resolve through [`kube::discovery`] the
//! way [`kcl_operator::apply`] does, objects are identified and scoped with
//! [`kcl_operator::plan`], and a `KclModule` is rendered and written through
//! [`kcl_operator::Service`] — the same code path as `kclx module` and
//! `PUT /v1/modules/…`, so the agent cannot apply something the operator
//! would not.

use std::sync::Arc;

use k8s_openapi::api::core::v1::Event;
use k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::CustomResourceDefinition;
use kcl_operator::crd::{KclModule, KclModuleSpec, RenderOptions};
use kcl_operator::error::not_found;
use kcl_operator::{Error as ClusterError, ResourceRef, Service, plan};
use kube::Client;
use kube::api::{Api, ApiResource, DeleteParams, DynamicObject, ListParams, Patch, PatchParams};
use kube::discovery::{Discovery, Scope, pinned_kind};
use serde_json::{Map, Value, json};

use crate::error::Error;
use crate::llm::ToolSpec;

/// The groups this agent is responsible for. Composed managed resources live
/// in provider groups (`s3.aws.upbound.io`, …) and are reachable by name
/// through `composed_resources` and `get_resource`, but they are not listed
/// as things to manage.
pub const GROUPS: [&str; 3] = [
    "kclx.example.org",
    "cloud.example.org",
    "platform.example.org",
];

/// Field manager for everything the agent writes, so `kubectl get -o yaml`
/// shows who did it.
pub const FIELD_MANAGER: &str = "kclx-agent";

/// A tool result past this is cut: a full namespace listing can dwarf the
/// context window, and a truncated answer with a hint beats a failed run.
pub const TOOL_RESULT_LIMIT: usize = 48 * 1024;

/// Read and dry-run tools, in the order they are offered to the model.
pub const READ_TOOLS: [&str; 8] = [
    "list_kinds",
    "describe_kind",
    "list_resources",
    "get_resource",
    "composed_resources",
    "events",
    "preview_module",
    "validate_resource",
];

/// Tools that change the cluster. Offered only under approval.
pub const WRITE_TOOLS: [&str; 2] = ["apply_resource", "delete_resource"];

pub struct Toolbox {
    client: Client,
    service: Arc<Service>,
}

impl Toolbox {
    pub fn new(client: Client, service: Arc<Service>) -> Self {
        Self { client, service }
    }

    pub fn service(&self) -> &Service {
        &self.service
    }

    /// What the model is allowed to see. `approve` adds the two write tools.
    pub fn specs(approve: bool) -> Vec<ToolSpec> {
        let object_property = json!({
            "type": "object",
            "description": "A complete Kubernetes object with apiVersion, kind, metadata.name and spec.",
        });
        let mut specs = vec![
            ToolSpec::new(
                "list_kinds",
                "List every kind this agent manages: KclModule plus the Crossplane composite \
                 kinds served by cloud.example.org and platform.example.org. Call this before \
                 naming a kind you have not already seen.",
                json!({"type": "object", "properties": {}, "additionalProperties": false}),
            ),
            ToolSpec::new(
                "describe_kind",
                "Read the CRD schema of one kind: its spec fields, status fields and printer \
                 columns. Call this before authoring or editing an object; every field you write \
                 must appear here.",
                schema(
                    json!({
                        "apiVersion": {"type": "string", "description": "e.g. cloud.example.org/v1alpha1"},
                        "kind": {"type": "string"},
                    }),
                    &["apiVersion", "kind"],
                ),
            ),
            ToolSpec::new(
                "list_resources",
                "List objects of one kind with their Ready/Synced conditions. Omit namespace to \
                 search every namespace.",
                schema(
                    json!({
                        "apiVersion": {"type": "string"},
                        "kind": {"type": "string"},
                        "namespace": {"type": "string"},
                        "limit": {"type": "integer", "description": "Default 50, maximum 200."},
                    }),
                    &["apiVersion", "kind"],
                ),
            ),
            ToolSpec::new(
                "get_resource",
                "Read one object in full.",
                schema(
                    json!({
                        "apiVersion": {"type": "string"},
                        "kind": {"type": "string"},
                        "name": {"type": "string"},
                        "namespace": {"type": "string"},
                    }),
                    &["apiVersion", "kind", "name"],
                ),
            ),
            ToolSpec::new(
                "composed_resources",
                "For a Crossplane composite: every resource it composed, with each one's Synced \
                 and Ready conditions. This is the first call when a composite is not Ready.",
                schema(
                    json!({
                        "apiVersion": {"type": "string"},
                        "kind": {"type": "string"},
                        "name": {"type": "string"},
                        "namespace": {"type": "string"},
                    }),
                    &["apiVersion", "kind", "name", "namespace"],
                ),
            ),
            ToolSpec::new(
                "events",
                "Recent events for one object, newest first.",
                schema(
                    json!({
                        "namespace": {"type": "string"},
                        "name": {"type": "string", "description": "involvedObject.name"},
                    }),
                    &["namespace", "name"],
                ),
            ),
            ToolSpec::new(
                "preview_module",
                "Render the KCL source of a KclModule without applying it, returning the objects \
                 it would produce. The required dry run before proposing or applying a \
                 KclModule, and useful for nothing else: to check any other kind — a Crossplane \
                 composite included — call validate_resource instead.",
                schema(
                    json!({
                        "source": {"type": "string", "description": "Inline KCL, a path in the image, or oci://host/repo?tag=x.y.z"},
                        "params": {"type": "object", "description": "Becomes option(\"params\")."},
                        "namespace": {"type": "string"},
                        "targetNamespace": {"type": "string"},
                    }),
                    &["source"],
                ),
            ),
            ToolSpec::new(
                "validate_resource",
                "Server-side apply an object in dry-run mode: the API server validates it against \
                 the CRD schema and writes nothing. The required dry run for every kind except \
                 KclModule, Crossplane composites included. Takes a whole object, not KCL.",
                schema(json!({"object": object_property}), &["object"]),
            ),
        ];
        if approve {
            specs.push(ToolSpec::new(
                "apply_resource",
                "Create or update an object with a server-side apply. Only call this after the \
                 matching dry run succeeded.",
                schema(json!({"object": object_property}), &["object"]),
            ));
            specs.push(ToolSpec::new(
                "delete_resource",
                "Delete one object. Never call this for an object the task did not name.",
                schema(
                    json!({
                        "apiVersion": {"type": "string"},
                        "kind": {"type": "string"},
                        "name": {"type": "string"},
                        "namespace": {"type": "string"},
                    }),
                    &["apiVersion", "kind", "name"],
                ),
            ));
        }
        specs
    }

    /// Run one tool call. An `Err` that [`Error::is_tool_level`] is the
    /// model's problem and is handed back to it; nothing else is returned
    /// from here.
    pub async fn call(
        &self,
        approve: bool,
        name: &str,
        arguments: &Value,
        default_namespace: &str,
    ) -> Result<Value, Error> {
        if !approve && WRITE_TOOLS.contains(&name) {
            return Err(Error::Invalid(format!(
                "{name} is not available: this run was not approved, so propose the change \
                 instead (the caller can re-run with --yes / approve=true)"
            )));
        }
        match name {
            "list_kinds" => self.list_kinds().await,
            "describe_kind" => {
                self.describe_kind(&arg_str(name, arguments, "apiVersion")?, &arg_str(name, arguments, "kind")?)
                    .await
            }
            "list_resources" => {
                self.list_resources(
                    &arg_str(name, arguments, "apiVersion")?,
                    &arg_str(name, arguments, "kind")?,
                    arg_opt_str(arguments, "namespace").as_deref(),
                    arg_limit(arguments),
                )
                .await
            }
            "get_resource" => {
                self.get_resource(
                    &arg_str(name, arguments, "apiVersion")?,
                    &arg_str(name, arguments, "kind")?,
                    &arg_str(name, arguments, "name")?,
                    arg_opt_str(arguments, "namespace").as_deref(),
                )
                .await
            }
            "composed_resources" => {
                self.composed_resources(
                    &arg_str(name, arguments, "apiVersion")?,
                    &arg_str(name, arguments, "kind")?,
                    &arg_str(name, arguments, "name")?,
                    &arg_str(name, arguments, "namespace")?,
                )
                .await
            }
            "events" => {
                self.events(
                    &arg_str(name, arguments, "namespace")?,
                    &arg_str(name, arguments, "name")?,
                )
                .await
            }
            "preview_module" => {
                self.preview_module(
                    &arg_str(name, arguments, "source")?,
                    arguments.get("params").filter(|v| !v.is_null()).cloned(),
                    arg_opt_str(arguments, "namespace")
                        .unwrap_or_else(|| default_namespace.to_string()),
                    arg_opt_str(arguments, "targetNamespace"),
                )
                .await
            }
            "validate_resource" => {
                self.write_object(arg_object(name, arguments)?, default_namespace, true)
                    .await
            }
            "apply_resource" => {
                self.write_object(arg_object(name, arguments)?, default_namespace, false)
                    .await
            }
            "delete_resource" => {
                self.delete_resource(
                    &arg_str(name, arguments, "apiVersion")?,
                    &arg_str(name, arguments, "kind")?,
                    &arg_str(name, arguments, "name")?,
                    arg_opt_str(arguments, "namespace")
                        .unwrap_or_else(|| default_namespace.to_string()),
                )
                .await
            }
            other => Err(Error::Invalid(format!("no tool named {other}"))),
        }
    }

    async fn list_kinds(&self) -> Result<Value, Error> {
        let discovery = Discovery::new(self.client.clone())
            .filter(&GROUPS)
            .run()
            .await?;
        let mut kinds: Vec<Value> = Vec::new();
        for group in discovery.groups() {
            for (resource, capabilities) in group.recommended_resources() {
                kinds.push(json!({
                    "apiVersion": resource.api_version,
                    "kind": resource.kind,
                    "plural": resource.plural,
                    "namespaced": capabilities.scope == Scope::Namespaced,
                }));
            }
        }
        kinds.sort_by(|a, b| {
            (a["apiVersion"].as_str(), a["kind"].as_str())
                .cmp(&(b["apiVersion"].as_str(), b["kind"].as_str()))
        });
        Ok(json!({"count": kinds.len(), "kinds": kinds}))
    }

    async fn describe_kind(&self, api_version: &str, kind: &str) -> Result<Value, Error> {
        let (resource, namespaced) = self.resolve(api_version, kind).await?;
        if resource.group.is_empty() {
            return Err(Error::Invalid(format!(
                "{api_version}/{kind} is a built-in kind with no CRD; this agent describes \
                 custom kinds only"
            )));
        }
        let crd_name = format!("{}.{}", resource.plural, resource.group);
        let crd = Api::<CustomResourceDefinition>::all(self.client.clone())
            .get(&crd_name)
            .await
            .map_err(|e| not_found("CustomResourceDefinition", crd_name.clone(), e))
            .map_err(Error::Cluster)?;
        let version = crd
            .spec
            .versions
            .iter()
            .find(|v| v.name == resource.version)
            .ok_or_else(|| {
                Error::Invalid(format!("{crd_name} does not serve version {}", resource.version))
            })?;
        let properties = version
            .schema
            .as_ref()
            .and_then(|s| s.open_api_v3_schema.as_ref())
            .and_then(|s| s.properties.as_ref());
        let of = |field: &str| -> Value {
            properties
                .and_then(|p| p.get(field))
                .and_then(|schema| serde_json::to_value(schema).ok())
                .unwrap_or(Value::Null)
        };
        Ok(json!({
            "apiVersion": resource.api_version,
            "kind": resource.kind,
            "namespaced": namespaced,
            "spec": of("spec"),
            "status": of("status"),
            "printerColumns": serde_json::to_value(&version.additional_printer_columns)?,
        }))
    }

    async fn list_resources(
        &self,
        api_version: &str,
        kind: &str,
        namespace: Option<&str>,
        limit: u32,
    ) -> Result<Value, Error> {
        guard_kind(api_version, kind)?;
        let (resource, namespaced) = self.resolve(api_version, kind).await?;
        let api = self.api(&resource, namespaced, namespace);
        let list = api.list(&ListParams::default().limit(limit)).await?;
        let items: Vec<Value> = list.items.iter().map(summary).collect();
        Ok(json!({
            "count": items.len(),
            // The continue token is deliberately dropped: a model that hits
            // the limit should narrow by namespace, not paginate.
            "truncated": items.len() as u32 == limit,
            "items": items,
        }))
    }

    async fn get_resource(
        &self,
        api_version: &str,
        kind: &str,
        name: &str,
        namespace: Option<&str>,
    ) -> Result<Value, Error> {
        guard_kind(api_version, kind)?;
        let (resource, namespaced) = self.resolve(api_version, kind).await?;
        if namespaced && namespace.is_none() {
            return Err(Error::Invalid(format!(
                "{kind} is namespaced; pass namespace"
            )));
        }
        let object = self
            .api(&resource, namespaced, namespace)
            .get(name)
            .await
            .map_err(|e| not_found("object", format!("{kind} {name}"), e))?;
        trim(&object)
    }

    async fn composed_resources(
        &self,
        api_version: &str,
        kind: &str,
        name: &str,
        namespace: &str,
    ) -> Result<Value, Error> {
        guard_kind(api_version, kind)?;
        let (resource, namespaced) = self.resolve(api_version, kind).await?;
        let composite = self
            .api(&resource, namespaced, Some(namespace))
            .get(name)
            .await
            .map_err(|e| not_found("object", format!("{kind} {namespace}/{name}"), e))?;

        let spec = composite.data.get("spec");
        // Crossplane v2 moved the composite's own machinery under
        // `spec.crossplane`; v1 kept it at the top of the spec.
        let refs = spec
            .and_then(|s| s.get("crossplane"))
            .and_then(|c| c.get("resourceRefs"))
            .or_else(|| spec.and_then(|s| s.get("resourceRefs")))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        let mut items = Vec::with_capacity(refs.len());
        for reference in &refs {
            let (Some(ref_api_version), Some(ref_kind), Some(ref_name)) = (
                reference.get("apiVersion").and_then(Value::as_str),
                reference.get("kind").and_then(Value::as_str),
                reference.get("name").and_then(Value::as_str),
            ) else {
                items.push(json!({"ref": reference, "error": {"reason": "InvalidArguments", "error": "the reference names no kind or name"}}));
                continue;
            };
            let ref_namespace = reference
                .get("namespace")
                .and_then(Value::as_str)
                .unwrap_or(namespace);
            let mut entry = json!({
                "apiVersion": ref_api_version,
                "kind": ref_kind,
                "name": ref_name,
                "namespace": ref_namespace,
            });
            match self
                .get_resource(ref_api_version, ref_kind, ref_name, Some(ref_namespace))
                .await
            {
                Ok(object) => {
                    let status = object.get("status");
                    entry["conditions"] = status
                        .and_then(|s| s.get("conditions"))
                        .cloned()
                        .unwrap_or_else(|| json!([]));
                    entry["atProvider"] = status
                        .and_then(|s| s.get("atProvider"))
                        .cloned()
                        .unwrap_or(Value::Null);
                }
                // One unreadable composed resource is itself the diagnosis;
                // it must not abort the triage of the others.
                Err(error) => entry["error"] = describe_error(&error),
            }
            items.push(entry);
        }
        Ok(json!({"resourceRefs": refs.len(), "items": items}))
    }

    async fn events(&self, namespace: &str, name: &str) -> Result<Value, Error> {
        let api = Api::<Event>::namespaced(self.client.clone(), namespace);
        let params = ListParams::default().fields(&format!("involvedObject.name={name}"));
        let mut events: Vec<Value> = api
            .list(&params)
            .await?
            .items
            .into_iter()
            .map(|event| {
                json!({
                    "type": event.type_,
                    "reason": event.reason,
                    "message": event.message,
                    "count": event.count,
                    // jiff's Timestamp displays as RFC 3339, which is what
                    // sorts correctly as a string.
                    "lastTimestamp": event.last_timestamp.map(|t| t.0.to_string()),
                })
            })
            .collect();
        events.sort_by(|a, b| b["lastTimestamp"].as_str().cmp(&a["lastTimestamp"].as_str()));
        events.truncate(30);
        Ok(json!({"count": events.len(), "events": events}))
    }

    async fn preview_module(
        &self,
        source: &str,
        params: Option<Value>,
        namespace: String,
        target_namespace: Option<String>,
    ) -> Result<Value, Error> {
        let spec = KclModuleSpec {
            source: source.to_string(),
            params,
            options: RenderOptions::default(),
            interval: "5m".to_string(),
            target_namespace: target_namespace.clone(),
            prune: true,
            suspend: false,
        };
        let namespace = target_namespace.unwrap_or(namespace);
        let preview = self
            .service
            .preview(&spec, &namespace, "agent-preview")
            .await?;
        Ok(serde_json::to_value(preview)?)
    }

    /// `validate_resource` and `apply_resource` differ by one flag: the same
    /// request, the same field manager, `dryRun=All` or not.
    async fn write_object(
        &self,
        object: Value,
        default_namespace: &str,
        dry_run: bool,
    ) -> Result<Value, Error> {
        let (api_version, kind, _) = identify(&object)?;
        guard_kind(&api_version, &kind)?;
        let (resource, namespaced) = self.resolve(&api_version, &kind).await?;

        let mut planned: DynamicObject = serde_json::from_value(object.clone())
            .map_err(|e| Error::Invalid(format!("{kind}: {e}")))?;
        plan::scope(&mut planned, namespaced, default_namespace);
        let reference = plan::reference(&planned);

        // A KclModule goes through the service layer, so the agent's writes
        // and `kclx module apply -f` are one code path.
        if !dry_run && is_kcl_module(&resource) {
            let module: KclModule = serde_json::from_value(serde_json::to_value(&planned)?)
                .map_err(|e| Error::Invalid(format!("KclModule: {e}")))?;
            self.service.apply(&module).await?;
            return Ok(serde_json::to_value(&reference)?);
        }

        let mut params = PatchParams::apply(FIELD_MANAGER).force();
        params.dry_run = dry_run;
        let applied = self
            .api(&resource, namespaced, planned.metadata.namespace.as_deref())
            .patch(&reference.name, &params, &Patch::Apply(&planned))
            .await?;
        if dry_run {
            Ok(json!({"valid": true, "object": trim(&applied)?}))
        } else {
            Ok(serde_json::to_value(&reference)?)
        }
    }

    async fn delete_resource(
        &self,
        api_version: &str,
        kind: &str,
        name: &str,
        namespace: String,
    ) -> Result<Value, Error> {
        guard_kind(api_version, kind)?;
        let (resource, namespaced) = self.resolve(api_version, kind).await?;
        let namespace = namespaced.then_some(namespace);
        if is_kcl_module(&resource) {
            let namespace = namespace.clone().unwrap_or_default();
            self.service.delete(&namespace, name).await?;
        } else {
            self.api(&resource, namespaced, namespace.as_deref())
                .delete(name, &DeleteParams::default())
                .await
                .map_err(|e| {
                    not_found(
                        "object",
                        format!("{kind} {}/{name}", namespace.as_deref().unwrap_or("-")),
                        e,
                    )
                })?;
        }
        Ok(serde_json::to_value(ResourceRef {
            api_version: resource.api_version.clone(),
            kind: resource.kind.clone(),
            namespace,
            name: name.to_string(),
        })?)
    }

    /// The `pinned_kind` lookup [`kcl_operator::apply::Applier`] uses, without
    /// its cache: a run is short and every tool call is already a round trip.
    async fn resolve(&self, api_version: &str, kind: &str) -> Result<(ApiResource, bool), Error> {
        let gvk = plan::gvk_of(api_version, kind).map_err(Error::Invalid)?;
        let (resource, capabilities) = pinned_kind(&self.client, &gvk)
            .await
            .map_err(|error| match error {
                kube::Error::Api(response) if response.code == 404 => {
                    ClusterError::UnknownKind(format!("{}/{}", gvk.api_version(), gvk.kind))
                }
                other => ClusterError::Kube(other),
            })?;
        Ok((resource, capabilities.scope == Scope::Namespaced))
    }

    fn api(
        &self,
        resource: &ApiResource,
        namespaced: bool,
        namespace: Option<&str>,
    ) -> Api<DynamicObject> {
        match (namespaced, namespace) {
            (true, Some(namespace)) => {
                Api::namespaced_with(self.client.clone(), namespace, resource)
            }
            _ => Api::all_with(self.client.clone(), resource),
        }
    }
}

/// What the model is shown for one tool call. Oversized results are cut with
/// a hint rather than dropped, so the run can still finish.
pub fn render_result(value: &Value) -> String {
    let text = value.to_string();
    if text.len() <= TOOL_RESULT_LIMIT {
        return text;
    }
    let mut end = TOOL_RESULT_LIMIT;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!(
        "{}…[truncated: {} bytes; narrow the query with namespace or limit]",
        &text[..end],
        text.len()
    )
}

/// A tool failure as the model sees it: the same `{reason, error}` pair the
/// HTTP API answers with.
pub fn describe_error(error: &Error) -> Value {
    json!({"reason": error.reason(), "error": error.to_string()})
}

/// Secrets never enter a prompt. RBAC should say the same thing, but the
/// refusal belongs in the code that builds the request.
fn guard_kind(api_version: &str, kind: &str) -> Result<(), Error> {
    if api_version == "v1" && kind == "Secret" {
        return Err(Error::Invalid(
            "this agent does not read or write Secrets".into(),
        ));
    }
    Ok(())
}

/// The three fields every object must have before anything else is worth
/// doing. Mirrors the checks in [`kcl_operator::plan::plan`].
fn identify(object: &Value) -> Result<(String, String, String), Error> {
    let map = object
        .as_object()
        .ok_or_else(|| Error::Invalid("object: is not a Kubernetes object".into()))?;
    let field = |name: &str, value: Option<&Value>| -> Result<String, Error> {
        value
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .ok_or_else(|| Error::Invalid(format!("object: has no {name}")))
    };
    let api_version = field("apiVersion", map.get("apiVersion"))?;
    let kind = field("kind", map.get("kind"))?;
    let name = field(
        "metadata.name",
        map.get("metadata").and_then(|m| m.get("name")),
    )?;
    Ok((api_version, kind, name))
}

fn is_kcl_module(resource: &ApiResource) -> bool {
    resource.group == "kclx.example.org" && resource.kind == "KclModule"
}

/// One listed object: enough to triage, far less than the whole spec.
fn summary(object: &DynamicObject) -> Value {
    let status = object.data.get("status");
    let mut rest = status
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);
    let conditions = rest.remove("conditions").unwrap_or_else(|| json!([]));
    json!({
        "name": object.metadata.name,
        "namespace": object.metadata.namespace,
        "labels": object.metadata.labels,
        "conditions": conditions,
        "status": Value::Object(rest),
    })
}

/// `managedFields` is half the bytes of a server-side-applied object and none
/// of the meaning.
fn trim(object: &DynamicObject) -> Result<Value, Error> {
    let mut value = serde_json::to_value(object)?;
    if let Some(metadata) = value.get_mut("metadata").and_then(Value::as_object_mut) {
        metadata.remove("managedFields");
    }
    Ok(value)
}

fn schema(properties: Value, required: &[&str]) -> Value {
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
    })
}

fn arg_str(tool: &str, arguments: &Value, key: &str) -> Result<String, Error> {
    arg_opt_str(arguments, key)
        .ok_or_else(|| Error::Invalid(format!("{tool}: missing string argument {key}")))
}

fn arg_opt_str(arguments: &Value, key: &str) -> Option<String> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn arg_object(tool: &str, arguments: &Value) -> Result<Value, Error> {
    arguments
        .get("object")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| Error::Invalid(format!("{tool}: missing object argument object")))
}

fn arg_limit(arguments: &Value) -> u32 {
    arguments
        .get("limit")
        .and_then(Value::as_u64)
        .filter(|limit| *limit > 0)
        .unwrap_or(50)
        .min(200) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(approve: bool) -> Vec<&'static str> {
        Toolbox::specs(approve)
            .iter()
            .map(ToolSpec::name)
            .collect()
    }

    #[test]
    fn write_tools_are_absent_unless_the_run_was_approved() {
        assert_eq!(names(false), READ_TOOLS.to_vec());
        let approved = names(true);
        assert_eq!(approved[..READ_TOOLS.len()], READ_TOOLS);
        assert_eq!(approved[READ_TOOLS.len()..], WRITE_TOOLS);
    }

    #[test]
    fn every_tool_schema_forbids_arguments_it_did_not_declare() {
        for spec in Toolbox::specs(true) {
            let parameters = &spec.function.parameters;
            assert_eq!(
                parameters["additionalProperties"],
                json!(false),
                "{} accepts unknown arguments",
                spec.name()
            );
            for required in parameters["required"].as_array().into_iter().flatten() {
                let key = required.as_str().unwrap();
                assert!(
                    parameters["properties"].get(key).is_some(),
                    "{} requires {key} but does not declare it",
                    spec.name()
                );
            }
        }
    }

    #[test]
    fn secrets_are_refused_before_any_cluster_call() {
        let error = guard_kind("v1", "Secret").unwrap_err();
        assert_eq!(error.reason(), "InvalidArguments");
        assert!(guard_kind("v1", "ConfigMap").is_ok());
        assert!(guard_kind("cloud.example.org/v1alpha1", "Bucket").is_ok());
    }

    #[test]
    fn a_long_result_is_cut_at_the_limit_and_says_so() {
        let small = json!({"a": 1});
        assert_eq!(render_result(&small), "{\"a\":1}");

        let big = json!("x".repeat(100 * 1024));
        let rendered = render_result(&big);
        assert!(rendered.len() < TOOL_RESULT_LIMIT + 100);
        assert!(rendered.ends_with("bytes; narrow the query with namespace or limit]"));
    }

    #[test]
    fn an_object_without_a_name_is_rejected_before_discovery() {
        let error = identify(&json!({"apiVersion": "v1", "kind": "ConfigMap"})).unwrap_err();
        assert_eq!(error.to_string(), "object: has no metadata.name");
        let error = identify(&json!({"kind": "ConfigMap"})).unwrap_err();
        assert_eq!(error.to_string(), "object: has no apiVersion");
        assert_eq!(
            identify(&json!({
                "apiVersion": "cloud.example.org/v1alpha1",
                "kind": "Bucket",
                "metadata": {"name": "demo"},
            }))
            .unwrap(),
            (
                "cloud.example.org/v1alpha1".to_string(),
                "Bucket".to_string(),
                "demo".to_string()
            )
        );
    }

    #[test]
    fn a_listing_limit_is_bounded_on_both_ends() {
        assert_eq!(arg_limit(&json!({})), 50);
        assert_eq!(arg_limit(&json!({"limit": 0})), 50);
        assert_eq!(arg_limit(&json!({"limit": 5})), 5);
        assert_eq!(arg_limit(&json!({"limit": 10_000})), 200);
    }

    #[test]
    fn a_summary_lifts_conditions_out_of_the_rest_of_the_status() {
        let object: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "Bucket",
            "metadata": {"name": "demo", "namespace": "default"},
            "spec": {"location": "eu"},
            "status": {
                "conditions": [{"type": "Ready", "status": "False"}],
                "ready": false,
            },
        }))
        .unwrap();
        let summary = summary(&object);
        assert_eq!(summary["name"], json!("demo"));
        assert_eq!(summary["conditions"][0]["status"], json!("False"));
        assert_eq!(summary["status"], json!({"ready": false}));
        // The spec is deliberately absent: listings are for triage.
        assert!(summary.get("spec").is_none());
    }
}
