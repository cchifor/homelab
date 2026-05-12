#!/usr/bin/env bash
# Run this on the claude-worker VM. Requires: docker, qemu-user-static, buildx.
# Pushes a multi-arch image to gitea.chifor.dev/c4/claude-runner.
set -euo pipefail

REGISTRY=${REGISTRY:-gitea.chifor.dev}
NAMESPACE=${NAMESPACE:-c4}
IMAGE=${IMAGE:-claude-runner}
TAG=${TAG:-$(date -u +%Y%m%d)-$(git rev-parse --short HEAD)}

cd "$(dirname "$0")"

docker buildx create --use --name claude-runner-builder 2>/dev/null || \
  docker buildx use claude-runner-builder

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag "${REGISTRY}/${NAMESPACE}/${IMAGE}:${TAG}" \
  --tag "${REGISTRY}/${NAMESPACE}/${IMAGE}:latest" \
  --push \
  .

echo
echo "Pushed: ${REGISTRY}/${NAMESPACE}/${IMAGE}:${TAG}"
echo "Pushed: ${REGISTRY}/${NAMESPACE}/${IMAGE}:latest"
