//! The single place KCL is executed. Both the CLI (`kclx render`) and the
//! Crossplane composition function (`kclx function`) go through
//! [`Engine::render`], so a package that renders locally renders identically
//! in-cluster.
//!
//! The KCL runtime is embedded (crate `kcl-lang`), not shelled out to: no
//! `kcl` binary in the function image, no process spawn per reconcile.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use kcl_lang::{API, Argument, ExecProgramArgs, ExternalPkg};
use parking_lot::Mutex;
use serde_json::{Map, Value, json};

use crate::deps::{Registries, Resolver};
use crate::source::{Entry, Source};

/// Knobs that map 1:1 onto `kcl run` flags and onto `function-kcl`'s
/// `spec.config`, so a Composition and a local invocation can be configured
/// the same way.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Options {
    /// `-D name=value`. Values are parsed as JSON, falling back to a KCL
    /// string, exactly like the `kcl` CLI.
    pub arguments: Vec<String>,
    /// `-O override_spec`
    pub overrides: Vec<String>,
    /// `-S path.selector`
    pub path_selectors: Vec<String>,
    /// `-n`: drop `None`-valued attributes from the output.
    pub disable_none: bool,
    /// `-r`
    pub strict_range_check: bool,
    /// Emit `_`-prefixed attributes.
    pub show_hidden: bool,
    pub sort_keys: bool,
    /// Add `_type: pkg.Schema` to every rendered instance.
    pub include_schema_type_path: bool,
    /// Vendor dependencies next to the module instead of using the shared
    /// module cache.
    pub vendor: bool,
}

/// One render. `params` becomes `option("params")` — the contract every KCL
/// package in this repo already reads (`_params = option("params") or {...}`).
#[derive(Debug, Clone)]
pub struct Request {
    pub source: Source,
    pub params: Map<String, Value>,
    /// Surfaced as `option("resource_list").functionConfig`; the Composition's
    /// input object when called as a function.
    pub function_config: Option<Value>,
    pub options: Options,
}

impl Request {
    pub fn new(source: Source) -> Self {
        Self {
            source,
            params: Map::new(),
            function_config: None,
            options: Options::default(),
        }
    }

    pub fn param(mut self, key: impl Into<String>, value: Value) -> Self {
        self.params.insert(key.into(), value);
        self
    }
}

/// What KCL produced.
#[derive(Debug, Clone)]
pub struct Rendered {
    /// Every public top-level variable, as KCL planned it.
    pub plan: Value,
    /// The resources: the top-level `items` list, unwrapped. `function-kcl`
    /// and `krm-kcl` use the same convention.
    pub items: Vec<Value>,
    /// KCL `print()` output.
    pub log: String,
}

/// Reusable KCL runtime handle.
///
/// `API` is `Send + Sync` and `exec_program` takes `&self`, but the runner
/// swaps the process-global panic hook around `catch_unwind`, which races
/// across threads. Renders are therefore serialised: a render costs a few
/// milliseconds, and a composition function is not throughput-bound.
pub struct Engine {
    api: API,
    exec: Mutex<()>,
    /// Resolved `kcl.mod` dependencies, keyed by module root. `exec_program`
    /// does not read `[dependencies]` itself, so this must be done for it —
    /// once per module, not once per reconcile.
    deps: Mutex<HashMap<PathBuf, Vec<ExternalPkg>>>,
    /// Pulled OCI packages, keyed by `<url>[@<tag>]`. The extracted modules
    /// are kept alive for the process lifetime so the cache stays valid.
    pulled: Mutex<HashMap<String, Entry>>,
    /// Downloads and `kcl.mod` walking, cached on disk across processes.
    resolver: Resolver,
    /// Kept so a vendoring render can build a module-local resolver that
    /// still knows about plain-HTTP registries and source rewrites.
    registries: Registries,
    scratch: PathBuf,
}

impl Engine {
    /// `scratch` holds inline sources and the package cache. It is created on
    /// demand.
    pub fn new(scratch: PathBuf) -> Self {
        Self::with_registries(scratch, Registries::default())
    }

    /// As [`Engine::new`], with registry behaviour for a local cluster: hosts
    /// served over plain HTTP, and package-reference rewrites.
    pub fn with_registries(scratch: PathBuf, registries: Registries) -> Self {
        Self {
            api: API::default(),
            exec: Mutex::new(()),
            deps: Mutex::new(HashMap::new()),
            pulled: Mutex::new(HashMap::new()),
            // Content-addressed, so it survives between runs of the CLI and
            // between reconciles of a restarted function without ever
            // serving a stale tag.
            resolver: Resolver::with_registries(scratch.join("cache"), registries.clone()),
            registries,
            scratch,
        }
    }

    pub fn render(&self, req: &Request) -> Result<Rendered> {
        let entry = self.entry(&req.source)?;
        let external_pkgs = match &entry.module_root {
            Some(root) => self.dependencies(root, req.options.vendor)?,
            None => Vec::new(),
        };

        let args = ExecProgramArgs {
            work_dir: entry.work_dir.display().to_string(),
            k_filename_list: entry.files.clone(),
            args: self.arguments(req)?,
            overrides: req.options.overrides.clone(),
            path_selector: req.options.path_selectors.clone(),
            disable_none: req.options.disable_none,
            strict_range_check: req.options.strict_range_check,
            show_hidden: req.options.show_hidden,
            sort_keys: req.options.sort_keys,
            include_schema_type_path: req.options.include_schema_type_path,
            external_pkgs,
            ..Default::default()
        };

        let result = {
            let _serialised = self.exec.lock();
            self.api.exec_program(&args).map_err(|e| anyhow!("{e}"))?
        };
        // Compile/parse failures come back as `Err`; runtime failures
        // (`assert`, index errors) come back as `Ok` with `err_message` set.
        if !result.err_message.is_empty() {
            bail!("{}", result.err_message.trim_end());
        }

        let plan: Value = if result.json_result.trim().is_empty() {
            Value::Object(Map::new())
        } else {
            serde_json::from_str(&result.json_result)
                .context("KCL returned a result that is not JSON")?
        };
        Ok(Rendered {
            items: unwrap_items(&plan),
            plan,
            log: result.log_message,
        })
    }

    /// The five top-level arguments `function-kcl`/`krm-kcl` pass, plus the
    /// caller's own `-D` pairs last so they can override.
    fn arguments(&self, req: &Request) -> Result<Vec<Argument>> {
        let params = Value::Object(req.params.clone());
        let resource_list = json!({
            "apiVersion": "config.kubernetes.io/v1",
            "kind": "ResourceList",
            "items": [],
            "functionConfig": req.function_config.clone().unwrap_or(Value::Null),
        });
        let env: Map<String, Value> = std::env::vars()
            .map(|(k, v)| (k, Value::String(v)))
            .collect();

        let mut args = vec![
            Argument {
                name: "params".into(),
                value: params.to_string(),
            },
            Argument {
                name: "resource_list".into(),
                value: resource_list.to_string(),
            },
            Argument {
                name: "items".into(),
                value: "[]".into(),
            },
            Argument {
                name: "PATH".into(),
                value: std::env::var("PATH").unwrap_or_default(),
            },
            Argument {
                name: "env".into(),
                value: Value::Object(env).to_string(),
            },
        ];
        for arg in &req.options.arguments {
            let (name, value) = arg
                .split_once('=')
                .ok_or_else(|| anyhow!("argument must be name=value, got {arg:?}"))?;
            args.push(Argument {
                name: name.to_string(),
                value: value.to_string(),
            });
        }
        Ok(args)
    }

    fn entry(&self, source: &Source) -> Result<Entry> {
        match source {
            Source::Oci { url, tag } => {
                let key = match tag {
                    Some(tag) => format!("{url}@{tag}"),
                    None => url.clone(),
                };
                // A cached pull is only good while the module cache still
                // holds it: `kcl mod` cleanups and `rm -rf ~/.kcl` happen,
                // and a long-lived function must not serve a dangling path.
                let cached = self.pulled.lock().get(&key).cloned();
                if let Some(hit) = cached {
                    if hit.work_dir.exists() {
                        return Ok(hit);
                    }
                    self.pulled.lock().remove(&key);
                }
                let entry = self.pull(source, &key)?;
                self.pulled.lock().insert(key, entry.clone());
                Ok(entry)
            }
            // Per-process so concurrent CLI runs cannot clobber each other's
            // inline `main.k`; OCI pulls stay in the shared cache.
            other => {
                other.materialise(&self.scratch.join(format!("inline-{}", std::process::id())))
            }
        }
    }

    /// Pull an OCI package and use it as the entry point. The registry is
    /// spoken to directly (pure Rust, no `kcl mod pull`), and the package
    /// lands in a content-addressed cache under the scratch directory.
    fn pull(&self, source: &Source, key: &str) -> Result<Entry> {
        let Source::Oci { url, tag } = source else {
            bail!("not an OCI source");
        };
        let root = self
            .resolver
            .pull(url, tag.as_deref())
            .with_context(|| format!("pulling {key}"))?;
        Ok(Entry {
            work_dir: root.clone(),
            files: vec![root.display().to_string()],
            module_root: Some(root),
        })
    }

    fn dependencies(&self, module_root: &PathBuf, vendor: bool) -> Result<Vec<ExternalPkg>> {
        // Memoised, but only while every resolved path is still on disk: a
        // cache wipe under a long-lived function would otherwise leave the
        // memo pointing at deleted packages, and KCL reports that as a
        // baffling "pkgpath not found" inside the dependency's own source.
        let cached = self.deps.lock().get(module_root).cloned();
        if let Some(hit) = cached {
            if hit.iter().all(|pkg| Path::new(&pkg.pkg_path).exists()) {
                return Ok(hit);
            }
            self.deps.lock().remove(module_root);
        }
        // `vendor` means "keep the downloads next to the module", so it gets
        // its own cache root; everything else shares the engine's.
        let vendored;
        let resolver = if vendor {
            vendored = Resolver::with_registries(module_root.join("vendor"), self.registries.clone());
            &vendored
        } else {
            &self.resolver
        };
        let resolved = resolver
            .resolve(module_root)
            .with_context(|| format!("resolving {}/kcl.mod", module_root.display()))?;
        self.deps.lock().insert(module_root.clone(), resolved.clone());
        Ok(resolved)
    }
}

/// KCL plans every public top-level variable; only `items` carries resources.
/// A program that binds a single object at top level (or returns a bare list)
/// is accepted too, so ad-hoc snippets work from the CLI.
fn unwrap_items(plan: &Value) -> Vec<Value> {
    match plan {
        Value::Object(map) => match map.get("items") {
            Some(Value::Array(items)) => items.clone(),
            Some(other) if !other.is_null() => vec![other.clone()],
            _ if map.contains_key("apiVersion") || map.contains_key("kind") => vec![plan.clone()],
            _ => Vec::new(),
        },
        Value::Array(items) => items.clone(),
        Value::Null => Vec::new(),
        other => vec![other.clone()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn items_are_unwrapped_from_the_plan() {
        let plan = json!({"items": [{"kind": "A"}, {"kind": "B"}], "other": 1});
        assert_eq!(unwrap_items(&plan).len(), 2);
        assert!(unwrap_items(&json!({"other": 1})).is_empty());
        assert_eq!(
            unwrap_items(&json!({"kind": "A", "apiVersion": "v1"})).len(),
            1
        );
        assert_eq!(unwrap_items(&json!([{"kind": "A"}])).len(), 1);
    }
}
