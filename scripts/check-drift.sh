#!/usr/bin/env bash
# Compare this chart with what is running for ONE instance. Exit 0 = in
# sync, 1 = drift. Extra arguments are passed to `helm template`.
#
#   CONTEXT=woow-k3s RELEASE=hermes NAMESPACE=hermes \
#     scripts/check-drift.sh -f deploy/woow-k3s/hermes-hermes.yaml
#
# Run once per live instance — this repo currently has three:
#   RELEASE=hermes                   NAMESPACE=hermes             -f deploy/woow-k3s/hermes-hermes.yaml
#   RELEASE=eugenechen-hermes-hermes NAMESPACE=eugenechen-hermes  -f deploy/woow-k3s/eugenechen-hermes-hermes.yaml
#   RELEASE=cindytech-cindytech1     NAMESPACE=cindytech          -f deploy/woow-k3s/cindytech-cindytech1.yaml
set -euo pipefail

CONTEXT="${CONTEXT:-woow-k3s}"
RELEASE="${RELEASE:?set RELEASE to the helm release name}"
NAMESPACE="${NAMESPACE:?set NAMESPACE to the release namespace}"
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helm template "$RELEASE" . -n "$NAMESPACE" --skip-tests "$@" > "$tmp/repo.yaml"
helm --kube-context "$CONTEXT" get manifest "$RELEASE" -n "$NAMESPACE" > "$tmp/release.yaml"

rc=0
if diff -u -B "$tmp/release.yaml" "$tmp/repo.yaml" > "$tmp/repo.diff"; then
  echo "1. repo == release ${RELEASE}"
else
  echo "1. DRIFT: this repo renders differently from release ${RELEASE}:"
  cat "$tmp/repo.diff"
  rc=1
fi

set +e
kubectl --context "$CONTEXT" diff -f "$tmp/repo.yaml" > "$tmp/live.diff" 2>&1
krc=$?
set -e
case "$krc" in
  0) echo "2. cluster == chart (context ${CONTEXT})" ;;
  1) echo "2. DRIFT: live objects differ from the chart:"; cat "$tmp/live.diff"; rc=1 ;;
  *) cat "$tmp/live.diff" >&2; exit "$krc" ;;
esac
exit "$rc"
