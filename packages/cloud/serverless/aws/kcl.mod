[package]
name = "serverless-aws"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
aws-lambda = { path = "../../../providers/aws-lambda" }
aws-iam = { path = "../../../providers/aws-iam" }
k8s = "1.32.4"
