FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99

# Set by buildx for each platform.
ARG TARGETOS
ARG TARGETARCH

LABEL org.opencontainers.image.title="hello-mondoo" \
      org.opencontainers.image.description="Hello from Mondoo Engineer!" \
      org.opencontainers.image.source="https://github.com/clickbg/pe-challenge-p2-container" \
      org.opencontainers.image.licenses="BSD-2-Clause"

# Binaries are downloaded and signature-checked by scripts/fetch-release.sh
# before the build. Nothing is fetched from inside the Dockerfile.
COPY --chmod=0555 dist/hello-mondoo_${TARGETOS}_${TARGETARCH} /usr/local/bin/hello-mondoo

ENV HTTP_PORT=8080
EXPOSE 8080

# distroless "nonroot" user. Numeric so Kubernetes can enforce runAsNonRoot.
USER 65532:65532

ENTRYPOINT ["/usr/local/bin/hello-mondoo"]
