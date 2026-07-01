import .kind

# Render a single Kind cluster config document at the root (no `items:` wrapper),
# so `kind create cluster --config` can consume `kcl run` output directly.
kind.Cluster {}
