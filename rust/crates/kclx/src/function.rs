//! `kclx function` — the same renderer, served as a Crossplane composition
//! function (`apiextensions.fn.proto.v1.FunctionRunnerService`).
//!
//! The gRPC layer is deliberately thin. It only:
//!   1. decodes the Composition's `input` (a `krm.kcl.dev/v1alpha1, KCLInput`,
//!      so the Compositions in `packages/cloud/**` work unchanged),
//!   2. projects composition state into `option("params")` using
//!      `function-kcl`'s key names (`oxr`, `dxr`, `ocds`, `dcds`, `ctx`),
//!   3. calls [`kcl_render::Engine::render`] — the same call `kclx render`
//!      makes,
//!   4. folds the rendered `items` into desired state with
//!      [`kcl_render::compose`] — the same code `--view desired` prints.
//!
//! Anything KCL-related that is not gRPC belongs in `kcl-render`, so the CLI
//! stays an honest rehearsal of what happens in-cluster.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Result, anyhow};
use function_sdk_rust::proto::v1::function_runner_service_server::FunctionRunnerService;
use function_sdk_rust::proto::v1::{
    MatchLabels, Ready as PbReady, Requirements, Resource, ResourceSelector, Resources,
    RunFunctionRequest, RunFunctionResponse, State, resource_selector,
};
use function_sdk_rust::{request, resource, response};
use kcl_render::{Composed, Desired, Engine, Options, Ready, Request, Source, Target, compose};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tonic::{Status, async_trait};

/// The Composition's `spec.pipeline[].input`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Input {
    #[serde(default)]
    pub kind: String,
    pub spec: InputSpec,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct InputSpec {
    /// Path, inline KCL, or `oci://<repo>[?tag=<version>]`.
    pub source: String,
    /// Extra `option("params")` entries, on top of the composition state.
    pub params: Map<String, Value>,
    /// `kcl run` knobs.
    pub config: Options,
    pub target: Target,
    /// Bases for the `PatchResources` target.
    pub resources: Vec<Base>,
    /// Registry credentials. Pulls are anonymous here, so a Composition that
    /// sets this is rejected rather than silently failing to authenticate.
    pub credentials: Option<Value>,
    /// A `[dependencies]` block function-kcl appends to an inline source's
    /// `kcl.mod`. Rejected for the same reason: silently ignoring it would
    /// surface as a mystery "module not found" from inside the package.
    pub dependencies: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Base {
    pub name: String,
    pub base: Value,
}

pub struct KclFunction {
    engine: Arc<Engine>,
}

impl KclFunction {
    pub fn new(engine: Arc<Engine>) -> Self {
        Self { engine }
    }
}

#[async_trait]
impl FunctionRunnerService for KclFunction {
    async fn run_function(
        &self,
        req: tonic::Request<RunFunctionRequest>,
    ) -> Result<tonic::Response<RunFunctionResponse>, Status> {
        let req = req.into_inner();
        let mut rsp = response::to(&req, response::DEFAULT_TTL);

        // A failed render is a pipeline failure, not a transport failure:
        // Crossplane surfaces a fatal result on the XR's events, while a gRPC
        // error is reported as the function being broken.
        match self.render(&req).await {
            Ok(outcome) => {
                rsp.desired = Some(outcome.state);
                rsp.requirements = outcome.requirements;
                response::normal(&mut rsp, format!("rendered {} resource(s)", outcome.count));
            }
            Err(err) => {
                response::fatal(&mut rsp, format!("{err:#}"));
            }
        }
        Ok(tonic::Response::new(rsp))
    }
}

/// What one render contributes to the response.
struct Outcome {
    state: State,
    /// Rendered items that are objects, for the result message on the XR.
    count: usize,
    /// `None` unless the module asked for resources: Crossplane compares the
    /// whole `Requirements` message across calls to decide whether to run the
    /// step again, so an empty-but-present message must never alternate with
    /// `None`.
    requirements: Option<Requirements>,
}

impl KclFunction {
    async fn render(&self, req: &RunFunctionRequest) -> Result<Outcome> {
        let input: Input = request::get_input(req).map_err(|e| anyhow!("invalid input: {e}"))?;
        if !input.kind.is_empty() && input.kind != "KCLInput" && input.kind != "KCLRun" {
            return Err(anyhow!("unsupported input kind {:?}", input.kind));
        }
        if input.spec.source.trim().is_empty() {
            return Err(anyhow!("spec.source is required"));
        }
        if input.spec.credentials.is_some() {
            return Err(anyhow!(
                "spec.credentials is not supported: package pulls are anonymous"
            ));
        }
        if input.spec.dependencies.is_some() {
            return Err(anyhow!(
                "spec.dependencies is not supported: put the dependencies in the package's own kcl.mod"
            ));
        }

        let observed_xr = composite(req.observed.as_ref());
        let desired_xr = {
            let mut dxr = composite(req.desired.as_ref());
            // Crossplane sends desired state without identity on the first
            // pass; KCL packages read `dxr.metadata.name`.
            if dxr.get("apiVersion").is_none() {
                dxr = merge_identity(&observed_xr, dxr);
            }
            dxr
        };

        let mut params = input.spec.params.clone();
        params.insert("oxr".into(), observed_xr.clone());
        params.insert("dxr".into(), desired_xr.clone());
        params.insert("ocds".into(), observed_composed(req.observed.as_ref()));
        params.insert("dcds".into(), desired_composed(req.desired.as_ref()));
        params.insert("ctx".into(), context(req));
        params.insert("requiredResources".into(), required(&req.required_resources));
        params.insert("extraResources".into(), required(&req.extra_resources));

        let request = Request {
            source: Source::parse(&input.spec.source),
            params,
            function_config: Some(json!({
                "apiVersion": "krm.kcl.dev/v1alpha1",
                "kind": "KCLInput",
                "spec": {"source": input.spec.source, "target": input.spec.target},
            })),
            options: input.spec.config.clone(),
        };

        // exec_program is synchronous and CPU-bound (milliseconds), and the
        // engine serialises renders internally: keep it off the reactor.
        let engine = Arc::clone(&self.engine);
        let rendered = tokio::task::spawn_blocking(move || engine.render(&request))
            .await
            .map_err(|e| anyhow!("render task panicked: {e}"))??;
        if !rendered.log.trim().is_empty() {
            tracing_log(&rendered.log);
        }

        let mut desired = Desired { composite: desired_xr, resources: existing_desired(req) };
        if input.spec.target == Target::PatchResources {
            let bases: Vec<(String, Value)> =
                input.spec.resources.iter().map(|b| (b.name.clone(), b.base.clone())).collect();
            compose::seed_bases(&mut desired, &bases);
        }
        let asked = compose::apply(&rendered.items, input.spec.target, &observed_xr, &mut desired)?;

        // Meta items are instructions to the function, not objects, so they
        // are not part of the tally — and only the default target reads them.
        let count = match input.spec.target {
            Target::Default => rendered.items.iter().filter(|item| !compose::is_meta(item)).count(),
            _ => rendered.items.len(),
        };
        Ok(Outcome { state: state(req, desired)?, count, requirements: requirements(&asked) })
    }
}

/// Rebuild the wire `State`, preserving the connection details Crossplane and
/// earlier pipeline steps put on already-desired resources.
fn state(req: &RunFunctionRequest, desired: Desired) -> Result<State> {
    let previous: HashMap<String, Resource> = req
        .desired
        .as_ref()
        .map(|s| s.resources.clone())
        .unwrap_or_default();

    let mut resources = HashMap::with_capacity(desired.resources.len());
    for Composed { name, ready, resource: value } in desired.resources {
        let mut proto = previous.get(&name).cloned().unwrap_or_default();
        proto.resource = Some(resource::json_to_struct(object(&value)?));
        proto.ready = match ready {
            Ready::Unspecified => proto.ready,
            Ready::True => PbReady::True as i32,
            Ready::False => PbReady::False as i32,
        };
        resources.insert(name, proto);
    }

    let mut composite = req
        .desired
        .as_ref()
        .and_then(|s| s.composite.clone())
        .unwrap_or_default();
    composite.resource = Some(resource::json_to_struct(object(&desired.composite)?));

    Ok(State { composite: Some(composite), resources })
}

fn object(value: &Value) -> Result<&Map<String, Value>> {
    value.as_object().ok_or_else(|| anyhow!("expected a JSON object, got {value}"))
}

fn composite(state: Option<&State>) -> Value {
    state
        .and_then(|s| s.composite.as_ref())
        .and_then(|c| c.resource.as_ref())
        .map(resource::struct_to_json)
        .unwrap_or_else(|| json!({}))
}

fn merge_identity(from: &Value, mut into: Value) -> Value {
    for key in ["apiVersion", "kind"] {
        if let (Some(value), Some(map)) = (from.get(key), into.as_object_mut()) {
            map.insert(key.to_string(), value.clone());
        }
    }
    if let (Some(name), Some(map)) = (from.pointer("/metadata/name"), into.as_object_mut()) {
        let metadata = map.entry("metadata").or_insert_with(|| json!({}));
        if let Some(metadata) = metadata.as_object_mut() {
            metadata.entry("name").or_insert(name.clone());
        }
    }
    into
}

/// `params.ocds`: `{"<name>": {"Resource": {...}, "ConnectionDetails": {"k": "<base64>"}}}`.
/// The capitalised keys are `function-kcl`'s (Go structs without JSON tags);
/// keeping them means KCL packages written against `function-kcl` — every
/// package in this repo — read the same fields here.
fn observed_composed(state: Option<&State>) -> Value {
    let mut out = Map::new();
    for (name, res) in state.map(|s| &s.resources).into_iter().flatten() {
        let details: Map<String, Value> = res
            .connection_details
            .iter()
            .map(|(k, v)| (k.clone(), Value::String(base64(v))))
            .collect();
        out.insert(
            name.clone(),
            json!({
                "Resource": res.resource.as_ref().map(resource::struct_to_json).unwrap_or_else(|| json!({})),
                "ConnectionDetails": details,
            }),
        );
    }
    Value::Object(out)
}

/// `params.dcds`: `{"<name>": {"Resource": {...}, "Ready": "True"|""}}`.
fn desired_composed(state: Option<&State>) -> Value {
    let mut out = Map::new();
    for (name, res) in state.map(|s| &s.resources).into_iter().flatten() {
        let ready = match PbReady::try_from(res.ready) {
            Ok(PbReady::True) => "True",
            Ok(PbReady::False) => "False",
            _ => "",
        };
        out.insert(
            name.clone(),
            json!({
                "Resource": res.resource.as_ref().map(resource::struct_to_json).unwrap_or_else(|| json!({})),
                "Ready": ready,
            }),
        );
    }
    Value::Object(out)
}

/// `params.requiredResources` / `params.extraResources`:
/// `{"<key>": [{"Resource": {...}}, ...]}` — `function-kcl`'s shape again (a
/// Go `[]Required` marshalled without JSON tags). Crossplane only fills these
/// in on the call *after* the module asked for them, and a lookup that finds
/// nothing yields an empty list, so a module guards with
/// `option("params")?.requiredResources?.<key>` against `Undefined`.
fn required(groups: &HashMap<String, Resources>) -> Value {
    let mut out = Map::new();
    for (key, group) in groups {
        let found: Vec<Value> = group
            .items
            .iter()
            .map(|res| {
                json!({
                    "Resource": res.resource.as_ref().map(resource::struct_to_json).unwrap_or_else(|| json!({})),
                })
            })
            .collect();
        out.insert(key.clone(), Value::Array(found));
    }
    Value::Object(out)
}

/// The requirements `kcl-render` collected, as the response's protobuf
/// message. `kcl-render` is deliberately protobuf-free, so this is the one
/// place `ResourceSelector` is built.
fn requirements(asked: &compose::Requirements) -> Option<Requirements> {
    if asked.is_empty() {
        return None;
    }
    Some(Requirements {
        resources: asked.resources.iter().map(selector).collect(),
        extra_resources: asked.extra_resources.iter().map(selector).collect(),
        ..Default::default()
    })
}

fn selector((key, required): (&String, &compose::RequiredResource)) -> (String, ResourceSelector) {
    let r#match = match &required.r#match {
        compose::SelectorMatch::Name(name) => resource_selector::Match::MatchName(name.clone()),
        compose::SelectorMatch::Labels(labels) => resource_selector::Match::MatchLabels(MatchLabels {
            labels: labels.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
        }),
    };
    (
        key.clone(),
        ResourceSelector {
            api_version: required.api_version.clone(),
            kind: required.kind.clone(),
            // Unset, not empty: an empty namespace is a namespaced lookup in
            // the empty namespace as far as the proto is concerned.
            namespace: required.namespace.clone(),
            r#match: Some(r#match),
        },
    )
}

fn context(req: &RunFunctionRequest) -> Value {
    req.context.as_ref().map(resource::struct_to_json).unwrap_or_else(|| json!({}))
}

/// Desired resources earlier pipeline steps asked for. Dropping them would
/// delete the live resources, since desired state is a full intent.
fn existing_desired(req: &RunFunctionRequest) -> Vec<Composed> {
    let Some(state) = req.desired.as_ref() else {
        return Vec::new();
    };
    let mut resources: Vec<Composed> = state
        .resources
        .iter()
        .map(|(name, res)| Composed {
            name: name.clone(),
            ready: match PbReady::try_from(res.ready) {
                Ok(PbReady::True) => Ready::True,
                Ok(PbReady::False) => Ready::False,
                _ => Ready::Unspecified,
            },
            resource: res.resource.as_ref().map(resource::struct_to_json).unwrap_or_else(|| json!({})),
        })
        .collect();
    // HashMap iteration order is random; keep responses deterministic.
    resources.sort_by(|a, b| a.name.cmp(&b.name));
    resources
}

fn tracing_log(log: &str) {
    for line in log.lines() {
        eprintln!("kcl: {line}");
    }
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding — how Go marshals `map[string][]byte`, which
/// is what KCL packages expect to find in `ocds.*.ConnectionDetails`.
fn base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = u32::from(b[0]) << 16 | u32::from(b[1]) << 8 | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[(n >> (18 - 6 * i)) as usize & 0x3f] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// A module that declares a required resource and reports, in a composed
    /// resource, whether Crossplane has handed it back yet.
    const GATED: &str = r#"
_params = option("params")
_ents = _params?.requiredResources?.entitlement

items = [
    {
        apiVersion = "meta.krm.kcl.dev/v1alpha1"
        kind = "RequiredResources"
        requirements.entitlement = {
            apiVersion = "platform.example.org/v1alpha1"
            kind = "Entitlement"
            name = _params.oxr.spec.team
        }
    }
    {
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "cfg"}
        data.tier = _ents[0].Resource.spec.tier if _ents else "unknown"
    }
]
"#;

    fn pb_resource(value: Value) -> Resource {
        Resource {
            resource: Some(resource::json_to_struct(value.as_object().unwrap())),
            ..Default::default()
        }
    }

    fn gated_request(required_resources: HashMap<String, Resources>) -> RunFunctionRequest {
        let input = json!({
            "apiVersion": "krm.kcl.dev/v1alpha1",
            "kind": "KCLInput",
            "spec": {"source": GATED},
        });
        let oxr = json!({
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "Gated",
            "metadata": {"name": "demo"},
            "spec": {"team": "team-a"},
        });
        RunFunctionRequest {
            input: Some(resource::json_to_struct(input.as_object().unwrap())),
            observed: Some(State { composite: Some(pb_resource(oxr)), resources: HashMap::new() }),
            required_resources,
            ..Default::default()
        }
    }

    async fn run(req: RunFunctionRequest) -> RunFunctionResponse {
        let scratch =
            std::env::temp_dir().join(format!("kclx-function-test-{}", std::process::id()));
        let function = KclFunction::new(Arc::new(Engine::new(scratch)));
        function.run_function(tonic::Request::new(req)).await.unwrap().into_inner()
    }

    /// The whole required-resources loop: the module asks, Crossplane calls
    /// again with what it found, and the module reads it.
    #[tokio::test]
    async fn a_required_resources_item_asks_for_a_resource_without_composing_one() {
        let first = run(gated_request(HashMap::new())).await;
        assert_eq!(
            first.results[0].message, "rendered 1 resource(s)",
            "the meta item is an instruction, not a resource: {:?}",
            first.results
        );

        let desired = first.desired.as_ref().unwrap();
        assert_eq!(desired.resources.len(), 1, "{:?}", desired.resources.keys());
        let cfg = resource::struct_to_json(desired.resources["cfg"].resource.as_ref().unwrap());
        assert_eq!(cfg["data"]["tier"], "unknown", "nothing has been fetched yet");

        let requirements = first.requirements.as_ref().expect("requirements were asked for");
        assert_eq!(requirements.resources.len(), 1);
        let selector = &requirements.resources["entitlement"];
        assert_eq!(selector.kind, "Entitlement");
        assert_eq!(selector.namespace, None, "Entitlement is cluster scoped");
        assert_eq!(selector.r#match, Some(resource_selector::Match::MatchName("team-a".into())));
        assert!(requirements.extra_resources.is_empty());

        // Crossplane's second call, carrying what the selector matched.
        let found = HashMap::from([(
            "entitlement".to_string(),
            Resources {
                items: vec![pb_resource(json!({
                    "apiVersion": "platform.example.org/v1alpha1",
                    "kind": "Entitlement",
                    "spec": {"tier": "gold"},
                }))],
            },
        )]);
        let second = run(gated_request(found)).await;

        let desired = second.desired.as_ref().unwrap();
        let cfg = resource::struct_to_json(desired.resources["cfg"].resource.as_ref().unwrap());
        assert_eq!(cfg["data"]["tier"], "gold", "params.requiredResources reached the module");
        assert_eq!(
            second.requirements, first.requirements,
            "an unchanged requirement must not make Crossplane iterate again"
        );
    }

    #[test]
    fn base64_matches_the_go_encoding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"hello world"), "aGVsbG8gd29ybGQ=");
        assert_eq!(base64(&[0xff, 0xfe, 0xfd]), "//79");
    }

    #[test]
    fn identity_is_borrowed_from_the_observed_xr() {
        let observed = json!({"apiVersion": "cloud.example.org/v1alpha1", "kind": "ApiGateway", "metadata": {"name": "demo"}});
        let desired = merge_identity(&observed, json!({}));
        assert_eq!(desired["kind"], "ApiGateway");
        assert_eq!(desired["metadata"]["name"], "demo");
    }

    #[test]
    fn input_decodes_a_function_kcl_composition() {
        let input: Input = serde_json::from_value(json!({
            "apiVersion": "krm.kcl.dev/v1alpha1",
            "kind": "KCLInput",
            "spec": {
                "source": "oci://docker.io/yurikrupnik/apigateway-aws?tag=0.1.0",
                "target": "Resources",
                "config": {"disableNone": true, "sortKeys": true},
                "params": {"region": "eu-west-1"}
            }
        }))
        .unwrap();
        assert_eq!(input.spec.target, Target::Resources);
        assert!(input.spec.config.disable_none && input.spec.config.sort_keys);
        assert_eq!(input.spec.params["region"], "eu-west-1");
    }

    #[test]
    fn input_defaults_the_target_and_rejects_an_empty_source() {
        let input: Input =
            serde_json::from_value(json!({"kind": "KCLInput", "spec": {"source": "a = 1"}})).unwrap();
        assert_eq!(input.spec.target, Target::Default);
    }

    #[test]
    fn required_resources_reach_params_in_function_kcls_shape() {
        let group = Resources {
            items: vec![
                pb_resource(json!({"kind": "Entitlement"})),
                pb_resource(json!({"kind": "Quota"})),
            ],
        };
        let groups = HashMap::from([("entitlement".to_string(), group)]);

        assert_eq!(
            serde_json::to_string(&required(&groups)).unwrap(),
            r#"{"entitlement":[{"Resource":{"kind":"Entitlement"}},{"Resource":{"kind":"Quota"}}]}"#,
            "the capitalised Resource key is function-kcl's Go field name"
        );
    }

    #[test]
    fn an_empty_required_resources_map_reads_as_absent_in_kcl() {
        // `{}` is what `option("params")?.requiredResources?.entitlement`
        // needs to see before Crossplane has fetched anything: the key
        // resolves to Undefined rather than to a list that looks like a hit.
        assert_eq!(serde_json::to_string(&required(&HashMap::new())).unwrap(), "{}");
    }

    #[test]
    fn requirements_stay_absent_until_the_module_asks_for_something() {
        assert!(requirements(&compose::Requirements::default()).is_none());
    }

    #[test]
    fn requirements_become_resource_selectors() {
        let asked = compose::Requirements {
            resources: BTreeMap::from([(
                "entitlement".to_string(),
                compose::RequiredResource {
                    api_version: "platform.example.org/v1alpha1".into(),
                    kind: "Entitlement".into(),
                    namespace: None,
                    r#match: compose::SelectorMatch::Name("team-a".into()),
                },
            )]),
            extra_resources: BTreeMap::from([(
                "quota".to_string(),
                compose::RequiredResource {
                    api_version: "v1".into(),
                    kind: "ConfigMap".into(),
                    namespace: Some("kube-system".into()),
                    r#match: compose::SelectorMatch::Labels(BTreeMap::from([(
                        "team".to_string(),
                        "a".to_string(),
                    )])),
                },
            )]),
        };

        let out = requirements(&asked).unwrap();
        let entitlement = &out.resources["entitlement"];
        assert_eq!(entitlement.api_version, "platform.example.org/v1alpha1");
        assert_eq!(entitlement.namespace, None, "cluster scoped leaves the field unset");
        assert_eq!(
            entitlement.r#match,
            Some(resource_selector::Match::MatchName("team-a".into()))
        );

        let quota = &out.extra_resources["quota"];
        assert_eq!(quota.namespace.as_deref(), Some("kube-system"));
        assert_eq!(
            quota.r#match,
            Some(resource_selector::Match::MatchLabels(MatchLabels {
                labels: HashMap::from([("team".to_string(), "a".to_string())]),
            }))
        );
    }
}
