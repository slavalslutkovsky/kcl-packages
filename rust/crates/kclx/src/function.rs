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
use function_sdk_rust::proto::v1::{Ready as PbReady, Resource, RunFunctionRequest, RunFunctionResponse, State};
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
            Ok((desired, count)) => {
                rsp.desired = Some(desired);
                response::normal(&mut rsp, format!("rendered {count} resource(s)"));
            }
            Err(err) => {
                response::fatal(&mut rsp, format!("{err:#}"));
            }
        }
        Ok(tonic::Response::new(rsp))
    }
}

impl KclFunction {
    async fn render(&self, req: &RunFunctionRequest) -> Result<(State, usize)> {
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
        compose::apply(&rendered.items, input.spec.target, &observed_xr, &mut desired)?;

        let count = rendered.items.len();
        Ok((state(req, desired)?, count))
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
}
