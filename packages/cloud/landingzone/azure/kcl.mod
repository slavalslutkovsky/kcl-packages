[package]
name = "landingzone-azure"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
k8s = "1.32.4"
landingzone-xrd = { path = "../xrd" }
landingzone-contract = { path = "../contract" }
network-xrd = { path = "../../network/xrd" }
hubspoke-xrd = { path = "../../hubspoke/xrd" }
kms-xrd = { path = "../../kms/xrd" }
