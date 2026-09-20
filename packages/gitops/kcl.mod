[package]
name = "gitops"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
k8s = "1.32.4"
app = { path = "../app" }
flux-source = { path = "../providers/flux-source" }
flux-kustomize = { path = "../providers/flux-kustomize" }
