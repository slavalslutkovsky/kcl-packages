[package]
name = "landing-gcp"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
gcp-storage = { path = "../../../providers/gcp-storage" }
gcp-compute = { path = "../../../providers/gcp-compute" }
k8s = "1.32.4"
