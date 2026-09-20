[package]
name = "organization-gcp"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
gcp-cloudplatform = { path = "../../../providers/gcp-cloudplatform" }
gcp-orgpolicy = { path = "../../../providers/gcp-orgpolicy" }
k8s = "1.32.4"
