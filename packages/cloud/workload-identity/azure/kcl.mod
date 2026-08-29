[package]
name = "workload-identity-azure"
edition = "v0.12.3"
version = "0.1.2"

[dependencies]
azure-managedidentity = { path = "../../../providers/azure-managedidentity" }
azure-authorization = { path = "../../../providers/azure-authorization" }
k8s = "1.32.4"
