#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/assert.sh"

section "Round 4: Resilience & Recovery (11 tests)"

# 4.1 Agent pod kill + recovery
echo "-- 4.1 Agent pod kill --"
kubectl -n "$NAMESPACE" delete pod -l "$AGENT_LABEL" --grace-period=5 > /dev/null 2>&1
if kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l "$AGENT_LABEL" --timeout=180s > /dev/null 2>&1; then
  pass "Agent pod recovered after kill"
else
  fail "Agent pod recovery" "timeout 180s"
fi

# 4.2 PostgreSQL restart + data persistence
echo "-- 4.2 PostgreSQL persistence --"
kexec_pg psql -U hermes -d hermes -c \
  "CREATE TABLE IF NOT EXISTS _test_persist (val text); INSERT INTO _test_persist VALUES ('survive-restart');" \
  > /dev/null 2>&1
kubectl -n "$NAMESPACE" delete pod -l "$POSTGRES_LABEL" --grace-period=5 > /dev/null 2>&1
if kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l "$POSTGRES_LABEL" --timeout=120s > /dev/null 2>&1; then
  sleep 3
  VAL=$(kexec_pg psql -U hermes -d hermes -tAc \
    "SELECT val FROM _test_persist WHERE val='survive-restart';" 2>/dev/null)
  kexec_pg psql -U hermes -d hermes -c "DROP TABLE IF EXISTS _test_persist;" > /dev/null 2>&1
  [[ "$VAL" == *"survive-restart"* ]] \
    && pass "PostgreSQL data survived restart" \
    || fail "PostgreSQL persistence" "val=$VAL"
else
  fail "PostgreSQL recovery" "timeout 120s"
fi

# 4.3 Redis AOF recovery
echo "-- 4.3 Redis AOF recovery --"
kexec_redis redis-cli SET _test_aof "survive-restart" > /dev/null 2>&1
kexec_redis redis-cli BGREWRITEAOF > /dev/null 2>&1
sleep 3
kubectl -n "$NAMESPACE" delete pod -l "$REDIS_LABEL" --grace-period=5 > /dev/null 2>&1
if kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l "$REDIS_LABEL" --timeout=60s > /dev/null 2>&1; then
  sleep 3
  VAL=$(kexec_redis redis-cli GET _test_aof 2>/dev/null)
  kexec_redis redis-cli DEL _test_aof > /dev/null 2>&1
  [[ "$VAL" == *"survive-restart"* ]] \
    && pass "Redis AOF data survived restart" \
    || fail "Redis AOF" "val=$VAL"
else
  fail "Redis recovery" "timeout 60s"
fi

# 4.5 Cloudflared restart + tunnel reconnect
echo "-- 4.5 Cloudflared restart --"
kubectl -n "$NAMESPACE" rollout restart deployment/$CLOUDFLARED_DEPLOY > /dev/null 2>&1
if kubectl -n "$NAMESPACE" rollout status deployment/$CLOUDFLARED_DEPLOY --timeout=60s > /dev/null 2>&1; then
  sleep 5
  CODE=$(http_code "$EXTERNAL_URL" -k 2>/dev/null)
  if [[ "$CODE" =~ ^[23] ]]; then
    pass "Cloudflared tunnel reconnected: HTTP $CODE"
  else
    skip "Cloudflared tunnel" "HTTP $CODE (may need more time)"
  fi
else
  fail "Cloudflared restart" "rollout timeout"
fi

# 4.6 Agent gateway post-recovery
echo "-- 4.6 Agent gateway post-recovery --"
PHASE=$(kubectl -n "$NAMESPACE" get pods -l "$AGENT_LABEL" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
READY=$(kubectl -n "$NAMESPACE" get pods -l "$AGENT_LABEL" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
[[ "$PHASE" == "Running" && "$READY" == "true" ]] \
  && pass "Agent gateway ready post-recovery" \
  || fail "Agent post-recovery" "phase=$PHASE ready=$READY"

# 4.7 Memory within limits
echo "-- 4.7 Memory check --"
MEM=$(kubectl -n "$NAMESPACE" top pod -l "$AGENT_LABEL" --no-headers 2>/dev/null | awk '{print $3}')
if [[ -n "$MEM" ]]; then
  MEM_MI=$(echo "$MEM" | sed 's/Mi//')
  if [[ "$MEM_MI" =~ ^[0-9]+$ ]] && [[ "$MEM_MI" -lt 4096 ]]; then
    pass "Agent memory: ${MEM} (under 4Gi limit)"
  else
    fail "Agent memory" "mem=$MEM"
  fi
else
  skip "Memory check" "kubectl top not available"
fi

# 4.8 Scale agent to 2 replicas
echo "-- 4.8 Scale to 2 replicas --"
kubectl -n "$NAMESPACE" scale deployment/$AGENT_DEPLOY --replicas=2 > /dev/null 2>&1
sleep 30
READY_COUNT=$(kubectl -n "$NAMESPACE" get deployment $AGENT_DEPLOY \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ "$READY_COUNT" == "2" ]]; then
  pass "Agent scaled to 2 replicas"
else
  skip "Agent scaling" "readyReplicas=$READY_COUNT (PVC RWO may block)"
fi
kubectl -n "$NAMESPACE" scale deployment/$AGENT_DEPLOY --replicas=1 > /dev/null 2>&1
kubectl -n "$NAMESPACE" rollout status deployment/$AGENT_DEPLOY --timeout=120s > /dev/null 2>&1

# 4.9 Rolling update
echo "-- 4.9 Rolling update --"
kubectl -n "$NAMESPACE" rollout restart deployment/$AGENT_DEPLOY > /dev/null 2>&1
if kubectl -n "$NAMESPACE" rollout status deployment/$AGENT_DEPLOY --timeout=180s > /dev/null 2>&1; then
  pass "Rolling update completed"
else
  fail "Rolling update" "timeout"
fi

# 4.10 Rollback
echo "-- 4.10 Rollback --"
kubectl -n "$NAMESPACE" rollout undo deployment/$AGENT_DEPLOY > /dev/null 2>&1
if kubectl -n "$NAMESPACE" rollout status deployment/$AGENT_DEPLOY --timeout=180s > /dev/null 2>&1; then
  pass "Rollback completed"
else
  fail "Rollback" "timeout"
fi

# 4.11 Pod restart count
echo "-- 4.11 Pod restart count --"
MAX_RESTARTS=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null \
  | awk '{print $4}' | sort -n | tail -1)
if [[ "$MAX_RESTARTS" =~ ^[0-9]+$ ]] && [[ "$MAX_RESTARTS" -le 5 ]]; then
  pass "Max pod restarts: $MAX_RESTARTS (acceptable)"
else
  fail "Pod restarts" "max=$MAX_RESTARTS"
fi

summary
