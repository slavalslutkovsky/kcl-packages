//! `kcl-console` — the HTTP backend of `apps/console`.

use std::net::SocketAddr;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use kcl_console::api::{self, Console};
use kcl_console::model::Source;

#[derive(Debug, Parser)]
#[command(name = "kcl-console", version, about = "Serve the multi-cloud console API", max_term_width = 100)]
struct Cli {
    #[arg(long, default_value = "127.0.0.1:8095", env = "KCL_CONSOLE_ADDR")]
    addr: SocketAddr,

    /// Sources to aggregate: k8s, aws, gcp, azure. Comma-separated or
    /// repeated; all four when omitted.
    #[arg(long = "source", value_delimiter = ',', env = "KCL_CONSOLE_SOURCES")]
    sources: Vec<Source>,

    /// Per-source deadline for one listing, in seconds.
    #[arg(long, default_value_t = 20)]
    timeout_secs: u64,
}

fn main() -> ExitCode {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("kcl_console=info"));
    tracing_subscriber::fmt().with_env_filter(filter).init();

    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("kcl-console: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<()> {
    let sources = match cli.sources.is_empty() {
        true => Source::ALL.to_vec(),
        false => cli.sources,
    };
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting the tokio runtime")?
        .block_on(async move {
            let console = Console::new(&sources, Duration::from_secs(cli.timeout_secs)).await;
            api::serve(Arc::new(console), cli.addr).await
        })
}
