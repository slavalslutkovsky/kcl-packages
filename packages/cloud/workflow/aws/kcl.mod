[package]
name = "workflow-aws"
edition = "v0.12.3"
version = "0.1.0"

[dependencies]
aws-sfn = { path = "../../../providers/aws-sfn" }
aws-iam = { path = "../../../providers/aws-iam" }
k8s = "1.32.4"
