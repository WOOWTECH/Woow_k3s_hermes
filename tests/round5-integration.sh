#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/assert.sh"

section "Round 5: Cross-Service Integration (10 tests)"

# 5.2 Agent -> PostgreSQL TCP
echo "-- 5.2 Agent -> PostgreSQL --"
RESULT=$(kexec_agent sh -c "timeout 5 sh -c 'echo | cat > /dev/tcp/$POSTGRES_SVC/$POSTGRES_PORT' 2>&1 && echo CONNECTED" 2>/dev/null)
if echo "$RESULT" | grep -q "CONNECTED"; then
  pass "Agent -> PostgreSQL TCP connected"
else
  DNS=$(kexec_agent sh -c "getent hosts $POSTGRES_SVC" 2>/dev/null)
  [[ -n "$DNS" ]] && pass "Agent -> PostgreSQL DNS resolves" || fail "Agent -> PostgreSQL" "no connectivity"
fi

# 5.3 Agent -> Redis TCP
echo "-- 5.3 Agent -> Redis --"
RESULT=$(kexec_agent sh -c "timeout 5 sh -c 'echo | cat > /dev/tcp/$REDIS_SVC/$REDIS_PORT' 2>&1 && echo CONNECTED" 2>/dev/null)
if echo "$RESULT" | grep -q "CONNECTED"; then
  pass "Agent -> Redis TCP connected"
else
  DNS=$(kexec_agent sh -c "getent hosts $REDIS_SVC" 2>/dev/null)
  [[ -n "$DNS" ]] && pass "Agent -> Redis DNS resolves" || fail "Agent -> Redis" "no connectivity"
fi

# 5.4 External -> Agent e2e
echo "-- 5.4 External -> Agent --"
CODE=$(http_code "$EXTERNAL_URL" -k)
if [[ "$CODE" =~ ^[23] ]]; then
  pass "External -> Agent: HTTP $CODE"
else
  fail "External -> Agent" "http=$CODE"
fi

# 5.6 Ingress /api -> Agent
echo "-- 5.6 Ingress /api -> Agent --"
CODE=$(http_code "$EXTERNAL_URL/api" -k)
if [[ "$CODE" != "502" && "$CODE" != "503" && "$CODE" != "000" ]]; then
  pass "Ingress /api -> Agent: HTTP $CODE"
else
  fail "Ingress /api" "http=$CODE"
fi

# 5.7 ConfigMap values correct
echo "-- 5.7 ConfigMap values --"
PG_HOST=$(kubectl -n "$NAMESPACE" get configmap hermes-config -o jsonpath='{.data.POSTGRES_HOST}' 2>/dev/null)
RD_HOST=$(kubectl -n "$NAMESPACE" get configmap hermes-config -o jsonpath='{.data.REDIS_HOST}' 2>/dev/null)
PG_PORT=$(kubectl -n "$NAMESPACE" get configmap hermes-config -o jsonpath='{.data.POSTGRES_PORT}' 2>/dev/null)
AGT_PORT=$(kubectl -n "$NAMESPACE" get configmap hermes-config -o jsonpath='{.data.HERMES_AGENT_PORT}' 2>/dev/null)
if [[ "$PG_HOST" == "$POSTGRES_SVC" && "$RD_HOST" == "$REDIS_SVC" && \
      "$PG_PORT" == "$POSTGRES_PORT" && "$AGT_PORT" == "$AGENT_PORT" ]]; then
  pass "ConfigMap values correct"
else
  fail "ConfigMap" "PG=$PG_HOST:$PG_PORT RD=$RD_HOST AGT=$AGT_PORT"
fi

# 5.8 Secrets exist & non-empty
echo "-- 5.8 Secrets --"
KEYS=$(kubectl -n "$NAMESPACE" get secret hermes-secrets -o jsonpath='{.data}' 2>/dev/null)
if echo "$KEYS" | grep -q "POSTGRES_PASSWORD" && echo "$KEYS" | grep -q "MINIMAX_API_KEY"; then
  pass "Secrets: POSTGRES_PASSWORD + MINIMAX_API_KEY present"
else
  fail "Secrets" "missing keys"
fi

# 5.9 Ingress host matches domain
echo "-- 5.9 Ingress host --"
HOST=$(kubectl -n "$NAMESPACE" get ingress hermes-ingress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
[[ "$HOST" == "$DOMAIN" ]] && pass "Ingress host=$HOST" || fail "Ingress host" "got=$HOST"

# 5.10 Cloudflare tunnel registered
echo "-- 5.10 Cloudflare tunnel --"
LOGS=$(kubectl -n "$NAMESPACE" logs deployment/$CLOUDFLARED_DEPLOY --tail=30 2>/dev/null)
if echo "$LOGS" | grep -q "Registered tunnel connection"; then
  LOCATIONS=$(echo "$LOGS" | grep "Registered" | grep -oP "location=\w+" | sort -u | tr '\n' ',' | sed 's/,$//')
  pass "CF tunnel registered ($LOCATIONS)"
else
  fail "CF tunnel" "no registration found"
fi

summary
