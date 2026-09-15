---
name: strongly
description: >-
  Help the user build on and operate the Strongly.AI platform through its REST
  API — deploying apps (behind the Strongly proxy, with JWT identity and
  artifacts), provisioning addons and data sources, running agents and
  workflows, and using MLOps, the model registry, and the AI Gateway. Use this
  whenever the user mentions Strongly, strongly.ai, a Strongly app/agent/
  workflow/addon/datasource/model, STRONGLY_SERVICES, the Strongly proxy, or an
  X-API-Key / X-Strongly-* header.
---

# Strongly.AI

Strongly is a platform for deploying apps, data, models, agents, and workflows on
managed Kubernetes. Everything a user can do in the UI is also reachable through
one REST API at `/api/v1`. Your job is to help the user drive that API correctly.

This file is the map. Deep, per-feature detail lives in `references/<feature>.md`
and should be read **on demand** — load a reference only when the task is about
that feature.

## Golden rules

1. **Only use real endpoints.** Every path in this skill maps to a real
   `/api/v1` route. Do not invent endpoints, fields, or query params. If you
   need something not documented here, discover it with a `list`/`GET` call or
   tell the user it may not be exposed — never guess a URL.
2. **Ground answers in the user's actual resources.** Before recommending an
   addon, model, or workflow, `GET` the relevant list and name what the user
   really has. Do not assume a resource exists.
3. **Async operations must be polled, not assumed.** Deploys, builds, model
   spin-ups, and workflow runs return immediately and finish later. After a
   `deploy`/`start`/`run`, poll the matching `status` endpoint until it reports
   ready/running/complete before you claim success or use the resource.
4. **Never handle the user's secrets for them.** The user creates their own API
   key; you use it, you never mint or ask them to paste a password. Treat the
   API key as sensitive — never put it in a URL or log it.
5. **No fabricated success.** If a call errors or a build fails, report the
   status and the error honestly. Do not paper over a failure.

## Authentication and base URL

- **Base URL:** `<HOST>/api/v1`, where `<HOST>` is the user's Strongly deployment
  (e.g. `https://app.strongly.ai`, or their self-hosted host). Always ask for /
  confirm the host; don't hardcode a public one.
- **Auth header:** send the platform API key as `X-API-Key: <key>` on every
  request. (A user JWT via `Authorization: Bearer <jwt>` also works for
  interactive sessions, but API-key is the norm for programmatic use.)
- **Getting a key:** the user creates one in the UI under **Settings → API Keys**
  (a.k.a. Profile → Security → API Keys). Keys carry **scopes**
  (`apps:write`, `apps:deploy`, `workflows:write`, `artifacts:read`, …); a call
  returns `403 scope-required` if the key lacks the scope. Tell the user which
  scope to add rather than working around it.

```bash
# Every call follows this shape:
curl -s -H "X-API-Key: $STRONGLY_API_KEY" \
     -H "Content-Type: application/json" \
     "$HOST/api/v1/apps"
```

**Response envelope.** Success is `{ "success": true, "data": … }` (lists add
`pagination`). Errors are `{ "success": false, "error": { "code", "message" } }`
with a matching HTTP status. Read `data` on success; surface `error.message` on
failure.

**Discovery.** List endpoints (`GET /api/v1/<resource>`) accept `limit`,
`offset`, `sort`, and usually `search`. Resource ids are 24-char hex Mongo
ObjectIds; pass them in the path (`/api/v1/apps/<id>`).

## The two things that make Strongly apps different

If the task involves **apps**, three platform mechanics matter — full detail in
`references/apps.md`, but the essentials:

- **The Strongly proxy.** Deployed apps are reached only through the platform
  proxy at a relative base path given by the `STRONGLY_URL` env var — never a
  bare port. Apps must serve from that base path (this is the usual cause of a
  blank React screen). The proxy is also the trust boundary.
- **Identity via one header.** The proxy injects the signed-in user as a JWT in
  `X-Strongly-User-Token` (and convenience `X-Strongly-User-*` headers). Apps
  **decode** it (they never see the signing secret) to know who the user is —
  no login screen.
- **Wiring via `STRONGLY_SERVICES`.** Connected addons, data sources, AI models,
  and workflows arrive as a JSON env var `STRONGLY_SERVICES`. The app reads
  connection strings and model endpoints from there instead of hardcoding them.

## Feature routing

Read the matching reference before doing detailed work in that area:

| The user is asking about… | Read | Key REST prefixes |
|---|---|---|
| Deploying/serving **apps**, proxy, JWT identity, artifacts | `references/apps.md` | `/apps`, `/artifacts` |
| **Addons** (managed Postgres/Mongo/Redis/…) | `references/addons.md` | `/addons` |
| **Data sources** (connect external DBs/warehouses/object stores) | `references/datasources.md` | `/datasources`, `/data-forge` |
| **Agents** (deploy & chat with Strongly Agents) | `references/agents.md` | `/agents`, `/agents/:id/messages` |
| **Workflows** (build/run node graphs, batch + streaming) | `references/workflows.md` | `/workflows`, `/workflow-nodes`, `/executions` |
| **MLOps** (AutoML, experiments, drift, fine-tuning, feature store) | `references/mlops.md` | `/automl`, `/experiments`, `/drift-detection`, `/fine-tuning`, `/feature-store` |
| **Model registry** (register/version/promote models) | `references/model-registry.md` | `/model-registry` |
| **AI Gateway** (call 3rd-party & self-hosted models, keys, guardrails) | `references/ai-gateway.md` | `/ai-models`, `/ai-inference`, `/ai-provider-keys`, `/guardrails` |

When you're unsure which area a request falls in, list the relevant resource
first (`GET /api/v1/apps`, `/agents`, `/workflows`, …) to orient, then load the
reference.
