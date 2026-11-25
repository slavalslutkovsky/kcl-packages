//! HTTP front end the micro frontends call.
//!
//! ```text
//! GET /healthz      process is up
//! GET /api/buckets  Inventory: every enabled source's report + merged rows
//! ```
//!
//! Every request asks every enabled source afresh, concurrently; a failing
//! source is reported in `sources[]` and never fails the response.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result};
use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};
use futures::future::join_all;
use tracing::info;

use crate::cloud;
use crate::k8s::Cluster;
use crate::model::{Bucket, Failure, Inventory, Source, SourceReport, SourceState, merge};

pub struct Console {
    /// `None` when `k8s` is not an enabled source.
    cluster: Option<Cluster>,
    clouds: Vec<Source>,
    timeout: Duration,
}

impl Console {
    pub async fn new(sources: &[Source], timeout: Duration) -> Self {
        let cluster = match sources.contains(&Source::K8s) {
            true => Some(Cluster::connect().await),
            false => None,
        };
        let clouds = Source::ALL
            .into_iter()
            .filter(|source| *source != Source::K8s && sources.contains(source))
            .collect();
        Console { cluster, clouds, timeout }
    }

    pub async fn inventory(&self) -> Inventory {
        let composites = async {
            let cluster = self.cluster.as_ref()?;
            let started = Instant::now();
            let result = cluster.buckets().await;
            Some(report(Source::K8s, cluster.label.clone(), started, result))
        };
        let clouds = join_all(self.clouds.iter().map(|&source| async move {
            let started = Instant::now();
            let result = cloud::list(source, self.timeout).await;
            report(source, cloud::label(source), started, result)
        }));
        let (composites, clouds) = tokio::join!(composites, clouds);

        let mut sources = Vec::new();
        let composites = composites.map_or_else(Vec::new, |(report, rows)| {
            sources.push(report);
            rows
        });
        let mut found = Vec::new();
        for (report, rows) in clouds {
            sources.push(report);
            found.extend(rows);
        }
        Inventory { sources, buckets: merge(composites, found) }
    }
}

fn report(
    source: Source,
    label: String,
    started: Instant,
    result: Result<Vec<Bucket>, Failure>,
) -> (SourceReport, Vec<Bucket>) {
    let millis = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    let (state, detail, rows) = match result {
        Ok(rows) => (SourceState::Ok, None, rows),
        Err(Failure::Unavailable(why)) => (SourceState::Unavailable, Some(why), Vec::new()),
        Err(Failure::Error(why)) => (SourceState::Error, Some(why), Vec::new()),
    };
    let report = SourceReport { source, label, state, detail, count: rows.len(), millis };
    (report, rows)
}

pub fn router(console: Arc<Console>) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/buckets", get(buckets))
        .with_state(console)
}

async fn buckets(State(console): State<Arc<Console>>) -> Json<Inventory> {
    Json(console.inventory().await)
}

pub async fn serve(console: Arc<Console>, addr: SocketAddr) -> Result<()> {
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    info!(%addr, "serving the console API");
    axum::serve(listener, router(console))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("serving the console API")
}
