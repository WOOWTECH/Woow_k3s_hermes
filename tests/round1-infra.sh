#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/assert.sh"

section "Round 1: Infrastructure Health (17 tests)"

# 1.1-1.5 Pod Running & Ready
for pair in \
  "$POSTGRES_LABEL|PostgreSQL" \
  "$REDIS_LABEL|Redis" \
  "$AGENT_LABEL|Agent" \
  "$CLOUDFLARED_LABEL|Cloudflared"; do
  LABEL="${pair%%|*}"; NAME="${pair##*|}"
  PHASE=$(kubectl -n "$NAMESPACE" get pods -l "$LABEL" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  READY=$(kubectl -n "$NAMESPACE" get pods -l "$LABEL" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  if [[ "$PHASE" == "Running" ]]; then
    pass "$NAME pod Running (ready=$READY)"
  else
    fail "$NAME pod" "phase=$PHASE"
  fi
done

# 1.6-1.9 Service ClusterIP
for svc in "$POSTGRES_SVC" "$REDIS_SVC" "$AGENT_SVC"; do
  CIP=$(kubectl -n "$NAMESPACE" get svc "$svc" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  if [[ -n "$CIP" && "$CIP" != "None" ]]; then
    pass "$svc ClusterIP=$CIP"
  else
    fail "$svc ClusterIP" "ip=$CIP"
  fi
done

# 1.10-1.12 PVC Bound
for pvc in "$PVC_POSTGRES" "$PVC_REDIS" "$PVC_HOME"; do
  PHASE=$(kubectl -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Bound" ]] && pass "$pvc Bound" || fail "$pvc" "phase=$PHASE"
done

# 1.13 PostgreSQL pg_isready
kexec_pg pg_isready -U hermes -d hermes > /dev/null 2>&1 \
  && pass "PostgreSQL pg_isready" || fail "pg_isready" "failed"

# 1.14 Redis PING
PONG=$(kexec_redis redis-cli ping 2>/dev/null)
[[ "$PONG" == *"PONG"* ]] && pass "Redis PONG" || fail "Redis ping" "got=$PONG"

# 1.15 Network policies exist
NP_COUNT=$(kubectl -n "$NAMESPACE" get networkpolicy "$NP_POSTGRES" "$NP_REDIS" --no-headers 2>/dev/null | wc -l)
[[ "$NP_COUNT" -ge 2 ]] && pass "Network policies: $NP_COUNT found" || fail "Network policies" "only $NP_COUNT"

# 1.16 Resource limits on agent
LIMITS=$(kubectl -n "$NAMESPACE" get deployment "$AGENT_DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits}' 2>/dev/null)
if echo "$LIMITS" | grep -q "memory" && echo "$LIMITS" | grep -q "cpu"; then
  pass "Agent resource limits set"
else
  fail "Resource limits" "limits=$LIMITS"
fi

# 1.17 Ingress host correct
HOST=$(kubectl -n "$NAMESPACE" get ingress hermes-ingress \
  -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
[[ "$HOST" == "$DOMAIN" ]] && pass "Ingress host=$HOST" || fail "Ingress host" "got=$HOST"

summary
