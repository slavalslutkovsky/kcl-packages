[package]
name = "backup-velero"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
velero = { path = "../../../providers/velero" }
k8s = "1.32.4"
