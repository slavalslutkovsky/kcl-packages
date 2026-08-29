//! `kclx` — one KCL renderer, two front ends.
//!
//! * `kclx render <source>` runs a KCL package now and prints JSON or YAML.
//! * `kclx function` serves the same renderer as a Crossplane composition
//!   function on :9443.
//!
//! Both go through `kcl_render::Engine`, so what you see locally is what the
//! cluster gets.

mod function;
mod render;

use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use kcl_render::{Engine, deps::Registries};

#[derive(Debug, Parser)]
#[command(
    name = "kclx",
    version,
    about = "Render KCL to JSON/YAML, or serve it as a Crossplane composition function",
    max_term_width = 100
)]
struct Cli {
    /// Directory for inline sources and pulled OCI packages.
    #[arg(long, global = true, env = "KCLX_CACHE_DIR")]
    cache_dir: Option<PathBuf>,

    /// Registry host served without TLS, e.g. `--plain-http-registry
    /// kind-registry`. Repeatable; adds to KCLX_PLAIN_HTTP_REGISTRIES.
    #[arg(long, global = true, value_name = "HOST")]
    plain_http_registry: Vec<String>,

    /// Rewrite a package-reference prefix, e.g. `--rewrite-source
    /// docker.io/yurikrupnik=kind-registry`, so a committed Composition can
    /// resolve against a locally published build. Repeatable; adds to
    /// KCLX_SOURCE_REWRITE.
    #[arg(long, global = true, value_name = "FROM=TO")]
    rewrite_source: Vec<String>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Render a KCL package and print the result.
    Render(render::RenderArgs),

    /// Serve the renderer as a Crossplane composition function.
    Function(FunctionArgs),
}

#[derive(Debug, clap::Args)]
struct FunctionArgs {
    #[command(flatten)]
    sdk: function_sdk_rust::Args,
}

fn main() -> ExitCode {
    // Two rustls crypto providers are linked in: aws-lc-rs, through the
    // function SDK's tonic TLS, and ring, through the OCI client's reqwest.
    // rustls refuses to guess between them and panics on first use — which in
    // a cluster is the mTLS handshake with Crossplane, i.e. a crash loop with
    // no useful message. Pick the one tonic is built against, once, here.
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    }

    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("kclx: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<()> {
    let scratch = cli
        .cache_dir
        .unwrap_or_else(|| std::env::temp_dir().join("kclx"));

    // The environment carries the deployed configuration (a
    // DeploymentRuntimeConfig sets it on the function pod); flags add to it
    // for one-off local runs.
    let mut registries = Registries::from_env();
    registries.plain_http.extend(cli.plain_http_registry);
    for pair in &cli.rewrite_source {
        let (from, to) = pair
            .split_once('=')
            .ok_or_else(|| anyhow!("--rewrite-source expects FROM=TO, got {pair:?}"))?;
        registries.rewrites.push((from.to_string(), to.to_string()));
    }
    let engine = Arc::new(Engine::with_registries(scratch, registries));

    match cli.command {
        Command::Render(args) => {
            let out = render::run(&args, &engine)?;
            let mut stdout = std::io::stdout().lock();
            stdout.write_all(out.as_bytes())?;
            stdout.flush()?;
            Ok(())
        }
        Command::Function(args) => serve(args, engine),
    }
}

fn serve(args: FunctionArgs, engine: Arc<Engine>) -> Result<()> {
    function_sdk_rust::logging::configure(args.sdk.debug);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting the tokio runtime")?;
    runtime
        .block_on(function_sdk_rust::serve(
            function::KclFunction::new(engine),
            &args.sdk,
        ))
        .context("serving the composition function")
}
