[package]
name = "mgmt-gcp"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
gcp-cloudplatform = { path = "../../../providers/gcp-cloudplatform" }
gcp-compute = { path = "../../../providers/gcp-compute" }
gcp-container = { path = "../../../providers/gcp-container" }
gcp-kms = { path = "../../../providers/gcp-kms" }
gcp-sql = { path = "../../../providers/gcp-sql" }
gcp-artifact = { path = "../../../providers/gcp-artifact" }
gcp-storage = { path = "../../../providers/gcp-storage" }
gcp-dns = { path = "../../../providers/gcp-dns" }
gcp-secretmanager = { path = "../../../providers/gcp-secretmanager" }
gcp-binaryauthorization = { path = "../../../providers/gcp-binaryauthorization" }
k8s = "1.32.4"
