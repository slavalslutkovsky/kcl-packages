[package]
name = "network-aws"
edition = "v0.12.3"
version = "0.1.3"

[dependencies]
aws-ec2 = { path = "../../../providers/aws-ec2" }
aws-elasticache = { path = "../../../providers/aws-elasticache" }
aws-rds = { path = "../../../providers/aws-rds" }
k8s = "1.32.4"
