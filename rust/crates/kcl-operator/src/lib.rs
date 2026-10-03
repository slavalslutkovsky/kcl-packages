//! `KclModule` operator, and the two front ends built on top of it.
//!
//! ```text
//!                    ┌──────────────────────────────────────┐
//!  kclx operator ───▶│ controller  watch → render → apply   │
//!                    │ apply       discovery, SSA, prune    │
//!  kclx api ────────▶│ service     list/get/apply/delete    │──▶ API server
//!  kclx module ─────▶│             preview (no cluster I/O) │
//!                    └──────────────────────────────────────┘
//!                                    kcl_render::Engine
//! ```
//!
//! The controller is the only component that writes rendered objects. The
//! CLI and the REST API share [`service::Service`], so `kclx module apply -f`
//! and `PUT /v1/modules/{ns}/{name}` are the same code path with different
//! transports — and neither can drift from what the controller then does,
//! because all three render through the one [`kcl_render::Engine`].

pub mod api;
pub mod apply;
pub mod controller;
pub mod crd;
pub mod error;
pub mod plan;
pub mod service;

pub use crd::{KclModule, KclModuleSpec, KclModuleStatus, RenderOptions, ResourceRef};
pub use error::Error;
pub use service::Service;
