//! REST front end over [`Service`].
//!
//! Deliberately thin: every route is one call into the service layer that
//! `kclx module …` also calls, so the HTTP surface cannot grow behaviour the
//! CLI does not have. It is not a proxy for the Kubernetes API — it exposes
//! `KclModule` and the render that produces its objects, nothing else.
//!
//! ```text
//! GET    /healthz                        process is up
//! GET    /readyz                         the API server answers
//! GET    /v1/modules[?namespace=ns]      list
//! GET    /v1/modules/{namespace}/{name}  read
//! PUT    /v1/modules/{namespace}/{name}  create or update (server-side apply)
//! DELETE /v1/modules/{namespace}/{name}  delete (the controller prunes)
//! POST   /v1/render                      render a spec without applying it
//! ```

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context as _, Result};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tracing::info;

use crate::crd::{KclModule, KclModuleSpec};
use crate::error::Error;
use crate::service::{Preview, Service};

pub fn router(service: Arc<Service>) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/readyz", get(readyz))
        .route("/v1/modules", get(list))
        .route(
            "/v1/modules/{namespace}/{name}",
            get(read).put(write).delete(remove),
        )
        .route("/v1/render", post(render))
        .with_state(service)
}

pub async fn serve(service: Arc<Service>, addr: SocketAddr) -> Result<()> {
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    info!(%addr, "serving the KclModule API");
    axum::serve(listener, router(service))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("serving the API")
}

#[derive(Debug, Default, Deserialize)]
struct ListQuery {
    /// Absent means every namespace.
    namespace: Option<String>,
}

#[derive(Debug, Serialize)]
struct List {
    items: Vec<KclModule>,
}

/// A spec plus where it would be rendered. The module need not exist: this
/// is the endpoint for "what would this package produce?".
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RenderRequest {
    #[serde(flatten)]
    spec: KclModuleSpec,
    /// Namespace the rendered namespaced objects would land in.
    #[serde(default = "default_namespace")]
    namespace: String,
}

async fn readyz(State(service): State<Arc<Service>>) -> Result<String, Error> {
    service.apiserver_version().await
}

async fn list(
    State(service): State<Arc<Service>>,
    Query(query): Query<ListQuery>,
) -> Result<Json<List>, Error> {
    let items = service.list(query.namespace.as_deref()).await?;
    Ok(Json(List { items }))
}

async fn read(
    State(service): State<Arc<Service>>,
    Path((namespace, name)): Path<(String, String)>,
) -> Result<Json<KclModule>, Error> {
    Ok(Json(service.get(&namespace, &name).await?))
}

async fn write(
    State(service): State<Arc<Service>>,
    Path((namespace, name)): Path<(String, String)>,
    Json(spec): Json<KclModuleSpec>,
) -> Result<Json<KclModule>, Error> {
    let mut module = KclModule::new(&name, spec);
    module.metadata.namespace = Some(namespace);
    Ok(Json(service.apply(&module).await?))
}

async fn remove(
    State(service): State<Arc<Service>>,
    Path((namespace, name)): Path<(String, String)>,
) -> Result<StatusCode, Error> {
    service.delete(&namespace, &name).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn render(
    State(service): State<Arc<Service>>,
    Json(request): Json<RenderRequest>,
) -> Result<Json<Preview>, Error> {
    let preview = service
        .preview(&request.spec, &request.namespace, "preview")
        .await?;
    Ok(Json(preview))
}

/// Errors carry the same `reason` the `Ready` condition uses, so a client
/// switching on failures sees one vocabulary whether it read the status or
/// called the API.
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let body = json!({"reason": self.reason(), "error": self.to_string()});
        (self.status(), Json(body)).into_response()
    }
}

fn default_namespace() -> String {
    "default".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crd::RenderOptions;

    #[test]
    fn a_render_request_is_a_spec_plus_a_namespace() {
        let request: RenderRequest = serde_json::from_value(json!({
            "source": "oci://docker.io/yurikrupnik/app?tag=0.1.4",
            "params": {"name": "web"},
            "namespace": "apps",
        }))
        .unwrap();
        assert_eq!(request.namespace, "apps");
        assert_eq!(request.spec.params.unwrap()["name"], json!("web"));
        // Spec defaults still apply through the flatten.
        assert_eq!(request.spec.interval, "5m");
        assert!(request.spec.prune);
        assert!(request.spec.options.disable_none);
    }

    #[test]
    fn the_namespace_defaults_so_a_bare_spec_renders() {
        let request: RenderRequest = serde_json::from_value(json!({"source": "a = 1"})).unwrap();
        assert_eq!(request.namespace, "default");
        assert_eq!(request.spec.options, RenderOptions {
            arguments: vec![],
            disable_none: true,
            sort_keys: false,
        });
    }

    #[test]
    fn errors_answer_with_the_condition_reason_and_a_matching_status() {
        let response = Error::Invalid("item 0: has no kind".into()).into_response();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }
}
