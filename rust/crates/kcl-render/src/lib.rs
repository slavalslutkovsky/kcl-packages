//! Runtime KCL rendering, plus the Crossplane desired-state conversion built
//! on top of it.
//!
//! The crate exists so that exactly one code path renders KCL in this repo:
//!
//! ```text
//!   kclx render <source> --param k=v      \
//!                                          >-- kcl_render::Engine::render
//!   kclx function  (FunctionRunnerService) /
//! ```
//!
//! [`engine`] runs the program; [`deps`] resolves the packages it imports;
//! [`compose`] turns the resulting `items` into composed resources and
//! composite patches. Neither knows about gRPC or clap, so a third front end
//! (an HTTP endpoint taking query parameters, say) is a matter of building a
//! [`engine::Request`].

pub mod compose;
pub mod deps;
pub mod engine;
pub mod source;

pub use compose::{Composed, Desired, Ready, RequiredResource, Requirements, SelectorMatch, Target};
pub use engine::{Engine, Options, Rendered, Request};
pub use source::Source;

use anyhow::{Context, Result};
use serde_json::Value;

/// Parse a YAML *or* JSON document (YAML is a superset, so one parser does
/// both) into a JSON value. Used for `--oxr`, `--params-file` and friends.
pub fn parse_document(text: &str) -> Result<Value> {
    serde_yaml_ng::from_str(text).context("input is neither valid YAML nor JSON")
}

/// Serialise as a YAML document stream: one `---`-separated document per item,
/// which is what `kubectl apply -f -` and `crossplane render` expect.
pub fn to_yaml_stream(items: &[Value]) -> Result<String> {
    let mut out = String::new();
    for item in items {
        out.push_str("---\n");
        out.push_str(&serde_yaml_ng::to_string(item)?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn yaml_and_json_documents_both_parse() {
        assert_eq!(parse_document("a: 1").unwrap(), json!({"a": 1}));
        assert_eq!(parse_document(r#"{"a": 1}"#).unwrap(), json!({"a": 1}));
    }

    #[test]
    fn yaml_stream_separates_documents() {
        let out = to_yaml_stream(&[json!({"a": 1}), json!({"b": 2})]).unwrap();
        assert_eq!(out, "---\na: 1\n---\nb: 2\n");
    }
}
