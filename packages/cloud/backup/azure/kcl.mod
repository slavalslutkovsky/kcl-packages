[package]
name = "backup-azure"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
azure-dataprotection = { path = "../../../providers/azure-dataprotection" }
azure-containerservice = { path = "../../../providers/azure-containerservice" }
azure-authorization = { path = "../../../providers/azure-authorization" }
k8s = "1.32.4"
