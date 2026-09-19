# syntax=docker/dockerfile:1
#
# Lapce - containerized build.
#
# Stages:
#   toolchain  : Rust toolchain + all native build dependencies
#   builder    : compiles the `lapce` executable into /out/lapce
#   export     : scratch stage containing only /lapce (use with `--output`)
#   runtime    : slim Debian image able to run the GUI binary
#
# Typical usage (see docker-compose.yml):
#   docker build --target export --output type=local,dest=./target/docker .
#   docker build --target runtime -t lapce:local .
#
# Build args:
#   RUST_VERSION       Rust image tag used for the builder (default: 1)
#   DEBIAN_CODENAME    Debian codename for the builder base (default: bookworm)
#   CARGO_PROFILE      Cargo profile to compile (default: release-lto)
#   CARGO_BUILD_JOBS   Parallel rustc jobs (default: 8, keeps RAM usage sane)

ARG RUST_VERSION=1
ARG DEBIAN_CODENAME=bookworm

# ---------------------------------------------------------------------------
# toolchain: toolchain + native dependencies, without any application source.
# ---------------------------------------------------------------------------
FROM rust:${RUST_VERSION}-${DEBIAN_CODENAME} AS toolchain

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_TERM_COLOR=always \
    CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

# Native dependencies required to build Lapce on GNU/Linux.
# Mirrors `make ubuntu-deps` plus tooling the vendored C libraries need.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
        bash clang lld llvm file cmake make perl pkg-config curl git ca-certificates \
        libxkbcommon-x11-dev libvulkan-dev libwayland-dev xorg-dev \
        libxcb-shape0-dev libxcb-xfixes0-dev libgtk-3-dev \
        libwebkit2gtk-4.1-dev \
        libssl-dev zlib1g-dev libzstd-dev libfontconfig1-dev && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# builder: fetch dependencies, then compile the executable.
# ---------------------------------------------------------------------------
FROM toolchain AS builder

WORKDIR /source

# Full source tree (honours .dockerignore).
COPY . .

# Warm the Cargo caches. The registry/git caches are BuildKit cache mounts, so
# this is cheap on rebuilds even though it re-runs after source changes.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    cargo fetch --locked

ARG CARGO_PROFILE=release-lto
ARG CARGO_BUILD_JOBS=8

ENV CARGO_PROFILE=${CARGO_PROFILE} \
    CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}

# The target directory lives in a BuildKit cache, so rebuilds are incremental
# while the resulting image stays small (only /out/lapce is committed).
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/source/target,sharing=locked \
    set -euxo pipefail; \
    cargo build --locked --profile "${CARGO_PROFILE}" --bin lapce; \
    install -Dm755 "/source/target/${CARGO_PROFILE}/lapce" /out/lapce; \
    file /out/lapce; \
    ls -lh /out/lapce; \
    /out/lapce --version || true

# ---------------------------------------------------------------------------
# export: bare stage holding only the executable, for `--output type=local`.
# ---------------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /out/lapce /lapce

# ---------------------------------------------------------------------------
# runtime: minimal image that can launch the produced GUI binary.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_CODENAME}-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates fontconfig fonts-dejavu-core zlib1g \
        libgtk-3-0 libvulkan1 libgl1 libegl1 \
        libwebkit2gtk-4.1-0 \
        mesa-vulkan-drivers libgl1-mesa-dri \
        libxkbcommon0 libxkbcommon-x11-0 \
        libwayland-client0 libwayland-cursor0 libwayland-egl1 \
        libx11-6 libx11-xcb1 libxrender1 libxext6 \
        libxcb1 libxcb-shape0 libxcb-xfixes0 libxcb-randr0 libxcb-render0 \
        libxcb-shm0 libxcb-xkb1 libxcb-util1 libxcb-icccm4 libxcb-image0 \
        libxcb-keysyms1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/lapce /usr/local/bin/lapce

ENTRYPOINT ["/usr/local/bin/lapce"]
