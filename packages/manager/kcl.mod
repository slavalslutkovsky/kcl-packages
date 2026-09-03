[package]
name = "manager"
edition = "v0.12.3"
version = "0.1.3"

[dependencies]
k8s = "1.32.4"
app = { path = "../app" }
cert-manager = { path = "../providers/cert-manager" }
chaos-mesh = { path = "../providers/chaos-mesh" }
flux-helm = { path = "../providers/flux-helm" }
flux-source = { path = "../providers/flux-source" }
