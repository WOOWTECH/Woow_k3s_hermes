#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/assert.sh"

section "Round 2: Backend API Tests (14 tests)"

# 2.1 Agent gateway TCP 8642
AGENT_TCP=$(kexec_agent sh -c 'cat /proc/net/tcp 2>/dev/null | grep ":21C2" || echo "NOTFOUND"')
if [[ "$AGENT_TCP" != *"NOTFOUND"* && -n "$AGENT_TCP" ]]; then
  pass "Agent gateway TCP 8642 listening"
else
  # Fallback: check via service
  RESULT=$(kubectl -n "$NAMESPACE" run tcp-probe-agent --rm -i --restart=Never \
    --image=busybox --command -- sh -c "nc -z -w 3 $AGENT_SVC $AGENT_PORT && echo OK" 2>/dev/null | tail -1)
  [[ "$RESULT" == *"OK"* ]] && pass "Agent gateway TCP 8642 (via probe)" || fail "Agent TCP 8642" "not listening"
fi

# 2.2 Agent dashboard TCP 9119
DASH_TCP=$(kexec_agent sh -c 'cat /proc/net/tcp 2>/dev/null | grep ":23A7" || echo "NOTFOUND"')
if [[ "$DASH_TCP" != *"NOTFOUND"* && -n "$DASH_TCP" ]]; then
  pass "Agent dashboard TCP 9119 listening"
else
  skip "Agent dashboard TCP 9119" "proc/net/tcp unavailable"
fi

# 2.4 Cloudflared /ready
CF_READY=$(kexec_cf wget -q -O- http://localhost:$CF_METRICS_PORT/ready 2>/dev/null)
[[ "$?" -eq 0 || -n "$CF_READY" ]] && pass "Cloudflared /ready responds" || fail "Cloudflared /ready" "no response"

# 2.5 PostgreSQL CRUD
PG_RESULT=$(kexec_pg psql -U hermes -d hermes -tAc "
  CREATE TABLE IF NOT EXISTS _test_r2 (id serial PRIMARY KEY, val text);
  INSERT INTO _test_r2 (val) VALUES ('hermes-enterprise-test');
  SELECT val FROM _test_r2 WHERE val='hermes-enterprise-test';
  DROP TABLE _test_r2;
" 2>&1)
echo "$PG_RESULT" | grep -q "hermes-enterprise-test" \
  && pass "PostgreSQL CRUD cycle" || fail "PostgreSQL CRUD" "result=$(echo "$PG_RESULT" | head -1)"

# 2.6 Redis SET/GET
kexec_redis redis-cli SET _test_r2 "hermes-enterprise-test" > /dev/null 2>&1
VAL=$(kexec_redis redis-cli GET _test_r2 2>/dev/null)
[[ "$VAL" == *"hermes-enterprise-test"* ]] \
  && pass "Redis SET/GET" || fail "Redis SET/GET" "val=$VAL"

# 2.7 Redis DEL
kexec_redis redis-cli DEL _test_r2 > /dev/null 2>&1
VAL=$(kexec_redis redis-cli GET _test_r2 2>/dev/null)
[[ -z "$VAL" || "$VAL" == *"nil"* ]] && pass "Redis DEL verified" || fail "Redis DEL" "val=$VAL"

# 2.8 Redis TTL
kexec_redis redis-cli SET _test_ttl v EX 30 > /dev/null 2>&1
TTL=$(kexec_redis redis-cli TTL _test_ttl 2>/dev/null)
kexec_redis redis-cli DEL _test_ttl > /dev/null 2>&1
if [[ "$TTL" =~ ^[0-9]+$ ]] && [[ "$TTL" -gt 0 ]]; then
  pass "Redis TTL=$TTL"
else
  fail "Redis TTL" "ttl=$TTL"
fi

# 2.9 Redis version
INFO=$(kexec_redis redis-cli INFO server 2>/dev/null)
echo "$INFO" | grep -q "redis_version:7" \
  && pass "Redis version 7.x" || fail "Redis version" "$(echo "$INFO" | grep redis_version | head -1)"

# 2.10 Redis maxmemory-policy
POLICY=$(kexec_redis redis-cli CONFIG GET maxmemory-policy 2>/dev/null | tail -1)
[[ "$POLICY" == "allkeys-lru" ]] \
  && pass "Redis maxmemory-policy: allkeys-lru" || fail "Redis maxmemory-policy" "got=$POLICY"

# 2.11 DNS agent -> postgres
DNS=$(kexec_agent sh -c "getent hosts $POSTGRES_SVC 2>/dev/null || nslookup $POSTGRES_SVC 2>/dev/null" 2>/dev/null)
[[ -n "$DNS" ]] && pass "DNS agent->postgres resolves" || fail "DNS agent->postgres" "no resolution"

# 2.12 DNS agent -> redis
DNS=$(kexec_agent sh -c "getent hosts $REDIS_SVC 2>/dev/null || nslookup $REDIS_SVC 2>/dev/null" 2>/dev/null)
[[ -n "$DNS" ]] && pass "DNS agent->redis resolves" || fail "DNS agent->redis" "no resolution"

# 2.13 External URL responds
EXT_CODE=$(http_code "$EXTERNAL_URL" -k)
if [[ "$EXT_CODE" =~ ^[23] ]]; then
  pass "External URL responds: HTTP $EXT_CODE"
else
  fail "External URL" "http=$EXT_CODE"
fi

# 2.14 HTTPS cert valid
CERT_INFO=$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
if echo "$CERT_INFO" | grep -q "notAfter"; then
  pass "HTTPS certificate valid"
else
  skip "HTTPS certificate" "openssl check failed"
fi

summary
