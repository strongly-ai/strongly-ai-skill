---
name: strongly
description: >-
  Help the user build on and operate the Strongly.AI platform through its REST
  API, deploying apps (behind the Strongly proxy, with JWT identity and
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
and should be read **on demand**, load a reference only when the task is about
that feature.

## Golden rules

1. **Only use real endpoints.** Every path in this skill maps to a real
   `/api/v1` route. Do not invent endpoints, fields, or query params. If you
   need something not documented here, discover it with a `list`/`GET` call or
   tell the user it may not be exposed, never guess a URL.
2. **Ground answers in the user's actual resources.** Before recommending an
   addon, model, or workflow, `GET` the relevant list and name what the user
   really has. Do not assume a resource exists.
3. **Async operations must be polled, not assumed.** Deploys, builds, model
   spin-ups, and workflow runs return immediately and finish later. After a
   `deploy`/`start`/`run`, poll the matching `status` endpoint until it reports
   ready/running/complete before you claim success or use the resource.
4. **Never handle the user's secrets for them.** The user creates their own API
   key; you use it, you never mint or ask them to paste a password. Treat the
   API key as sensitive, never put it in a URL or log it.
5. **No fabricated success.** If a call errors or a build fails, report the
   status and the error honestly. Do not paper over a failure.

## Authentication: first decide WHERE you are running

Auth works two different ways depending on your execution context. Figure out
which one you're in **before** doing anything else.

**Inside Strongly**, you are running in a Strongly **workspace** (e.g. Claude
Code or Codex in a Strongly workspace) or inside a deployed **app**. Tell by the
environment: `STRONGLY_API_URL` and/or `STRONGLY_SERVICES` are set.
- The platform base URL is already in the environment: **`$STRONGLY_API_URL`**
  (an in-cluster address the platform sets); its REST API is
  `$STRONGLY_API_URL/api/v1`.
- **Auth is handled for you.** The platform injects the caller's bearer token on
  these in-cluster calls, so you do **not** set an `Authorization` header, and you
  do **not** ask the user for a key or host. (`$STRONGLY_API_KEY` is also present
  in the workspace env if you prefer to send it explicitly, but you don't need
  to.) Just call the API.

```bash
# Inside Strongly: use the injected base URL, no auth header needed.
curl -s "$STRONGLY_API_URL/api/v1/apps"
```

**Outside Strongly**, you are running anywhere else (Claude Code on a laptop, a
CI job, any external client). None of the `STRONGLY_*` env vars are set.
- You must supply the **host**: `<HOST>/api/v1`, where `<HOST>` is the user's
  Strongly deployment (e.g. `https://app.strongly.ai`, or their self-hosted host).
  Ask the user for it; never hardcode a public one.
- Authenticate with an API key header: **`X-API-Key: <key>`** on every request.
  The user creates a key in the UI under **Settings → API Keys** (a.k.a.
  Profile → Security → API Keys). You never mint one or ask them to paste a
  password, only the API key.

```bash
# Outside Strongly: explicit host + API key.
curl -s -H "X-API-Key: $STRONGLY_API_KEY" "$HOST/api/v1/apps"
```

Either way the request shape (paths, bodies, envelope) is identical, only the
base URL and auth differ. Below, `$BASE` means `$STRONGLY_API_URL/api/v1` inside
Strongly or `$HOST/api/v1` outside.

**Scopes.** API keys carry scopes (`apps:write`, `apps:deploy`,
`workflows:write`, `artifacts:read`, …); a call returns `403 scope-required` if
the key lacks one. Tell the user which scope to add rather than working around
it. (In-cluster callers inherit the caller's own permissions.)

**Response envelope.** Success is `{ "success": true, "data": … }` (lists add
`pagination`). Errors are `{ "success": false, "error": { "code", "message" } }`
with a matching HTTP status. Read `data` on success; surface `error.message` on
failure.

**Discovery.** List endpoints (`GET /api/v1/<resource>`) accept `limit`,
`offset`, `sort`, and usually `search`. Resource ids are 24-char hex Mongo
ObjectIds; pass them in the path (`/api/v1/apps/<id>`).

## The three things that make Strongly apps different

If the task involves **apps**, three platform mechanics matter. Full detail is in
`references/apps.md`; the essentials:

- **The Strongly proxy.** Deployed apps are reached only through the platform
  proxy at a relative base path given by the `STRONGLY_URL` env var, never a
  bare port. Apps must serve from that base path (this is the usual cause of a
  blank React screen). The proxy is also the trust boundary.
- **Identity via one header.** The proxy injects the signed-in user as a JWT in
  `X-Strongly-User-Token` (and convenience `X-Strongly-User-*` headers). Apps
  **decode** it (they never see the signing secret) to know who the user is, with
  no login screen.
- **Wiring via `STRONGLY_SERVICES`.** Connected addons, data sources, AI models,
  and workflows arrive as a JSON env var `STRONGLY_SERVICES`. The app reads
  connection strings and model endpoints from there instead of hardcoding them.

## Feature routing

Read the matching reference before doing detailed work in that area:

| The user is asking about… | Read | Key REST prefixes (under `$BASE`) |
|---|---|---|
| Deploying/serving **apps**, the proxy, JWT identity, the manifest, artifacts | `references/apps.md` | `/apps`, `/artifacts` |
| **Addons** (managed Postgres/Mongo/Redis/… provisioned by Strongly) | `references/addons.md` | `/addons`, `/addon-types` |
| **Data sources** (connect EXTERNAL DBs/warehouses/object stores; data prep) | `references/datasources.md` | `/datasources`, `/data-forge` |
| **Agents** (deploy & chat with Strongly Agents) | `references/agents.md` | `/agents` |
| **Workflows** (build/run node graphs, batch + streaming) | `references/workflows.md` | `/workflows`, `/workflow-nodes`, `/executions`, `/streaming-workflows` |
| **MLOps** (AutoML, experiments, drift, fine-tuning, feature store, inference) | `references/mlops.md` | `/automl`, `/experiments`, `/drift`, `/fine-tuning`, `/feature-store` |
| **Model registry** (register/version/deploy models) | `references/model-registry.md` | `/model-registry` |
| **AI Gateway** (call 3rd-party & self-hosted models, keys, guardrails, analytics) | `references/ai-gateway.md` | `/ai/models`, `/ai/provider-keys`, `/ai/chat/completions`, `/guardrails` |
| **Compute** (workspaces, environments, clusters, node pools, volumes, code sessions) | `references/compute.md` | `/workspaces`, `/environments`, `/compute`, `/volumes`, `/code-sessions` |
| **Projects** (project + filesystem + Kanban board) | `references/projects.md` | `/projects`, `/board-cards` |
| **Governance** (policies, gates, evidence, guardrails) | `references/governance.md` | `/governance`, `/guardrails` |
| **FinOps** (costs, budgets, resource groups, schedules) | `references/finops.md` | `/finops` |
| **Marketplace** (browse & deploy offerings, metered usage) | `references/marketplace.md` | `/marketplace`, `/offering-usage` |
| **Library primitives** (memory, rules, prompts, tasks, skills, preferences) | `references/library.md` | `/memory`, `/rules`, `/prompts`, `/tasks`, `/skills`, `/preferences` |
| Doing any of the above **in Python** (e.g. inside a workspace or a training script) | `references/python-sdk.md` | the `strongly` package (`pip install strongly-ai`) |

Prefixes are a hint, not the contract: the reference for each area lists the exact
paths, methods, and params. Do not guess a path from the prefix. When you're
unsure which area a request falls in, list the relevant resource first
(`GET $BASE/apps`, `/agents`, `/workflows`, …) to orient, then load the reference.
