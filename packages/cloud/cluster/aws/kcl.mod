[package]
name = "cluster-aws"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
aws-eks = { path = "../../../providers/aws-eks" }
aws-iam = { path = "../../../providers/aws-iam" }
k8s = "1.32.4"
