//! Where the KCL comes from, and how it turns into `ExecProgramArgs` inputs.
//!
//! Three shapes cover every caller we have: a working-tree path (the CLI and
//! `crossplane render` against a checkout), inline source (a Composition that
//! carries its KCL in `spec.source`), and an OCI package (the published
//! `oci://docker.io/<org>/<pkg>?tag=x.y.z` sources every Composition in
//! `packages/cloud/**` uses).

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};

/// The KCL program to execute.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// A `.k` file, or a directory compiled as a package.
    Path(PathBuf),
    /// Source text. Written to `dir/main.k` under a caller-owned directory
    /// because KCL derives the package root from a real path on disk: passing
    /// only `k_code_list` breaks as soon as the program imports an external
    /// package.
    Inline(String),
    /// An OCI-published KCL package, pulled into the local module cache.
    Oci { url: String, tag: Option<String> },
}

impl Source {
    /// Parse the `spec.source` grammar `function-kcl` accepts, minus git/http:
    /// `oci://host/repo[?tag=v]`, a filesystem path, or inline KCL.
    pub fn parse(spec: &str) -> Self {
        let trimmed = spec.trim();
        if let Some(rest) = trimmed.strip_prefix("oci://") {
            let (repo, tag) = match rest.split_once("?tag=") {
                Some((repo, tag)) => (repo, Some(tag.to_string())),
                None => (rest, None),
            };
            return Source::Oci { url: format!("oci://{repo}"), tag };
        }
        // Inline KCL always contains an assignment or an import; a path never
        // contains a newline. Anything else is treated as a path so a typo
        // fails loudly with "no such file" instead of as a syntax error.
        if trimmed.contains('\n') || trimmed.contains('=') {
            Source::Inline(trimmed.to_string())
        } else {
            Source::Path(PathBuf::from(trimmed))
        }
    }
}

/// A source materialised on disk, ready to hand to the KCL runtime.
#[derive(Debug, Clone)]
pub struct Entry {
    /// `ExecProgramArgs::work_dir` — what `file.workdir()` returns in KCL.
    pub work_dir: PathBuf,
    /// `ExecProgramArgs::k_filename_list`.
    pub files: Vec<String>,
    /// Directory holding the `kcl.mod` whose `[dependencies]` must be
    /// resolved, when there is one.
    pub module_root: Option<PathBuf>,
}

/// Nearest ancestor (inclusive) holding a `kcl.mod`.
fn module_root(from: &Path) -> Option<PathBuf> {
    let mut cur = Some(from);
    while let Some(dir) = cur {
        if dir.join("kcl.mod").is_file() {
            return Some(dir.to_path_buf());
        }
        cur = dir.parent();
    }
    None
}

impl Source {
    /// Materialise the source. `scratch` is a directory the caller owns and
    /// cleans up; it is only touched for [`Source::Inline`] and
    /// [`Source::Oci`].
    pub fn materialise(&self, scratch: &Path) -> Result<Entry> {
        match self {
            Source::Path(path) => {
                let abs = fs::canonicalize(path)
                    .with_context(|| format!("KCL source not found: {}", path.display()))?;
                let work_dir = if abs.is_dir() {
                    abs.clone()
                } else {
                    abs.parent()
                        .ok_or_else(|| anyhow!("source has no parent directory: {}", abs.display()))?
                        .to_path_buf()
                };
                Ok(Entry {
                    files: vec![abs.display().to_string()],
                    module_root: module_root(&work_dir),
                    work_dir,
                })
            }
            Source::Inline(code) => {
                fs::create_dir_all(scratch)?;
                let file = scratch.join("main.k");
                fs::write(&file, code)?;
                Ok(Entry {
                    work_dir: scratch.to_path_buf(),
                    files: vec![file.display().to_string()],
                    module_root: module_root(scratch),
                })
            }
            Source::Oci { .. } => {
                bail!("OCI sources must be resolved through Engine::pull")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_oci_with_and_without_tag() {
        assert_eq!(
            Source::parse("oci://docker.io/yurikrupnik/bucket-aws?tag=0.1.0"),
            Source::Oci {
                url: "oci://docker.io/yurikrupnik/bucket-aws".into(),
                tag: Some("0.1.0".into())
            }
        );
        assert_eq!(
            Source::parse("oci://docker.io/yurikrupnik/bucket-aws"),
            Source::Oci { url: "oci://docker.io/yurikrupnik/bucket-aws".into(), tag: None }
        );
    }

    #[test]
    fn parses_paths_and_inline() {
        assert_eq!(Source::parse("packages/cloud/bucket/aws"), Source::Path("packages/cloud/bucket/aws".into()));
        assert_eq!(Source::parse("items = [{a = 1}]"), Source::Inline("items = [{a = 1}]".into()));
    }
}
