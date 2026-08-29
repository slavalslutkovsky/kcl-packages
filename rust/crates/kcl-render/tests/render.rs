//! End-to-end checks of the shared render path: KCL in, resources out, and
//! the Crossplane desired state the composition function derives from them.
//!
//! Inline sources only — no registry, no `kcl.mod` — so these stay hermetic.

use kcl_render::{Desired, Engine, Request, Source, Target, compose};
use serde_json::json;

fn engine(name: &str) -> Engine {
    let scratch = std::env::temp_dir().join(format!("kcl-render-test-{}-{name}", std::process::id()));
    Engine::new(scratch)
}

const BUCKET: &str = r#"
_params = option("params")
_oxr = _params.oxr

items = [
    {
        apiVersion = "storage.example.org/v1beta1"
        kind = "Bucket"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.forProvider = {
            location = _oxr.spec.region
            versioning = _params?.versioning or False
        }
    }
    {
        apiVersion = _oxr.apiVersion
        kind = _oxr.kind
        metadata.name = _oxr.metadata.name
        status.ready = "managed" in (_params?.ocds or {})
    }
]
"#;

fn oxr() -> serde_json::Value {
    json!({
        "apiVersion": "cloud.example.org/v1alpha1",
        "kind": "Bucket",
        "metadata": {"name": "demo"},
        "spec": {"region": "us-central1"}
    })
}

#[test]
fn params_reach_the_program_and_items_come_back() {
    let engine = engine("items");
    let request = Request::new(Source::Inline(BUCKET.into()))
        .param("oxr", oxr())
        .param("versioning", json!(true));

    let rendered = engine.render(&request).unwrap();

    assert_eq!(rendered.items.len(), 2, "{:#?}", rendered.items);
    assert_eq!(rendered.items[0]["spec"]["forProvider"]["location"], "us-central1");
    assert_eq!(rendered.items[0]["spec"]["forProvider"]["versioning"], true);
}

#[test]
fn items_become_composed_resources_and_a_composite_status_patch() {
    let engine = engine("desired");
    let request = Request::new(Source::Inline(BUCKET.into()))
        .param("oxr", oxr())
        .param("ocds", json!({"managed": {"Resource": {"status": {}}}}));

    let rendered = engine.render(&request).unwrap();
    let mut desired = Desired { composite: oxr(), resources: Vec::new() };
    compose::apply(&rendered.items, Target::Default, &oxr(), &mut desired).unwrap();

    assert_eq!(desired.resources.len(), 1, "the XR item is a patch, not a composed resource");
    let composed = &desired.resources[0];
    assert_eq!(composed.name, "managed", "named by the annotation");
    assert!(
        composed.resource["metadata"].get("annotations").is_none(),
        "the naming annotation is stripped: {}",
        composed.resource
    );
    assert_eq!(desired.composite["status"]["ready"], true, "observed state reached the XR status");
    assert_eq!(desired.composite["spec"]["region"], "us-central1", "spec is untouched");
}

#[test]
fn engine_is_reusable_across_renders() {
    let engine = engine("reuse");
    for region in ["us-central1", "europe-west1"] {
        let oxr = json!({
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "Bucket",
            "metadata": {"name": "demo"},
            "spec": {"region": region}
        });
        let rendered = engine.render(&Request::new(Source::Inline(BUCKET.into())).param("oxr", oxr)).unwrap();
        assert_eq!(rendered.items[0]["spec"]["forProvider"]["location"], region);
    }
}

#[test]
fn assertion_failures_are_reported_as_errors() {
    let engine = engine("assert");
    let source = Source::Inline("assert option(\"params\").replicas > 0, \"replicas must be positive\"\n".into());
    let request = Request::new(source).param("replicas", json!(0));

    let err = engine.render(&request).unwrap_err().to_string();
    assert!(err.contains("replicas must be positive"), "unexpected error: {err}");
}

#[test]
fn a_missing_source_is_an_error_not_an_empty_render() {
    let engine = engine("missing");
    let err = engine
        .render(&Request::new(Source::Path("does/not/exist.k".into())))
        .unwrap_err()
        .to_string();
    assert!(err.contains("does/not/exist.k"), "unexpected error: {err}");
}
