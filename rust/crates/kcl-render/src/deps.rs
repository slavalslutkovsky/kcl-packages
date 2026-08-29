//! Package resolution: pulling OCI-published KCL modules, and turning a
//! module's `kcl.mod` `[dependencies]` into the `-E name=path` list the KCL
//! compiler needs.
//!
//! The KCL SDK ships a resolver of its own (`API::update_dependencies`), but
//! its OCI client accepts exactly one layer media type,
//! `application/vnd.oci.image.layer.v1.tar`. Every package this repo
//! publishes carries `application/vnd.oci.image.layer.v1.tar+gzip`, so that
//! resolver only ever worked when `~/.kcl/kpm` happened to be warm — which is
//! never true in a freshly started function image. Hence a resolver here:
//! both layer encodings, a content-addressed cache we own, and no reliance on
//! a `kcl`/`kpm` binary being present.

use std::collections::{HashSet, VecDeque};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, anyhow, bail};
use flate2::read::GzDecoder;
use kcl_lang::ExternalPkg;
use oci_client::manifest::{
    IMAGE_LAYER_GZIP_MEDIA_TYPE, IMAGE_LAYER_MEDIA_TYPE, OciDescriptor, OciImageManifest,
};
use oci_client::secrets::RegistryAuth;
use oci_client::client::{ClientConfig, ClientProtocol};
use oci_client::{Client, Reference};
use sha2::{Digest, Sha256};

const OCI_SCHEME: &str = "oci://";

/// Where a bare `name = "<version>"` dependency is published, matching the
/// SDK's own default and its `KCL_SRC_URL` override so a `kcl.mod` resolves
/// to the same place here as it does under `kcl run`.
const DEFAULT_REGISTRY: &str = "ghcr.io/kcl-lang";

/// Registry behaviour a local cluster needs: an in-cluster registry is served
/// over plain HTTP, and the Compositions committed in this repo point at the
/// published `docker.io/...` packages, which is the wrong place when the same
/// Composition is being tried against a locally published build.
///
/// Both are read from the environment ([`Registries::from_env`]) so a
/// `DeploymentRuntimeConfig` can configure the function pod without rebuilding
/// the image, and both are settable from the CLI.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Registries {
    /// Registry hosts (`host` or `host:port`) served without TLS.
    pub plain_http: Vec<String>,
    /// `from=to` prefix rewrites applied to every package reference, longest
    /// prefix first.
    pub rewrites: Vec<(String, String)>,
}

/// Plain-HTTP registry hosts, comma-separated: `kind-registry,localhost:5001`.
pub const ENV_PLAIN_HTTP: &str = "KCLX_PLAIN_HTTP_REGISTRIES";
/// Package reference rewrites, comma-separated `from=to` pairs:
/// `docker.io/yurikrupnik=kind-registry`.
pub const ENV_REWRITE: &str = "KCLX_SOURCE_REWRITE";

impl Registries {
    pub fn from_env() -> Self {
        let plain_http = std::env::var(ENV_PLAIN_HTTP)
            .map(|v| split_list(&v))
            .unwrap_or_default();
        let rewrites = std::env::var(ENV_REWRITE)
            .map(|v| {
                split_list(&v)
                    .iter()
                    .filter_map(|pair| pair.split_once('=').map(|(f, t)| (f.to_string(), t.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        Self { plain_http, rewrites }.normalised()
    }

    /// Longest prefix first, so `docker.io/org/pkg=x` wins over `docker.io=y`.
    fn normalised(mut self) -> Self {
        self.rewrites.sort_by_key(|(from, _)| std::cmp::Reverse(from.len()));
        self
    }

    /// Apply the rewrites to a package reference, with or without the
    /// `oci://` scheme.
    pub fn rewrite(&self, reference: &str) -> String {
        let (scheme, rest) = match reference.strip_prefix(OCI_SCHEME) {
            Some(rest) => (OCI_SCHEME, rest),
            None => ("", reference),
        };
        for (from, to) in &self.rewrites {
            let from = from.strip_prefix(OCI_SCHEME).unwrap_or(from);
            if let Some(tail) = rest.strip_prefix(from) {
                // Only rewrite whole path segments: `docker.io/yuri` must not
                // match `docker.io/yurikrupnik`.
                if tail.is_empty() || tail.starts_with('/') {
                    let to = to.strip_prefix(OCI_SCHEME).unwrap_or(to);
                    return format!("{scheme}{to}{tail}");
                }
            }
        }
        reference.to_string()
    }

    fn client(&self) -> Client {
        if self.plain_http.is_empty() {
            return Client::default();
        }
        Client::new(ClientConfig {
            protocol: ClientProtocol::HttpsExcept(self.plain_http.clone()),
            ..Default::default()
        })
    }
}

fn split_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(str::to_string)
        .collect()
}

/// Resolves KCL packages into on-disk module directories.
///
/// The cache is content-addressed by layer digest, so it is safe to share
/// between processes and immune to republished tags.
pub struct Resolver {
    cache: PathBuf,
    registries: Registries,
}

/// A `[dependencies]` entry, with the default registry already filled in for
/// the bare-version form.
#[derive(Debug, PartialEq, Eq)]
enum Dep {
    Oci { url: String, tag: Option<String> },
    /// Already joined onto the depending module's root, but not canonicalised:
    /// the directory need not exist yet at parse time.
    Path(PathBuf),
}

/// How a package layer is encoded. KCL's own client only understands
/// [`Encoding::Tar`], which is the whole reason this module exists.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
enum Encoding {
    Tar,
    Gzip,
}

impl Resolver {
    /// Anonymous pulls over HTTPS, no rewrites.
    pub fn new(cache: PathBuf) -> Self {
        Self { cache, registries: Registries::default() }
    }

    pub fn with_registries(cache: PathBuf, registries: Registries) -> Self {
        Self { cache, registries: registries.normalised() }
    }

    /// Pull an OCI KCL package, returning the extracted module directory.
    pub fn pull(&self, url: &str, tag: Option<&str>) -> Result<PathBuf> {
        off_thread(|| {
            let rt = runtime()?;
            let client = self.registries.client();
            rt.block_on(self.fetch(&client, url, tag))
        })
    }

    /// Recursively resolve a module's `kcl.mod` `[dependencies]` into the
    /// `-E name=path` list KCL needs.
    pub fn resolve(&self, module_root: &Path) -> Result<Vec<ExternalPkg>> {
        off_thread(|| {
            let rt = runtime()?;
            let client = self.registries.client();
            rt.block_on(self.walk(&client, module_root))
        })
    }

    /// Breadth-first over the dependency graph, mirroring what the SDK does:
    /// a module's direct dependencies win over anything a transitive one
    /// brings in under the same name.
    async fn walk(&self, client: &Client, module_root: &Path) -> Result<Vec<ExternalPkg>> {
        let mut queue = VecDeque::from([module_root.to_path_buf()]);
        let mut visited: HashSet<PathBuf> = HashSet::new();
        let mut named: HashSet<String> = HashSet::new();
        let mut resolved: Vec<ExternalPkg> = Vec::new();

        while let Some(root) = queue.pop_front() {
            // Two modules sharing a dependency, or a genuine cycle, must not
            // make us walk (or download) the same module twice.
            if !visited.insert(root.clone()) {
                continue;
            }
            for (name, dep) in dependencies(&root)? {
                let path = match &dep {
                    Dep::Oci { url, tag } => self
                        .fetch(client, url, tag.as_deref())
                        .await
                        .with_context(|| {
                            format!("dependency {name:?} of {}/kcl.mod", root.display())
                        })?,
                    Dep::Path(path) => std::fs::canonicalize(path).with_context(|| {
                        format!(
                            "dependency {name:?} of {}/kcl.mod points at {}",
                            root.display(),
                            path.display()
                        )
                    })?,
                };
                queue.push_back(path.clone());
                // KCL identifiers cannot contain `-`, so `gcp-storage` is
                // written `import gcp_storage`; the compiler matches external
                // packages on that spelling.
                let pkg_name = name.replace('-', "_");
                if named.insert(pkg_name.clone()) {
                    resolved.push(ExternalPkg {
                        pkg_name,
                        pkg_path: path.display().to_string(),
                    });
                }
            }
        }
        Ok(resolved)
    }

    /// Download and extract one package, or hand back the cached copy.
    async fn fetch(&self, client: &Client, url: &str, tag: Option<&str>) -> Result<PathBuf> {
        // Rewrites apply to entry sources and transitive dependencies alike:
        // a Composition pointing at `docker.io/<org>/bucket-gcp` must be able
        // to resolve against a locally published build without editing the
        // committed manifest.
        let rewritten = self.registries.rewrite(url);
        let image = rewritten.strip_prefix(OCI_SCHEME).unwrap_or(&rewritten);
        let tag = tag.unwrap_or("latest");
        let reference = Reference::try_from(format!("{image}:{tag}"))
            .with_context(|| format!("not a pullable OCI reference: {rewritten}"))?;

        let (manifest, _) = client
            .pull_image_manifest(&reference, &RegistryAuth::Anonymous)
            .await
            .with_context(|| format!("fetching the manifest of {image}:{tag}"))?;
        let (layer, encoding) = package_layer(&manifest)
            .with_context(|| format!("{image}:{tag} is not a KCL package artifact"))?;

        // Keyed by layer digest rather than by tag: a republished tag hashes
        // differently, so it can never be served from a stale directory.
        let hex = layer
            .digest
            .split_once(':')
            .map(|(_, hex)| hex)
            .unwrap_or(&layer.digest);
        let dir = self
            .cache
            .join("packages")
            .join(sanitise(&format!(
                "{}/{}",
                reference.registry(),
                reference.repository()
            )))
            .join(sanitise(tag))
            .join(&hex[..hex.len().min(16)]);
        if let Some(root) = module_root(&dir) {
            return Ok(root);
        }

        let mut blob: Vec<u8> = Vec::with_capacity(layer.size.max(0) as usize);
        client
            .pull_blob(&reference, layer, &mut blob)
            .await
            .with_context(|| format!("downloading the package layer of {image}:{tag}"))?;
        verify(&blob, &layer.digest)?;

        let staging = staging_dir(&dir)?;
        match encoding {
            Encoding::Tar => tar::Archive::new(blob.as_slice()).unpack(&staging),
            Encoding::Gzip => tar::Archive::new(GzDecoder::new(blob.as_slice())).unpack(&staging),
        }
        .with_context(|| format!("unpacking the package layer of {image}:{tag}"))?;

        // Publish by rename so the digest directory only ever appears
        // complete: the cache-hit check above trusts that a `kcl.mod` under it
        // means the whole module is there, and a crash mid-unpack or a
        // concurrent pull must not be able to break that promise.
        match std::fs::rename(&staging, &dir) {
            Ok(()) => {}
            // Same digest, so whoever won the race extracted the same bytes.
            Err(_) if module_root(&dir).is_some() => {
                std::fs::remove_dir_all(&staging).ok();
            }
            Err(err) => {
                std::fs::remove_dir_all(&staging).ok();
                return Err(err)
                    .with_context(|| format!("publishing {} into the cache", dir.display()));
            }
        }
        module_root(&dir).ok_or_else(|| anyhow!("{image}:{tag} contains no kcl.mod"))
    }
}

/// Run `f` on a thread of its own.
///
/// The OCI client is async and `Runtime::block_on` panics if the calling
/// thread is already inside a runtime. Renders reach us either from a plain
/// sync CLI or from `spawn_blocking`, both of which are fine, but a dedicated
/// thread makes that independent of the caller — and turns a panic in the
/// resolver into an error rather than unwinding through the render.
fn off_thread<T: Send>(f: impl FnOnce() -> Result<T> + Send) -> Result<T> {
    std::thread::scope(|scope| {
        scope
            .spawn(f)
            .join()
            .map_err(|_| anyhow!("package resolution panicked"))?
    })
}

fn runtime() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("starting a runtime for the OCI client")
}

/// The sole layer of a KCL package artifact, plus how it is compressed.
fn package_layer(manifest: &OciImageManifest) -> Result<(&OciDescriptor, Encoding)> {
    let [layer] = manifest.layers.as_slice() else {
        bail!(
            "expected a single package layer, found {}",
            manifest.layers.len()
        );
    };
    let encoding = match layer.media_type.as_str() {
        IMAGE_LAYER_MEDIA_TYPE => Encoding::Tar,
        IMAGE_LAYER_GZIP_MEDIA_TYPE => Encoding::Gzip,
        other => bail!("unsupported layer media type {other:?}"),
    };
    Ok((layer, encoding))
}

/// The blob was requested by digest but nothing checked what came back, and
/// the cache is keyed by that digest: an unverified layer would be filed under
/// a name promising content it does not have.
fn verify(blob: &[u8], digest: &str) -> Result<()> {
    let Some(want) = digest.strip_prefix("sha256:") else {
        bail!("unsupported layer digest {digest:?}");
    };
    let got = hex(&Sha256::digest(blob));
    if got != want {
        bail!("layer digest mismatch: manifest says {want}, layer hashes to {got}");
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// A sibling of the final directory, so publishing is a rename inside one
/// filesystem, and unique per pull so two concurrent ones cannot share a tree.
fn staging_dir(dir: &Path) -> Result<PathBuf> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let parent = dir
        .parent()
        .ok_or_else(|| anyhow!("cache path has no parent: {}", dir.display()))?;
    let staging = parent.join(format!(
        ".staging-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::remove_dir_all(&staging).ok();
    std::fs::create_dir_all(&staging)
        .with_context(|| format!("creating {}", staging.display()))?;
    Ok(staging)
}

/// The directory holding the package's `kcl.mod`. The packages this repo pulls
/// tar their contents at the archive root — verified against
/// `docker.io/yurikrupnik/bucket-gcp:0.1.0` and `ghcr.io/kcl-lang/k8s:1.32.4`,
/// both of which put `kcl.mod` at the top — but other publishers wrap
/// everything in one directory, so a single level down is checked too.
fn module_root(dir: &Path) -> Option<PathBuf> {
    if dir.join("kcl.mod").is_file() {
        return Some(dir.to_path_buf());
    }
    std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|child| child.path())
        .find(|child| child.join("kcl.mod").is_file())
}

fn sanitise(component: &str) -> String {
    component
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// `oci://<registry>/<name>` for the bare `name = "<version>"` form.
fn default_url(name: &str) -> String {
    let registry = std::env::var("KCL_SRC_URL").unwrap_or_else(|_| DEFAULT_REGISTRY.to_string());
    let registry = registry.trim_end_matches('/');
    let registry = registry.strip_prefix(OCI_SCHEME).unwrap_or(registry);
    format!("{OCI_SCHEME}{registry}/{name}")
}

/// Parse one module's `[dependencies]`. A directory without a `kcl.mod` simply
/// has none: a `{ path = ... }` dependency is allowed to be a plain source
/// directory rather than a package of its own.
fn dependencies(module_root: &Path) -> Result<Vec<(String, Dep)>> {
    let manifest = module_root.join("kcl.mod");
    let text = match std::fs::read_to_string(&manifest) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err).with_context(|| format!("reading {}", manifest.display())),
    };
    let value = parse_manifest(&text).with_context(|| format!("parsing {}", manifest.display()))?;
    let Some(table) = value.get("dependencies").and_then(|d| d.as_table()) else {
        return Ok(Vec::new());
    };
    table
        .iter()
        .map(|(name, spec)| {
            let dep = dependency(name, spec, module_root)
                .with_context(|| format!("in {}", manifest.display()))?;
            Ok((name.clone(), dep))
        })
        .collect()
}

fn dependency(name: &str, spec: &toml::Value, module_root: &Path) -> Result<Dep> {
    let string = |key: &str| spec.get(key).and_then(|v| v.as_str()).map(str::to_string);
    match spec {
        // `name = "<version>"`.
        toml::Value::String(version) => Ok(Dep::Oci {
            url: default_url(name),
            tag: Some(version.clone()),
        }),
        toml::Value::Table(_) => {
            if spec.get("git").is_some() {
                bail!("dependency {name:?} uses an unsupported git source");
            }
            if let Some(path) = string("path") {
                return Ok(Dep::Path(module_root.join(path)));
            }
            // `version` names a tag in both the `{ oci = ..., version = ... }`
            // and the bare `{ version = ... }` form.
            let tag = string("tag").or_else(|| string("version"));
            match string("oci") {
                Some(url) => Ok(Dep::Oci { url, tag }),
                None if tag.is_some() => Ok(Dep::Oci {
                    url: default_url(name),
                    tag,
                }),
                None => bail!("dependency {name:?} names no oci, path or version source"),
            }
        }
        other => bail!("dependency {name:?} must be a version string or a table, got {other}"),
    }
}

/// `kcl.mod` files in this repo pick up junk from tooling — one of them ends
/// with a bare `kpm` token, which is not TOML at all. A strict parse is tried
/// first, and only if that fails are lines that cannot be TOML dropped, so a
/// real syntax error inside a real entry is still reported.
fn parse_manifest(text: &str) -> Result<toml::Value> {
    match toml::from_str::<toml::Value>(text) {
        Ok(value) => Ok(value),
        Err(strict) => {
            let salvaged = text
                .lines()
                .filter(|line| is_toml_ish(line))
                .collect::<Vec<_>>()
                .join("\n");
            toml::from_str::<toml::Value>(&salvaged).map_err(|_| anyhow!("{strict}"))
        }
    }
}

fn is_toml_ish(line: &str) -> bool {
    let line = line.trim();
    line.is_empty() || line.starts_with('#') || line.starts_with('[') || line.contains('=')
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scratch directory removed on drop. `kcl.mod` parsing reads from disk,
    /// so the tests need real files.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(label: &str) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let dir = std::env::temp_dir().join(format!(
                "kcl-render-deps-{label}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn module(&self, manifest: &str) -> PathBuf {
            std::fs::write(self.0.join("kcl.mod"), manifest).unwrap();
            self.0.clone()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).ok();
        }
    }

    fn registries(pairs: &[(&str, &str)]) -> Registries {
        Registries {
            plain_http: vec![],
            rewrites: pairs.iter().map(|(f, t)| (f.to_string(), t.to_string())).collect(),
        }
        .normalised()
    }

    #[test]
    fn rewrites_a_reference_prefix_and_keeps_the_scheme() {
        let r = registries(&[("docker.io/yurikrupnik", "kind-registry")]);
        assert_eq!(
            r.rewrite("oci://docker.io/yurikrupnik/bucket-gcp"),
            "oci://kind-registry/bucket-gcp"
        );
        assert_eq!(r.rewrite("docker.io/yurikrupnik/bucket-gcp"), "kind-registry/bucket-gcp");
        assert_eq!(r.rewrite("oci://docker.io/yurikrupnik"), "oci://kind-registry");
    }

    #[test]
    fn rewrites_only_whole_path_segments() {
        let r = registries(&[("docker.io/yuri", "kind-registry")]);
        assert_eq!(
            r.rewrite("oci://docker.io/yurikrupnik/bucket-gcp"),
            "oci://docker.io/yurikrupnik/bucket-gcp",
            "a prefix that stops mid-segment must not match"
        );
    }

    #[test]
    fn the_longest_matching_rewrite_wins() {
        let r = registries(&[
            ("docker.io", "mirror"),
            ("docker.io/yurikrupnik/bucket-gcp", "kind-registry/bucket-gcp-dev"),
        ]);
        assert_eq!(
            r.rewrite("oci://docker.io/yurikrupnik/bucket-gcp"),
            "oci://kind-registry/bucket-gcp-dev"
        );
        assert_eq!(r.rewrite("oci://docker.io/other/pkg"), "oci://mirror/other/pkg");
    }

    #[test]
    fn an_unmatched_reference_is_untouched() {
        let r = registries(&[("docker.io/yurikrupnik", "kind-registry")]);
        assert_eq!(r.rewrite("oci://ghcr.io/kcl-lang/k8s"), "oci://ghcr.io/kcl-lang/k8s");
        assert_eq!(Registries::default().rewrite("oci://a/b"), "oci://a/b");
    }

    #[test]
    fn env_lists_are_comma_separated_and_tolerate_spaces() {
        // Set/read through the same process env the function pod uses.
        unsafe {
            std::env::set_var(ENV_PLAIN_HTTP, "kind-registry, localhost:5001 ,");
            std::env::set_var(ENV_REWRITE, "docker.io/yurikrupnik=kind-registry,junk");
        }
        let r = Registries::from_env();
        unsafe {
            std::env::remove_var(ENV_PLAIN_HTTP);
            std::env::remove_var(ENV_REWRITE);
        }
        assert_eq!(r.plain_http, ["kind-registry", "localhost:5001"]);
        assert_eq!(r.rewrites, [("docker.io/yurikrupnik".to_string(), "kind-registry".to_string())]);
    }

    #[test]
    fn every_dependency_form_this_repo_uses_resolves() {
        let scratch = Scratch::new("forms");
        let root = scratch.module(
            r#"
[package]
name = "kclx-test"
version = "0.1.0"

[dependencies]
k8s = "1.32.4"
bucket-gcp = { oci = "oci://docker.io/yurikrupnik/bucket-gcp", tag = "0.1.0" }
redis-aws = { oci = "oci://docker.io/yurikrupnik/redis-aws", version = "0.0.1" }
gcp-storage = { path = "../../../providers/gcp-storage" }
konfig = { version = "0.11.0" }
"#,
        );
        let deps: std::collections::HashMap<String, Dep> =
            dependencies(&root).unwrap().into_iter().collect();

        assert_eq!(
            deps["k8s"],
            Dep::Oci {
                url: "oci://ghcr.io/kcl-lang/k8s".into(),
                tag: Some("1.32.4".into()),
            }
        );
        assert_eq!(
            deps["bucket-gcp"],
            Dep::Oci {
                url: "oci://docker.io/yurikrupnik/bucket-gcp".into(),
                tag: Some("0.1.0".into()),
            }
        );
        // `version` is a tag by another name.
        assert_eq!(
            deps["redis-aws"],
            Dep::Oci {
                url: "oci://docker.io/yurikrupnik/redis-aws".into(),
                tag: Some("0.0.1".into()),
            }
        );
        assert_eq!(
            deps["konfig"],
            Dep::Oci {
                url: "oci://ghcr.io/kcl-lang/konfig".into(),
                tag: Some("0.11.0".into()),
            }
        );
        assert_eq!(
            deps["gcp-storage"],
            Dep::Path(root.join("../../../providers/gcp-storage"))
        );
    }

    #[test]
    fn a_bare_kpm_token_does_not_fail_the_parse() {
        let scratch = Scratch::new("junk");
        let root = scratch.module(
            "[package]\nname = \"apigateway-aws\"\n\n[dependencies]\nk8s = \"1.32.4\"\nkpm\n",
        );
        let deps = dependencies(&root).unwrap();
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].0, "k8s");
    }

    #[test]
    fn a_real_syntax_error_is_still_reported() {
        let scratch = Scratch::new("broken");
        let root = scratch.module("[dependencies]\nk8s = \n");
        assert!(dependencies(&root).is_err());
    }

    #[test]
    fn git_dependencies_are_rejected_by_name() {
        let scratch = Scratch::new("git");
        let root = scratch.module(
            "[dependencies]\nhelloworld = { git = \"https://github.com/kcl-lang/helloworld\", tag = \"0.1.0\" }\n",
        );
        let err = format!("{:#}", dependencies(&root).unwrap_err());
        assert!(err.contains("helloworld"), "{err}");
        assert!(err.contains("git"), "{err}");
    }

    #[test]
    fn a_module_without_dependencies_resolves_to_nothing() {
        let scratch = Scratch::new("bare");
        let root = scratch.module("[package]\nname = \"k8s\"\nversion = \"1.32.4\"\n");
        assert!(dependencies(&root).unwrap().is_empty());
        // A `{ path = ... }` target need not be a package at all.
        assert!(dependencies(&scratch.0.join("missing")).unwrap().is_empty());
    }

    #[test]
    fn a_sourceless_dependency_table_is_an_error() {
        let scratch = Scratch::new("sourceless");
        let root = scratch.module("[dependencies]\nmystery = { registry = \"nowhere\" }\n");
        assert!(dependencies(&root).is_err());
    }

    #[test]
    fn package_layers_accept_both_tar_encodings() {
        let layer = |media_type: &str| OciImageManifest {
            layers: vec![OciDescriptor {
                media_type: media_type.into(),
                digest: "sha256:00".into(),
                ..Default::default()
            }],
            ..Default::default()
        };

        let tar = layer(IMAGE_LAYER_MEDIA_TYPE);
        assert_eq!(package_layer(&tar).unwrap().1, Encoding::Tar);
        let gzip = layer(IMAGE_LAYER_GZIP_MEDIA_TYPE);
        assert_eq!(package_layer(&gzip).unwrap().1, Encoding::Gzip);

        let other = layer("application/vnd.docker.image.rootfs.diff.tar.gzip");
        let err = format!("{}", package_layer(&other).unwrap_err());
        assert!(err.contains("application/vnd.docker.image.rootfs.diff.tar.gzip"), "{err}");
    }

    #[test]
    fn a_mismatched_layer_digest_is_refused() {
        let want = hex(&Sha256::digest(b"kcl"));
        verify(b"kcl", &format!("sha256:{want}")).unwrap();
        assert!(verify(b"not kcl", &format!("sha256:{want}")).is_err());
        assert!(verify(b"kcl", "md5:whatever").is_err());
    }

    /// Hits docker.io, so it is not part of the default run.
    #[test]
    #[ignore = "requires network access to docker.io"]
    fn a_gzipped_package_pulls_and_resolves() {
        let scratch = Scratch::new("pull");
        let resolver = Resolver::new(scratch.0.clone());
        let root = resolver
            .pull("oci://docker.io/yurikrupnik/bucket-gcp", Some("0.1.0"))
            .unwrap();
        assert!(root.join("kcl.mod").is_file());
        let deps = resolver.resolve(&root).unwrap();
        assert!(deps.iter().any(|pkg| pkg.pkg_name == "k8s"), "{deps:?}");
    }
}
