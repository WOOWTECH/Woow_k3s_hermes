# Hermes Dual GUI API Contract

## Overview
This document defines the API endpoints relied upon by the Apporo Hermes deployment.
Both upstream APIs (hermes-agent, hermes-webui) are validated as part of our deployment pipeline.

## Dashboard API (port 9119) — hermes-agent built-in
| Endpoint | Method | Expected | Validated |
|----------|--------|----------|-----------|
| /api/status | GET | 200 + gateway state | Yes |
| /api/config | GET | 200 + 150+ config fields | Yes |
| /api/config/raw | GET | 200 + YAML as JSON | Yes |
| /api/config/defaults | GET | 200 + default values | Yes |
| /api/config/schema | GET | 200 + JSON schema | Yes |
| /api/sessions | GET | 200 + session list | Yes |
| /api/sessions/search | GET | 200 + search results | Yes |
| /api/skills | GET | 200 + skill list | Yes |
| /api/cron/jobs | GET | 200 + cron jobs | Yes |
| /api/credentials/pool | GET | 200 + API key info | Yes |
| /api/providers/oauth | GET | 200 + OAuth providers | Yes |
| /api/mcp/servers | GET | 200 + MCP config | Yes |
| /api/webhooks | GET | 200 + webhook config | Yes |
| /api/profiles | GET | 200 + profile list | Yes |
| /api/analytics/usage | GET | 200 + usage data | Yes |
| /api/analytics/models | GET | 200 + model stats | Yes |
| /api/logs | GET | 200 + log entries | Yes |
| /api/model/info | GET | 200 + current model | Yes |
| /api/model/options | GET | 200 + available models | Yes |
| /api/model/auxiliary | GET | 200 + aux model info | Yes |
| /api/memory | GET | 200 + memory data | Yes |
| /api/env | GET | 200 + env vars (redacted) | Yes |
| /api/tools/toolsets | GET | 200 + toolset config | Yes |
| /api/dashboard/themes | GET | 200 + theme list | Yes |
| /api/dashboard/plugins | GET | 200 + plugin list | Yes |
| /api/ops/hooks | GET | 200 + hooks config | Yes |
| /api/ops/checkpoints | GET | 200 + checkpoint data | Yes |
| /api/pairing | GET | 200 + pairing state | Yes |

## WebUI API (port 8787) — hermes-webui by nesquena
| Endpoint | Method | Expected | Validated |
|----------|--------|----------|-----------|
| /api/auth/login | POST | 200 + {"ok":true} | Yes |
| /api/auth/status | GET | 200 + logged_in status | Yes |
| /api/sessions | GET | 200 + session list | Yes |
| /api/session/new | POST | 200 + session_id | Yes |
| /api/chat/start | POST | 200 + stream_id | Yes |
| /api/skills | GET | 200 + 104 skills | Yes |
| /api/skills/toggle | POST | 200 + toggle result | Yes |
| /api/settings | GET | 200 + UI settings | Yes |
| /api/models | GET | 200 + model list | Yes |
| /api/profiles | GET | 200 + profile data | Yes |
| /api/memory | GET | 200 + SOUL.md | Yes |
| /api/insights | GET | 200 + analytics | Yes |
| /api/crons | GET | 200 + cron jobs | Yes |
| /api/logs | GET | 200 + log entries | Yes |
| /api/projects | GET | 200 + project list | Yes |
| /api/workspaces | GET | 200 + workspace list | Yes |
| /api/kanban/boards | GET | 200 + board list | Yes |
| /api/git/status | GET | 200 + git state | Yes |

## Deployment Ownership
- Container images: upstream (hermes-agent v0.15.1, hermes-webui v0.51.432)
- API contract validation: this deployment pipeline
- Configuration: golden-config.yaml, golden-settings.json, SOUL.md
- Skills: 104 skills (26 built-in + 14 Superpowers + custom KNX/WELL/ESG)
- Infrastructure: K8s manifests, CF tunnel routing, DNS, TLS
