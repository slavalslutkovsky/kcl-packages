//! REST front end over [`Agent`].
//!
//! Kept separate from `kcl_operator::api` rather than merged into it: this
//! process holds model credentials and, under approval, writes kinds the
//! module API has no business touching, so it gets its own binding, its own
//! ServiceAccount and its own port.
//!
//! ```text
//! GET  /healthz   process is up
//! GET  /readyz    the API server answers
//! POST /v1/agent  run one task: {"task", "namespace"?, "approve"?, "maxSteps"?}
//! ```

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context as _, Result};
use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::json;
use tracing::info;

use crate::agent::{Agent, Run, RunRequest};
use crate::error::Error;

pub fn router(agent: Arc<Agent>) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/readyz", get(readyz))
        .route("/v1/agent", post(run))
        .with_state(agent)
}

pub async fn serve(agent: Arc<Agent>, addr: SocketAddr) -> Result<()> {
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    info!(%addr, "serving the agent API");
    axum::serve(listener, router(agent))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("serving the agent API")
}

async fn readyz(State(agent): State<Arc<Agent>>) -> Result<String, Error> {
    Ok(agent.toolbox().service().apiserver_version().await?)
}

async fn run(
    State(agent): State<Arc<Agent>>,
    Json(request): Json<RunRequest>,
) -> Result<Json<Run>, Error> {
    // Steps are returned whole at the end; there is nothing to observe live
    // over a non-streaming HTTP response.
    Ok(Json(agent.run(request, &mut |_| {}).await?))
}

/// The same `{reason, error}` body `kcl_operator::api` answers with, so one
/// client can switch on failures from either service.
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let body = json!({"reason": self.reason(), "error": self.to_string()});
        (self.status(), Json(body)).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    async fn body(response: Response) -> serde_json::Value {
        let bytes = axum::body::to_bytes(response.into_body(), 64 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn a_model_failure_is_a_bad_gateway_carrying_the_reason() {
        let response = Error::Model("404: no such model".into()).into_response();
        assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
        assert_eq!(
            body(response).await,
            json!({"reason": "ModelFailed", "error": "model request failed: 404: no such model"})
        );
    }

    #[tokio::test]
    async fn an_empty_task_is_the_callers_fault() {
        let response = Error::Invalid("task is empty".into()).into_response();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(body(response).await["reason"], json!("InvalidArguments"));
    }
}
