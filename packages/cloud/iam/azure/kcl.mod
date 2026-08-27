[package]
name = "iam-azure"
edition = "v0.12.3"
version = "0.0.1"

[dependencies]
azure-managedidentity = { path = "../../../providers/azure-managedidentity" }
azure-authorization = { path = "../../../providers/azure-authorization" }
k8s = "1.32.4"
