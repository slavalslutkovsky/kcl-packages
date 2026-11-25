[package]
name = "app"
edition = "v0.12.3"
version = "0.3.1"

[dependencies]
chaos-mesh = { path = "../providers/chaos-mesh" }
external-secrets = "0.18.2"
gateway-api = { path = "../providers/gateway-api" }
k8s = "1.32.4"
keda = "0.1.3"
litmus = { path = "../providers/litmus" }
prometheus-operator = { path = "../providers/prometheus-operator" }
