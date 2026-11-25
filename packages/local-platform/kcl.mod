[package]
name = "local-platform"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
k8s = "1.32.4"
app = { path = "../app" }
cluster = { path = "../cluster" }
manager = { path = "../manager" }
argocd = { path = "../providers/argocd" }
cnpg = { path = "../providers/cnpg" }
