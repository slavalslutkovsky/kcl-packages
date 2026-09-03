[package]
name = "component-flux"
edition = "v0.12.3"
version = "0.1.2"

[dependencies]
flux-helm = { path = "../../../providers/flux-helm" }
flux-kustomize = { path = "../../../providers/flux-kustomize" }
flux-source = { path = "../../../providers/flux-source" }
