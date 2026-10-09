#!/usr/bin/env bash
# Download a hello-mondoo release from the app repo and verify it before it
# goes anywhere near an image. Used by CI and for local builds.
#
#   scripts/fetch-release.sh v1.2.3 [dist-dir]
#
# Needs: curl, cosign, sha256sum.
set -euo pipefail

TAG="${1:?usage: $0 <tag> [dist-dir]}"
DIST="${2:-dist}"
APP_REPO="clickbg/pe-challenge-p1-go-app"
ARCHES=(amd64 arm64)

# The tag arrives from a repository_dispatch payload, so treat it as untrusted.
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "error: '$TAG' is not a semver tag" >&2
  exit 1
fi

base="https://github.com/${APP_REPO}/releases/download/${TAG}"
binaries=()
for arch in "${ARCHES[@]}"; do
  binaries+=("hello-mondoo_linux_${arch}")
done

mkdir -p "$DIST"
cd "$DIST"

for f in SHA256SUMS SHA256SUMS.sigstore.json "${binaries[@]}"; do
  echo "downloading $f"
  curl -fsSL --retry 3 -o "$f" "${base}/${f}"
done

# Only the app repo's release workflow, running for this exact tag, is trusted
# to have signed the checksums.
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/${APP_REPO}/.github/workflows/release.yml@refs/tags/${TAG}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS

# sha256sum -c silently skips files that aren't listed, so check each binary
# is actually covered by the signed list before verifying.
pattern=$(printf '|%s' "${binaries[@]}")
grep -E "  (${pattern:1})$" SHA256SUMS > SHA256SUMS.linux
if [[ $(wc -l < SHA256SUMS.linux) -ne ${#binaries[@]} ]]; then
  echo "error: SHA256SUMS does not list every expected binary" >&2
  exit 1
fi
sha256sum -c SHA256SUMS.linux
