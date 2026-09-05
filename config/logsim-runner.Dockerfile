# Minimal image for running log-simulators inside Docker.
# Adds git to the official uv image so uvx can install from git+https URLs.
FROM ghcr.io/astral-sh/uv:0.5-python3.12-bookworm-slim

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
