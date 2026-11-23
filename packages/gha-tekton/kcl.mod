[package]
name = "gha-tekton"
edition = "v0.12.3"
version = "0.1.0"
description = "GitHub Actions workflow in, Tekton Pipelines-as-Code PipelineRun out"

[dependencies]
tekton = { path = "../providers/tekton" }
k8s = "1.32.4"
