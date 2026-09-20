[package]
name = "pricing"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
app = { path = "../../app" }
cluster-aws = { path = "../../cloud/cluster/aws" }
cluster-azure = { path = "../../cloud/cluster/azure" }
cluster-gcp = { path = "../../cloud/cluster/gcp" }
postgres-aws = { path = "../../cloud/postgres/aws" }
postgres-azure = { path = "../../cloud/postgres/azure" }
postgres-gcp = { path = "../../cloud/postgres/gcp" }
vm-aws = { path = "../../cloud/vm/aws" }
vm-azure = { path = "../../cloud/vm/azure" }
vm-gcp = { path = "../../cloud/vm/gcp" }
