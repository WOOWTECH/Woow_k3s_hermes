#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DIGEST=sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d

grep -q '^version: 2.1.0$' "$ROOT/Chart.yaml"
grep -q '^appVersion: "0.22.5"$' "$ROOT/Chart.yaml"
grep -q "v0.22.5@$DIGEST" "$ROOT/values.yaml"
grep -q "v0.22.5@$DIGEST" "$ROOT/docker/Dockerfile.hermes-agent"
grep -q "v0.22.5@$DIGEST" "$ROOT/docker/build-image.sh"
if grep -nE 'nousresearch/hermes-agent:(latest|0\.17\.4)' \
  "$ROOT/values.yaml" "$ROOT/docker/Dockerfile.hermes-agent" "$ROOT/docker/build-image.sh"; then
  echo "floating or incompatible Hermes runtime reference found" >&2
  exit 1
fi
echo "runtime release contract: PASS"
