[package]
name = "bucket-aws"
edition = "v0.12.3"
version = "0.1.6"

[dependencies]
aws-iam = { path = "../../../providers/aws-iam" }
aws-s3 = { path = "../../../providers/aws-s3" }
federation = { path = "../../federation" }
k8s = "1.32.4"
