#!/bin/bash
set -euo pipefail

# =============================================================
# Build Hermes Agent Custom Image
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.hermes-agent"

REGISTRY="${REGISTRY:-docker.io}"
IMAGE_NAME="${IMAGE_NAME:-woowtech/hermes-agent-custom}"
TAG="${TAG:-0.22.5-woow1}"
HERMES_BASE_IMAGE="${HERMES_BASE_IMAGE:-docker.io/nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

echo "============================================================"
echo "  Building Hermes Agent Custom Image"
echo "  Image: ${FULL_IMAGE}"
echo "============================================================"

if command -v docker &>/dev/null; then
    docker build \
        --build-arg "HERMES_BASE_IMAGE=${HERMES_BASE_IMAGE}" \
        --tag "${FULL_IMAGE}" \
        --file "${DOCKERFILE}" \
        "${SCRIPT_DIR}"
else
    echo "[FAIL] docker not found."
    exit 1
fi

echo ""
echo "[OK] Image built: ${FULL_IMAGE}"

if [ "${PUSH:-false}" = "true" ]; then
    echo "[INFO] Pushing to ${REGISTRY}..."
    docker push "${FULL_IMAGE}"
    echo "[OK] Pushed: ${FULL_IMAGE}"
fi
