# Runtime image for the composition function (`kclx function`).
#
# The KCL runtime is pure Rust since KCL 0.10 (the LLVM backend is gone), so
# unlike `kcllang/crossplane-kcl` this image needs no KCL native assets and no
# `kcl` binary — just the static-ish Rust binary on a distroless base.
#
# Build one image per architecture and let `crossplane xpkg push` join them:
#   docker buildx build --platform linux/amd64 -t ghcr.io/<org>/function-kclx-runtime:amd64 rust
FROM rust:1-slim-bookworm AS build

# git: the KCL Rust SDK is a git dependency (it is not published on crates.io).
# gcc/libc6-dev: `ring`, via the OCI client used to pull KCL packages.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git gcc libc6-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates crates
# --locked: kcl-lang/lib depends on kcl-lang/kcl by branch, so an unlocked
# build silently follows upstream main.
RUN cargo build --release --locked -p kclx

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/kclx /kclx
# Pulled KCL packages and inline sources land here; must be writable by
# nonroot, and is deliberately not a volume so the cache dies with the pod.
ENV KCLX_CACHE_DIR=/tmp/kclx
EXPOSE 9443
ENTRYPOINT ["/kclx", "function"]
