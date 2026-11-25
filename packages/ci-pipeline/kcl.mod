[package]
name = "ci-pipeline"
edition = "v0.12.3"
version = "0.1.1"
description = "One typed container-image pipeline (mirrored base images, pluggable scanners) rendered as Cloud Build config, Crossplane Cloud Build Triggers and GitHub Actions"

[dependencies]
gcp-cloudbuild = { path = "../providers/gcp-cloudbuild" }
k8s = "1.32.4"
