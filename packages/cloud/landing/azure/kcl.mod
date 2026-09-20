[package]
name = "landing-azure"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
azure-storage = { path = "../../../providers/azure-storage" }
azure-cdn = { path = "../../../providers/azure-cdn" }
k8s = "1.32.4"
