#!/usr/bin/env bash
PASS=0; FAIL=0; SKIP=0; TOTAL=0
RESULTS_LOG="${RESULTS_LOG:-/tmp/hermes-test-results.log}"

pass() { ((PASS++)); ((TOTAL++)); echo "  PASS: $1"; echo "PASS|$1" >> "$RESULTS_LOG"; }
fail() { ((FAIL++)); ((TOTAL++)); echo "  FAIL: $1 -- $2"; echo "FAIL|$1|$2" >> "$RESULTS_LOG"; }
skip() { ((SKIP++)); ((TOTAL++)); echo "  SKIP: $1 -- $2"; echo "SKIP|$1|$2" >> "$RESULTS_LOG"; }

section() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

summary() {
  echo ""
  echo "  -- Results: $PASS pass / $FAIL fail / $SKIP skip (total $TOTAL) --"
}

kexec_agent()  { kubectl -n "$NAMESPACE" exec deployment/hermes-agent    -- "$@" 2>&1; }
kexec_pg()     { kubectl -n "$NAMESPACE" exec deployment/hermes-postgresql -- "$@" 2>&1; }
kexec_redis()  { kubectl -n "$NAMESPACE" exec deployment/hermes-redis    -- "$@" 2>&1; }
kexec_cf()     { kubectl -n "$NAMESPACE" exec deployment/cloudflared     -- "$@" 2>&1; }

http_code() { curl -s -o /dev/null -w "%{http_code}" --max-time 10 $CURL_RESOLVE "$@" 2>&1; }
ext_curl() { curl -sk --max-time 10 $CURL_RESOLVE "$@" 2>&1; }
