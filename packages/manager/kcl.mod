[package]
name = "manager"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
k8s = "1.32.4"
app = { path = "../app" }
chaos-mesh = { path = "../providers/chaos-mesh" }
flux-helm = { path = "../providers/flux-helm" }
flux-source = { path = "../providers/flux-source" }
