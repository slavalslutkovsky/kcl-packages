//! `kclx render` — run a KCL package now, print JSON or YAML.
//!
//! Every flag here exists to make a local invocation indistinguishable from
//! the in-cluster one: the same `option("params")` object, the same
//! `items`-unwrapping, and with `--view desired` the same desired-state
//! conversion the composition function performs.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Args, ValueEnum};
use kcl_render::{Desired, Engine, Options, Request, Source, Target, compose, parse_document, to_yaml_stream};
use serde_json::{Map, Value, json};

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Format {
    Yaml,
    Json,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum View {
    /// The rendered resources: the top-level `items` list.
    Items,
    /// Every public top-level variable, as KCL planned it.
    Plan,
    /// Crossplane desired state, exactly as `kclx function` would return it.
    Desired,
}

#[derive(Debug, Args)]
pub struct RenderArgs {
    /// A path (`.k` file or package directory), inline KCL, or
    /// `oci://<repo>[?tag=<version>]` — the same grammar a Composition's
    /// `spec.source` accepts.
    pub source: String,

    #[arg(short, long, value_enum, default_value_t = Format::Yaml)]
    pub output: Format,

    #[arg(long, value_enum, default_value_t = View::Items)]
    pub view: View,

    /// `option("params")` entry, value taken as a string: `-p region=eu-west-1`.
    #[arg(short = 'p', long = "param", value_name = "KEY=VALUE")]
    pub params: Vec<String>,

    /// `option("params")` entry, value parsed as JSON: `--param-json 'replicas=3'`.
    #[arg(long = "param-json", value_name = "KEY=JSON")]
    pub params_json: Vec<String>,

    /// A URL query string of params: `--query 'region=eu-west-1&replicas=3'`.
    /// Values are JSON when they parse as JSON, strings otherwise — the shape
    /// an HTTP front end would hand to the same engine.
    #[arg(short = 'q', long)]
    pub query: Option<String>,

    /// YAML/JSON file merged into `option("params")` wholesale.
    #[arg(long, value_name = "FILE")]
    pub params_file: Option<PathBuf>,

    /// Observed composite resource → `params.oxr`. Also identifies the XR for
    /// `--view desired`, so status-only items are recognised.
    #[arg(long, value_name = "FILE")]
    pub oxr: Option<PathBuf>,

    /// Observed composed resources → `params.ocds`, keyed by composition
    /// resource name (`{"<name>": {"Resource": {...}}}`).
    #[arg(long, value_name = "FILE")]
    pub ocds: Option<PathBuf>,

    /// Crossplane function context → `params.ctx`.
    #[arg(long, value_name = "FILE")]
    pub ctx: Option<PathBuf>,

    /// Raw KCL top-level argument, like `kcl run -D`. Overrides the generated
    /// ones, `params` included.
    #[arg(short = 'D', long = "arg", value_name = "NAME=VALUE")]
    pub arguments: Vec<String>,

    /// `kcl run -S`: emit only this path of the result.
    #[arg(short = 'S', long = "path-selector", value_name = "PATH")]
    pub path_selectors: Vec<String>,

    /// `kcl run -O`: override an attribute in the program.
    #[arg(short = 'O', long = "override", value_name = "SPEC")]
    pub overrides: Vec<String>,

    /// How to read the rendered items when `--view desired`.
    #[arg(long, value_enum, default_value_t = TargetArg::Default)]
    pub target: TargetArg,

    /// Drop `None`-valued attributes (`kcl run -n`).
    #[arg(short = 'n', long)]
    pub disable_none: bool,

    #[arg(long)]
    pub sort_keys: bool,

    /// Emit `_`-prefixed attributes.
    #[arg(long)]
    pub show_hidden: bool,

    /// `kcl run -r`.
    #[arg(short = 'r', long)]
    pub strict_range_check: bool,

    /// Annotate instances with their schema type path.
    #[arg(long)]
    pub include_schema_type_path: bool,

    /// Vendor dependencies next to the module instead of using the shared
    /// module cache.
    #[arg(long)]
    pub vendor: bool,
}

/// clap cannot derive `ValueEnum` for a type in another crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum TargetArg {
    Default,
    Resources,
    PatchDesired,
    Xr,
}

impl From<TargetArg> for Target {
    fn from(value: TargetArg) -> Self {
        match value {
            TargetArg::Default => Target::Default,
            TargetArg::Resources => Target::Resources,
            TargetArg::PatchDesired => Target::PatchDesired,
            TargetArg::Xr => Target::Xr,
        }
    }
}

pub fn run(args: &RenderArgs, engine: &Engine) -> Result<String> {
    let mut request = Request::new(Source::parse(&args.source));
    request.params = params(args)?;
    request.function_config = Some(json!({
        "apiVersion": "krm.kcl.dev/v1alpha1",
        "kind": "KCLInput",
        "spec": {"source": args.source, "target": Target::from(args.target)},
    }));
    request.options = Options {
        arguments: args.arguments.clone(),
        overrides: args.overrides.clone(),
        path_selectors: args.path_selectors.clone(),
        disable_none: args.disable_none,
        strict_range_check: args.strict_range_check,
        show_hidden: args.show_hidden,
        sort_keys: args.sort_keys,
        include_schema_type_path: args.include_schema_type_path,
        vendor: args.vendor,
    };

    let rendered = engine.render(&request)?;
    if !rendered.log.trim().is_empty() {
        eprint!("{}", rendered.log);
    }

    match args.view {
        View::Plan => emit_one(&rendered.plan, args.output),
        View::Items => match args.output {
            Format::Json => Ok(format!("{:#}\n", Value::Array(rendered.items))),
            Format::Yaml => to_yaml_stream(&rendered.items),
        },
        View::Desired => {
            let observed = request.params.get("oxr").cloned().unwrap_or(Value::Null);
            let mut desired = Desired { composite: observed.clone(), resources: Vec::new() };
            compose::apply(&rendered.items, args.target.into(), &observed, &mut desired)?;
            emit_one(&desired_view(&desired), args.output)
        }
    }
}

/// The desired-state shape the function puts on the wire, as plain JSON.
fn desired_view(desired: &Desired) -> Value {
    let mut resources = Map::new();
    for composed in &desired.resources {
        resources.insert(
            composed.name.clone(),
            json!({"resource": composed.resource, "ready": format!("{:?}", composed.ready)}),
        );
    }
    json!({"composite": desired.composite, "resources": resources})
}

fn emit_one(value: &Value, format: Format) -> Result<String> {
    Ok(match format {
        Format::Json => format!("{value:#}\n"),
        Format::Yaml => serde_yaml_ng::to_string(value)?,
    })
}

/// Assemble `option("params")`. Later sources win, so a `--param` can correct
/// a value that came from `--params-file`.
fn params(args: &RenderArgs) -> Result<Map<String, Value>> {
    let mut params = Map::new();

    if let Some(path) = &args.params_file {
        match read_document(path)? {
            Value::Object(map) => params.extend(map),
            other => bail!("--params-file must hold a mapping, got {other}"),
        }
    }
    for (key, path) in [("oxr", &args.oxr), ("ocds", &args.ocds), ("ctx", &args.ctx)] {
        if let Some(path) = path {
            params.insert(key.to_string(), read_document(path)?);
        }
    }
    // The desired XR starts as the observed one, mirroring the function.
    if let Some(oxr) = params.get("oxr").cloned() {
        params.entry("dxr").or_insert(oxr);
    }
    params.entry("ocds").or_insert_with(|| json!({}));
    params.entry("dcds").or_insert_with(|| json!({}));

    if let Some(query) = &args.query {
        for (key, value) in parse_query(query)? {
            params.insert(key, value);
        }
    }
    for pair in &args.params {
        let (key, value) = split_pair(pair, "--param")?;
        params.insert(key.to_string(), Value::String(value.to_string()));
    }
    for pair in &args.params_json {
        let (key, value) = split_pair(pair, "--param-json")?;
        params.insert(
            key.to_string(),
            serde_json::from_str(value).with_context(|| format!("--param-json {key}: invalid JSON"))?,
        );
    }
    Ok(params)
}

fn split_pair<'a>(pair: &'a str, flag: &str) -> Result<(&'a str, &'a str)> {
    pair.split_once('=')
        .ok_or_else(|| anyhow!("{flag} expects KEY=VALUE, got {pair:?}"))
}

fn read_document(path: &Path) -> Result<Value> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading {}", path.display()))?;
    parse_document(&text).with_context(|| format!("parsing {}", path.display()))
}

/// `region=eu-west-1&replicas=3&tags={"team":"platform"}` → params. A value
/// that parses as JSON keeps its type; everything else stays a string, which
/// is the same coercion `kcl run -D` applies.
fn parse_query(query: &str) -> Result<Vec<(String, Value)>> {
    let mut out = Vec::new();
    for pair in query.trim_start_matches('?').split('&').filter(|p| !p.is_empty()) {
        let (key, value) = split_pair(pair, "--query")?;
        let key = percent_decode(key)?;
        let value = percent_decode(value)?;
        let value = serde_json::from_str(&value).unwrap_or(Value::String(value));
        out.push((key, value));
    }
    Ok(out)
}

fn percent_decode(input: &str) -> Result<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3])?;
                out.push(u8::from_str_radix(hex, 16).with_context(|| format!("bad escape %{hex}"))?);
                i += 3;
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    Ok(String::from_utf8(out)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_values_keep_json_types() {
        let params = parse_query("region=eu-west-1&replicas=3&cors={\"allowOrigins\":[\"*\"]}").unwrap();
        assert_eq!(params[0], ("region".into(), json!("eu-west-1")));
        assert_eq!(params[1], ("replicas".into(), json!(3)));
        assert_eq!(params[2].1, json!({"allowOrigins": ["*"]}));
    }

    #[test]
    fn query_is_percent_decoded() {
        let params = parse_query("?name=my+gateway&path=%2Fapi%2Fv1").unwrap();
        assert_eq!(params[0], ("name".into(), json!("my gateway")));
        assert_eq!(params[1], ("path".into(), json!("/api/v1")));
    }

    #[test]
    fn query_rejects_a_bare_key() {
        assert!(parse_query("region").is_err());
    }
}
