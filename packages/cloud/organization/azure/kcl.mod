[package]
name = "organization-azure"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
azure-management = { path = "../../../providers/azure-management" }
azure-authorization = { path = "../../../providers/azure-authorization" }
k8s = "1.32.4"
