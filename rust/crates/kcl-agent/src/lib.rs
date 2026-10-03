//! An LLM agent over the same [`kcl_operator::Service`] the `kclx` CLI and REST
//! API already use: the model is handed a fixed set of tools that read kinds,
//! objects, composed Crossplane resources and events, dry-run a `KclModule`
//! render or a server-side apply, and — only when the caller approved the run —
//! write or delete. Nothing else reaches the cluster. Errors split two ways: a
//! cluster refusal or a bad tool argument is fed back to the model as a tool
//! result so it can correct itself, while a model, transport or configuration
//! failure aborts the run.

pub mod agent;
pub mod api;
pub mod error;
pub mod llm;
pub mod tools;

pub use agent::{Agent, Run, RunRequest, Step};
pub use error::Error;
pub use llm::{Llm, LlmConfig};
pub use tools::Toolbox;
