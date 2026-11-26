# PRD: Hermes K8s Enterprise Deployment Validation

## Document Info

| Field | Value |
|-------|-------|
| Project | Hermes Smart Home Assistant |
| Platform | K3s cluster (2 master + 7 worker) |
| Namespace | `hermes` |
| Domain | https://hermes-woowtechjac.woowtech.io |
| Author | Enterprise QA |
| Date | 2026-05-11 |
| Test Framework | Bash + Playwright |
| Total Tests | 80 (68 bash + 12 Playwright) |

## Background & Motivation

Hermes is a smart home AI assistant deployed on K3s with 5 services:
hermes-agent (AI gateway), hermes-webui (web interface), PostgreSQL 15
(persistence), Redis 7 (cache with AOF), and cloudflared (Cloudflare Tunnel).
This test suite validates enterprise-grade readiness across infrastructure,
APIs, security, resilience, cross-service integration, and browser UX.

## Deployment Under Test

| Component | Image | Ports | Storage |
|-----------|-------|-------|---------|
| hermes-agent | nousresearch/hermes-agent:v0.22.5@sha256:9c556…238d | 8642 (gateway), 9119 (dashboard) | hermes-home-pvc 10Gi |
| hermes-webui | ghcr.io/nesquena/hermes-webui:latest | 8787 | emptyDir |
| PostgreSQL | postgres:15 | 5432 | hermes-postgresql-pvc 10Gi |
| Redis | redis:7-alpine | 6379 (appendonly, 256mb, allkeys-lru) | hermes-redis-pvc 5Gi |
| cloudflared | cloudflare/cloudflared:latest | 20241 (metrics) | none |

- **Ingress**: Traefik — `/` -> webui:8787, `/api` -> agent:8642
- **Network Policies**: PostgreSQL and Redis restricted to hermes-agent and hermes-webui pods only
- **External Access**: Cloudflare Tunnel -> hermes-webui-svc:8787

## Test Architecture

### Round 1: Infrastructure Health (17 tests)
| # | Test | Method | Expected |
|---|------|--------|----------|
| 1.1 | PostgreSQL pod Running | kubectl get pods -l app | Running |
| 1.2 | Redis pod Running | kubectl get pods -l app | Running |
| 1.3 | Agent pod Running & Ready | kubectl get pods -l app | 1/1 Ready |
| 1.4 | WebUI pod Running & Ready | kubectl get pods -l app | 1/1 Ready |
| 1.5 | Cloudflared pod Running | kubectl get pods -l app | Running |
| 1.6 | PostgreSQL service ClusterIP | kubectl get svc | Non-empty IP |
| 1.7 | Redis service ClusterIP | kubectl get svc | Non-empty IP |
| 1.8 | Agent service ClusterIP | kubectl get svc | Non-empty IP |
| 1.9 | WebUI service ClusterIP | kubectl get svc | Non-empty IP |
| 1.10 | PVC postgresql Bound | kubectl get pvc | Bound |
| 1.11 | PVC redis Bound | kubectl get pvc | Bound |
| 1.12 | PVC hermes-home Bound | kubectl get pvc | Bound |
| 1.13 | PostgreSQL pg_isready | kubectl exec pg_isready | exit 0 |
| 1.14 | Redis PING | kubectl exec redis-cli ping | PONG |
| 1.15 | Network policies exist | kubectl get networkpolicy | 2 found |
| 1.16 | Resource limits on agent | jsonpath .resources.limits | cpu + memory |
| 1.17 | Ingress host correct | jsonpath .spec.rules[0].host | domain match |

### Round 2: Backend API Tests (14 tests)
| # | Test | Method | Expected |
|---|------|--------|----------|
| 2.1 | Agent gateway TCP 8642 | TCP socket probe | Listening |
| 2.2 | Agent dashboard TCP 9119 | TCP socket probe | Listening |
| 2.3 | WebUI HTTP 8787 | curl from debug pod | 200/302 |
| 2.4 | Cloudflared /ready | wget metrics endpoint | 200 |
| 2.5 | PostgreSQL CRUD | CREATE/INSERT/SELECT/DROP | Data matches |
| 2.6 | Redis SET/GET | redis-cli SET/GET | Value matches |
| 2.7 | Redis DEL | redis-cli DEL/GET | nil |
| 2.8 | Redis TTL | SET with EX, TTL > 0 | TTL in range |
| 2.9 | Redis version | INFO server | redis_version:7 |
| 2.10 | Redis maxmemory-policy | CONFIG GET | allkeys-lru |
| 2.11 | DNS agent->postgres | getent hosts | Resolves |
| 2.12 | DNS agent->redis | getent hosts | Resolves |
| 2.13 | External URL responds | curl https://domain | HTTP response |
| 2.14 | HTTPS cert valid | openssl s_client | Valid cert |

### Round 3: Security & Stress (16 tests)
| # | Test | Method | Expected |
|---|------|--------|----------|
| 3.1 | WebUI requires auth | curl no-auth | 302/401 |
| 3.2 | Wrong password rejected | POST wrong password | Rejected |
| 3.3 | XSS payload safe | script tag in request | No execution |
| 3.4 | SQLi safe | SQL injection attempt | No damage |
| 3.5 | Oversized payload 1MB | curl large body | Not 500 |
| 3.6 | 50 concurrent requests | parallel curl | >= 90% success |
| 3.7 | 100 sequential rapid fire | loop curl | >= 95% success |
| 3.8 | Invalid auth token | Bearer INVALID | 401/403 |
| 3.9 | CORS headers | Origin: evil.com | Headers present |
| 3.10 | Network policy enforcement | Unauthorized pod -> DB | Blocked |
| 3.11 | Secrets not leaked | kubectl describe | No plaintext |
| 3.12 | Container non-root | id command | Informational |
| 3.13 | Path traversal | /../etc/passwd | Blocked |
| 3.14 | CRLF injection | %0d%0a header | Blocked |
| 3.15 | TLS certificate valid | openssl s_client | Not expired |
| 3.16 | Malformed JSON | POST invalid JSON | 400 not 500 |

### Round 4: Resilience & Recovery (11 tests)
| # | Test | Method | Expected |
|---|------|--------|----------|
| 4.1 | Agent pod kill + recovery | delete pod, wait ready | < 180s |
| 4.2 | PostgreSQL restart + persistence | INSERT, kill, SELECT | Data survives |
| 4.3 | Redis AOF recovery | SET, BGREWRITEAOF, kill, GET | Data survives |
| 4.4 | WebUI restart | kill, wait, HTTP check | Recovers |
| 4.5 | Cloudflared tunnel reconnect | rollout restart | External access restored |
| 4.6 | Agent gateway post-recovery | TCP 8642 after restart | Responds |
| 4.7 | Memory within limits | kubectl top pod | Under 4Gi |
| 4.8 | Scale agent to 2 | scale replicas, restore | Both run (or skip RWO) |
| 4.9 | Rolling update | rollout restart | Completes |
| 4.10 | Rollback | rollout undo | Succeeds |
| 4.11 | Pod restart count | get pods | Low count |

### Round 5: Cross-Service Integration (10 tests)
| # | Test | Method | Expected |
|---|------|--------|----------|
| 5.1 | WebUI -> Agent | curl from webui pod | Response |
| 5.2 | Agent -> PostgreSQL TCP | /dev/tcp probe | Connected |
| 5.3 | Agent -> Redis TCP | /dev/tcp probe | Connected |
| 5.4 | External -> WebUI e2e | curl external URL | Response |
| 5.5 | Ingress / -> WebUI | curl domain root | WebUI content |
| 5.6 | Ingress /api -> Agent | curl domain/api | Agent response |
| 5.7 | ConfigMap values correct | jsonpath verify | Match expected |
| 5.8 | Secrets exist & non-empty | jsonpath check | Keys present |
| 5.9 | Ingress host matches | jsonpath | Domain match |
| 5.10 | CF tunnel registered | kubectl logs | "Registered" found |

### Playwright Browser E2E (12 tests)
| # | Test | Method | Expected |
|---|------|--------|----------|
| T1 | Page loads | goto, check status | 200/302 |
| T2 | Password auth flow | fill + submit | Redirects to app |
| T3 | Dashboard content | textContent | > 50 chars |
| T4 | Navigation elements | locator count | Links exist |
| T5 | Agent status indicator | body text | Status keywords |
| T6 | Desktop 1280x720 | viewport + screenshot | Renders |
| T7 | Tablet 768x1024 | viewport + screenshot | Renders |
| T8 | Mobile 375x667 | viewport + screenshot | Renders |
| T9 | 404 invalid route | goto /nonexistent | Not 500 |
| T10 | Load < 5 seconds | timing | < 5000ms |
| T11 | /api reaches agent | goto /api | Not 502/503 |
| T12 | Wrong password rejected | fill wrong pw | Still on login |

## Success Criteria

| Criterion | Threshold |
|-----------|-----------|
| Round 1 (Infrastructure) | 100% pass |
| Round 2 (API) | 100% pass |
| Round 3 (Security) | >= 95% pass |
| Round 4 (Resilience) | >= 90% pass |
| Round 5 (Integration) | >= 95% pass |
| Playwright | >= 90% pass |
| **Overall** | **>= 95% for enterprise readiness** |
| Duration | < 30 minutes |
| Pod stability | Zero OOM kills |
