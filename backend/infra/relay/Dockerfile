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

COPY backend/relay-protocol backend/relay-protocol
COPY backend/relay backend/relay

RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  --mount=type=cache,target=/src/target \
  cargo build --release -p beepbeep-relay --bin beepbeep-relay \
  && mkdir -p /out \
  && cp target/release/beepbeep-relay /out/beepbeep-relay

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/beepbeep-relay /usr/local/bin/beepbeep-relay

CMD ["/usr/local/bin/beepbeep-relay"]
