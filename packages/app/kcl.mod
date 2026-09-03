[package]
name = "app"
edition = "v0.12.3"
version = "0.1.4"

[dependencies]
k8s = "1.32.4"
external-secrets = "0.18.2"
keda = "0.1.3"
chaos-mesh = { path = "../providers/chaos-mesh" }
