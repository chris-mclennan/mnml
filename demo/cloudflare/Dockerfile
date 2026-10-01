# The hosted demo's image: demo/Dockerfile's image, built for linux/amd64
# by ./build-image.sh (Cloudflare Containers run amd64 only), with the
# attract runner on a TCP port — the Durable Object reaches the container
# on 7681 (`defaultPort`); with `enableInternet = false` nothing else can,
# and nothing in the container can reach out.
#
# wrangler builds this file (`wrangler dev`, `wrangler deploy`) and pushes
# the result; the base is local, so ./build-image.sh runs first.
ARG BASE=mnml-demo:cf-amd64
FROM ${BASE}
ENV MNML_DEMO_LISTEN=tcp:0.0.0.0:7681
