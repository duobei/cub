# Multi-stage build for cub
# Stage 1: Build
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y curl git gcc && rm -rf /var/lib/apt/lists/*

# Install MoonBit
RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
ENV PATH="/root/.moon/bin:${PATH}"

WORKDIR /app
COPY moon.mod.json .
COPY src/ src/

# Install dependencies and build
RUN moon update && moon build --target native

# Stage 2: Runtime
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y curl git bash && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/_build/native/debug/build/main/main.exe /usr/local/bin/cub

# Default workspace
RUN mkdir -p /workspace
WORKDIR /workspace

ENTRYPOINT ["cub"]
