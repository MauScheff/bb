# syntax=docker/dockerfile:1.7

FROM rust:1.88-bookworm AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake libclang-dev \
  && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY backend/runtime/Cargo.toml backend/runtime/Cargo.toml
COPY backend/relay-protocol/Cargo.toml backend/relay-protocol/Cargo.toml
COPY backend/relay/Cargo.toml backend/relay/Cargo.toml

COPY backend/runtime backend/runtime
COPY backend/relay-protocol backend/relay-protocol
COPY backend/infra/self-hosted backend/infra/self-hosted

RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  --mount=type=cache,target=/src/target \
  cargo build --release -p beepbeep-runtime --bin beepbeep-runtime \
  && mkdir -p /out \
  && cp target/release/beepbeep-runtime /out/beepbeep-runtime

FROM debian:bookworm-slim

ARG UCM_LINUX_TARBALL_URL="https://github.com/unisonweb/unison/releases/latest/download/ucm-linux-x64.tar.gz"

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl tar \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "$UCM_LINUX_TARBALL_URL" -o /tmp/ucm.tar.gz \
  && mkdir -p /tmp/ucm \
  && tar -xzf /tmp/ucm.tar.gz -C /tmp/ucm \
  && find /tmp/ucm -type f -name ucm -perm -111 -exec cp {} /usr/local/bin/ucm \; -quit \
  && test -x /usr/local/bin/ucm \
  && rm -rf /tmp/ucm /tmp/ucm.tar.gz

COPY --from=builder /out/beepbeep-runtime /usr/local/bin/beepbeep-runtime
COPY backend/infra/vm/build/kernel /app/kernel

ENV TURBO_REPO_ROOT=/app
ENV TURBO_KERNEL_USE_DIRENV=0
ENV TURBO_KERNEL_UCM=/usr/local/bin/ucm
ENV TURBO_KERNEL_RUN_MODE=compiled
ENV TURBO_KERNEL_COMPILED_DIR=/app/kernel
ENV TURBO_KERNEL_WORKER_MODE=per-command

WORKDIR /app

CMD ["/usr/local/bin/beepbeep-runtime"]
