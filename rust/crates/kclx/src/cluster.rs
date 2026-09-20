//! The cluster-facing front ends: the controller, the REST API, and the
//! `KclModule` CLI.
//!
//! All three are argument parsing and printing only. Every decision they
//! could disagree about — how a spec becomes a render, what an apply writes,
//! what a failure is called — lives in `kcl_operator`.

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use kcl_operator::controller::{self, Options};
use kcl_operator::crd::{KclModule, KclModuleSpec};
use kcl_operator::service::Service;
use kcl_operator::{api, crd};
use kcl_render::Engine;
use kube::{Client, CustomResourceExt, ResourceExt};
use serde::Serialize;

#[derive(Debug, clap::Args)]
pub struct OperatorArgs {
    #[command(subcommand)]
    command: OperatorCommand,
}

#[derive(Debug, clap::Subcommand)]
enum OperatorCommand {
    /// Watch KclModules and reconcile them: render, apply, prune.
    Run(RunArgs),
    /// Print the KclModule CustomResourceDefinition.
    Crd,
}

#[derive(Debug, clap::Args)]
pub struct RunArgs {
    /// Watch a single namespace. Cluster-wide when omitted.
    #[arg(long, short = 'n')]
    namespace: Option<String>,

    /// Field manager for the applied objects. Change it and the next apply
    /// takes ownership of every field under the new name.
    #[arg(long, default_value = "kclx")]
    field_manager: String,

    /// Backoff after a failed reconcile. Successful ones requeue on the
    /// module's own `spec.interval`.
    #[arg(long, default_value = "30s")]
    error_requeue: String,
}

#[derive(Debug, clap::Args)]
pub struct ApiArgs {
    #[arg(long, default_value = "127.0.0.1:8080")]
    addr: SocketAddr,

    /// Field manager used by writes through the API.
    #[arg(long, default_value = "kclx-api")]
    field_manager: String,
}

#[derive(Debug, clap::Args)]
pub struct ModuleArgs {
    #[command(subcommand)]
    command: ModuleCommand,
}

#[derive(Debug, clap::Subcommand)]
enum ModuleCommand {
    /// List modules and their readiness.
    Ls(LsArgs),
    /// Print one module.
    Get(GetArgs),
    /// Create or update a module from a manifest.
    Apply(ApplyArgs),
    /// Delete a module; the controller deletes what it applied.
    Rm(GetArgs),
    /// Render a module's spec without applying it, as the controller would.
    Render(GetArgs),
}

#[derive(Debug, clap::Args)]
struct LsArgs {
    #[arg(long, short = 'n')]
    namespace: Option<String>,
    /// Every namespace (the default when --namespace is absent).
    #[arg(long, short = 'A')]
    all_namespaces: bool,
}

#[derive(Debug, clap::Args)]
struct GetArgs {
    name: String,
    #[arg(long, short = 'n', default_value = "default")]
    namespace: String,
    #[arg(long, short = 'o', default_value = "yaml", value_parser = ["yaml", "json"])]
    output: String,
}

#[derive(Debug, clap::Args)]
struct ApplyArgs {
    /// Manifest holding one KclModule. `-` reads stdin.
    #[arg(long, short = 'f')]
    file: String,
    /// Namespace for a manifest that does not name one.
    #[arg(long, short = 'n', default_value = "default")]
    namespace: String,
}

pub fn operator(args: OperatorArgs, engine: Arc<Engine>) -> Result<()> {
    match args.command {
        // No cluster, no runtime: printing the schema must work before the
        // CRD it describes is installed.
        OperatorCommand::Crd => {
            print!("{}", serde_yaml_ng::to_string(&KclModule::crd())?);
            Ok(())
        }
        OperatorCommand::Run(run) => {
            logging();
            let requeue = crd::parse_interval(&run.error_requeue)
                .map_err(|e| anyhow::anyhow!("--error-requeue: {e}"))?;
            runtime()?.block_on(async move {
                controller::run(client().await?, engine, Options {
                    namespace: run.namespace,
                    field_manager: run.field_manager,
                    error_requeue: requeue,
                })
                .await
            })
        }
    }
}

pub fn serve_api(args: ApiArgs, engine: Arc<Engine>) -> Result<()> {
    logging();
    runtime()?.block_on(async move {
        let service = Arc::new(Service::new(client().await?, engine, args.field_manager));
        api::serve(service, args.addr).await
    })
}

pub fn module(args: ModuleArgs, engine: Arc<Engine>) -> Result<()> {
    runtime()?.block_on(async move {
        let service = Service::new(client().await?, engine, "kclx-cli");
        match args.command {
            ModuleCommand::Ls(ls) => {
                let namespace = if ls.all_namespaces {
                    None
                } else {
                    ls.namespace.as_deref()
                };
                let modules = service.list(namespace).await?;
                print_table(&modules);
                Ok(())
            }
            ModuleCommand::Get(get) => {
                let module = service.get(&get.namespace, &get.name).await?;
                print_object(&module, &get.output)
            }
            ModuleCommand::Apply(apply) => {
                let module = read_module(&apply.file, &apply.namespace)?;
                let applied = service.apply(&module).await?;
                println!(
                    "kclmodule.kclx.example.org/{} applied to {}",
                    applied.name_any(),
                    applied.namespace().unwrap_or_default()
                );
                Ok(())
            }
            ModuleCommand::Rm(rm) => {
                service.delete(&rm.namespace, &rm.name).await?;
                println!("kclmodule.kclx.example.org/{} deleted", rm.name);
                Ok(())
            }
            ModuleCommand::Render(render) => {
                let module = service.get(&render.namespace, &render.name).await?;
                let preview = service
                    .preview(
                        &module.spec,
                        module.target_namespace(),
                        &module.label_value(),
                    )
                    .await?;
                print_object(&preview, &render.output)
            }
        }
    })
}

fn print_table(modules: &[KclModule]) {
    if modules.is_empty() {
        eprintln!("no KclModules found");
        return;
    }
    println!(
        "{:<24} {:<16} {:<8} {:<9} STATUS",
        "NAME", "NAMESPACE", "READY", "OBJECTS"
    );
    for module in modules {
        let condition = module
            .status
            .as_ref()
            .and_then(|status| status.conditions.iter().find(|c| c.type_ == crd::READY));
        let objects = module
            .status
            .as_ref()
            .map(|status| status.inventory.len())
            .unwrap_or(0);
        println!(
            "{:<24} {:<16} {:<8} {:<9} {}",
            module.name_any(),
            module.namespace().unwrap_or_default(),
            condition.map(|c| c.status.as_str()).unwrap_or("-"),
            objects,
            condition.map(|c| one_line(&c.message)).unwrap_or_default(),
        );
    }
}

/// A KCL compile error is several lines with a caret diagram; a table row is
/// one line. `kclx module get` still shows the whole thing.
fn one_line(message: &str) -> String {
    let first = message.lines().next().unwrap_or_default().trim();
    match first.char_indices().nth(72) {
        Some((cut, _)) => format!("{}…", &first[..cut]),
        None => first.to_string(),
    }
}

fn print_object<T: Serialize>(value: &T, format: &str) -> Result<()> {
    let text = match format {
        "json" => serde_json::to_string_pretty(value)?,
        _ => serde_yaml_ng::to_string(value)?,
    };
    println!("{}", text.trim_end());
    Ok(())
}

fn read_module(path: &str, namespace: &str) -> Result<KclModule> {
    let text = if path == "-" {
        std::io::read_to_string(std::io::stdin()).context("reading the manifest from stdin")?
    } else {
        std::fs::read_to_string(path).with_context(|| format!("reading {path}"))?
    };

    // Accept both a full manifest and a bare spec, because the API takes a
    // bare spec and a copy-pasted `kubectl get -o yaml` is a full one.
    let document: serde_json::Value = kcl_render::parse_document(&text)?;
    let mut module = match document.get("spec") {
        Some(_) => serde_json::from_value::<KclModule>(document.clone())
            .context("parsing the manifest as a KclModule")?,
        None => {
            let spec: KclModuleSpec = serde_json::from_value(document.clone())
                .context("parsing the manifest as a KclModuleSpec")?;
            let name = document
                .get("name")
                .and_then(|v| v.as_str())
                .context("a bare spec needs a `name`")?;
            KclModule::new(name, spec)
        }
    };
    if module.metadata.name.as_deref().unwrap_or_default().is_empty() {
        bail!("the manifest has no metadata.name");
    }
    if module.metadata.namespace.is_none() {
        module.metadata.namespace = Some(namespace.to_string());
    }
    Ok(module)
}

async fn client() -> Result<Client> {
    Client::try_default()
        .await
        .context("connecting to the cluster (is KUBECONFIG set?)")
}

fn runtime() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting the tokio runtime")
}

/// `RUST_LOG` wins; the default is quiet enough to read and loud enough to
/// see every reconcile.
fn logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("kclx=info,kcl_operator=info"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}
