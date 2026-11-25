[package]
name = "landingzone-gcp"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
k8s = "1.32.4"
landingzone-xrd = { path = "../xrd", version = "0.1.0" }
landingzone-contract = { path = "../contract", version = "0.1.0" }
network-xrd = { path = "../../network/xrd", version = "0.1.0" }
hubspoke-xrd = { path = "../../hubspoke/xrd", version = "0.1.1" }
kms-xrd = { path = "../../kms/xrd", version = "0.1.1" }
