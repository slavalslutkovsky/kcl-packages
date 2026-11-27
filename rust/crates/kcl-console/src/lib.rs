//! Backend for the multi-cloud console (`apps/console`), whose single-spa
//! micro frontends the shluviza-wrokspace host (`apps/console-host`) loads.
//!
//! Each portable XRD in `packages/cloud` gets a micro frontend; this crate
//! serves their data. A domain aggregates two kinds of source into one row
//! per real resource:
//!
//! * the Crossplane composites in the kubeconfig's cluster ([`k8s`]), and
//! * each cloud's own inventory, through its CLI ([`cloud`]),
//!
//! so a bucket shows whether Crossplane manages it, whether the cloud
//! confirms it exists, and which cloud buckets nothing manages yet.

pub mod api;
pub mod cloud;
pub mod k8s;
pub mod model;
