[package]
name = "bucket-gcp"
edition = "v0.12.3"
version = "0.1.6"

[dependencies]
gcp-storage = { path = "../../../providers/gcp-storage" }
federation = { path = "../../federation" }
k8s = "1.32.4"
