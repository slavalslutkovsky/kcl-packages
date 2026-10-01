[package]
name = "app"
edition = "v0.12.3"
version = "0.1.4"

[dependencies]
chaos-mesh = { path = "../providers/chaos-mesh" }
external-secrets = "0.18.2"
k8s = "1.32.4"
keda = "0.1.3"
prometheus-operator = { path = "../providers/prometheus-operator" }
