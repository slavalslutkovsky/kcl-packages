[package]
name = "cncf"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
app = { path = "../app" }
cert-manager = { path = "../providers/cert-manager" }
k8s = "1.32.4"
manager = { path = "../manager" }
