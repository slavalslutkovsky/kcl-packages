[package]
name = "network-gcp"
edition = "v0.12.3"
version = "0.1.6"

[dependencies]
gcp-compute = { path = "../../../providers/gcp-compute" }
gcp-servicenetworking = { path = "../../../providers/gcp-servicenetworking" }
k8s = "1.32.4"
network-xrd = { path = "../xrd" }
