[package]
name = "bucket-azure"
edition = "v0.12.3"
version = "0.1.5"

[dependencies]
azure-storage = { path = "../../../providers/azure-storage" }
azure-managedidentity = { path = "../../../providers/azure-managedidentity" }
azure-authorization = { path = "../../../providers/azure-authorization" }
federation = { path = "../../federation" }
k8s = "1.32.4"
