[package]
name = "landing-aws"
edition = "v0.12.3"
version = "0.1.1"

[dependencies]
aws-s3 = { path = "../../../providers/aws-s3" }
aws-cloudfront = { path = "../../../providers/aws-cloudfront" }
aws-acm = { path = "../../../providers/aws-acm" }
k8s = "1.32.4"
