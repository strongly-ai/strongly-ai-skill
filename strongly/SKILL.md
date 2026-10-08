---
name: strongly
description: >-
  Help the user build on and operate the Strongly.AI platform through its REST
  API, deploying apps (behind the Strongly proxy, with JWT identity and
  artifacts), provisioning addons and data sources, running agents and
  workflows, and using MLOps, the model registry, and the AI Gateway. Use this
  whenever the user mentions Strongly, strongly.ai, a Strongly app/agent/
  workflow/addon/datasource/model, STRONGLY_SERVICES, the Strongly proxy, or an
  X-API-Key / X-Strongly-* header, and whenever you write or edit a
  strongly.manifest.yaml or build an app meant to run on Strongly, even before
  it is deployed.
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
  (an in-cluster address the platform sets, in every workspace, job and app); its
  REST API is `$STRONGLY_API_URL/api/v1`. Make every API call to it.
- **Links for the user use `$STRONGLY_BASE_URL`**, the platform's public address
  (e.g. `https://app.strongly.ai`). `$STRONGLY_API_URL` cannot be opened from a
  browser, so never give the user a link built from it. A workspace port:
  `$STRONGLY_BASE_URL/api/workspace-proxy/$STRONGLY_WORKSPACE_ID/port/3000/`;
  a deployed app: `$STRONGLY_BASE_URL/apps/<app id>/view`.
- **Auth is handled for you.** The platform injects the caller's bearer token on
  these in-cluster calls, so you do **not** set an `Authorization` header, and you
  do **not** ask the user for a key or host. A workspace holds no API key at all;
  API keys are only for calling Strongly from outside it. Just call the API.

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
`offset`, `sort`, and usually `search`. Resource ids are opaque strings
(for example `app-dk8s1o8gwr03`, `project-vHPyNBcx3RSxs6Nsv`, `yeqemejxnqn7it66n`):
take them from a list or create response, never build or guess one, and pass them
in the path (`/api/v1/apps/<id>`).

## The three things that make Strongly apps different

If the task involves **apps**, three platform mechanics matter. Full detail is in
`references/apps.md`; the essentials:

- **The Strongly proxy.** Apps are reached only through a platform proxy at a
  relative base path, never a bare port: `/api/proxy/<app>/` deployed,
  `/api/workspace-proxy/<workspace>/port/<port>/` while running in a workspace.
  The proxy strips that prefix and sends it as `X-Forwarded-Prefix`; apps build
  every URL from it (this is the usual cause of a blank React screen) and listen
  on `PORT`, else 3000. The proxy is also the trust boundary.
- **Identity via one header.** The proxy injects the signed-in user as a JWT in
  `X-Strongly-User-Token` (and convenience `X-Strongly-User-*` headers). Apps
  **decode** it (they never see the signing secret) to know who the user is, with
  no login screen.
- **Wiring via `STRONGLY_SERVICES`.** Connected addons, data sources, AI models,
  and workflows arrive as a JSON env var `STRONGLY_SERVICES`. The app reads
  connection strings and model endpoints from there instead of hardcoding them.

## The app manifest: never guess its fields

Every app has a `strongly.manifest.yaml` in its root, and the build refuses one
with an unknown field or an invalid `type`, naming it. Write it in this format
the first time, while you are building the app, not only when you deploy it:

```yaml
version: "1.0"
type: nodejs            # react | nodejs | static | fullstack | flask | rshiny | mcp_server | custom
name: my-app
description: What the app does

ports:
  - port: 3000          # the port the app listens on; PORT is set to it
    name: http

health_check:
  path: /health

runtime:
  command: npm start    # optional; how the app starts
```

`env[]` entries are a list of `{name, value}`, never a map. Volumes, addons, data
sources and AI models are connected on the app (`references/apps.md` §2 and §4),
never in this file. Read `references/apps.md` §6 for every key before adding any
other field.

## Feature routing

Read the matching reference before doing detailed work in that area:

| The user is asking about… | Read | Key REST prefixes (under `$BASE`) |
|---|---|---|
| Building, deploying or serving **apps**: writing `strongly.manifest.yaml`, the proxy, JWT identity, artifacts | `references/apps.md` | `/apps`, `/artifacts` |
| **Addons** (managed Postgres/Mongo/Redis/… provisioned by Strongly) | `references/addons.md` | `/addons`, `/addon-types` |
| **Data sources** (connect EXTERNAL DBs/warehouses/object stores; data prep) | `references/datasources.md` | `/datasources`, `/data-forge` |
| **Agents** (deploy & chat with Strongly Agents) | `references/agents.md` | `/agents` |
| **Workflows** (build/run node graphs, batch + streaming) | `references/workflows.md` | `/workflows`, `/workflow-nodes`, `/executions`, `/workflow-alerts`, `/streaming-workflows` |
| **MLOps** (AutoML, experiments, fine-tuning, feature store, inference) | `references/mlops.md` | `/automl`, `/experiments`, `/fine-tuning`, `/feature-store` |
| **Model registry** (register/version/deploy models) | `references/model-registry.md` | `/model-registry` |
| **Model evaluation** for registry models (prediction records, Record inputs, actuals, the model card) | `references/model-evaluation.md` | `/model-registry/models/:id/actuals`, `/model-registry/models/:id/monitoring`, `/drift/predictions` |
| **Drift** for registry models (baselines, analyses, results, schedule) | `references/drift.md` | `/drift`, `/model-registry/models/:id/baselines` |
| **AI Gateway** (call 3rd-party & self-hosted models, keys, guardrails, analytics) | `references/ai-gateway.md` | `/ai/models`, `/ai/provider-keys`, `/ai/chat/completions`, `/guardrails` |
| **Compute** (workspaces, environments, clusters, node pools, volumes, code sessions) | `references/compute.md` | `/workspaces`, `/environments`, `/compute`, `/volumes`, `/code-sessions` |
| **Projects** (project + filesystem + Kanban board) | `references/projects.md` | `/projects`, `/board-cards` |
| **Governance** (policies, gates, evidence, guardrails) | `references/governance.md` | `/governance`, `/guardrails` |
| **FinOps** (costs, budgets, resource groups, schedules) | `references/finops.md` | `/finops` |
| **Marketplace** (browse & deploy offerings, metered usage) | `references/marketplace.md` | `/marketplace`, `/offering-usage` |
| **Library primitives** (memory, rules, prompts, tasks, skills, preferences, pools) | `references/library.md` | `/memory`, `/rules`, `/prompts`, `/tasks`, `/skills`, `/preferences`, `/pools` |
| **Imprints** (installable skill + memory bundles) | `references/imprints.md` | `/imprints` |
| **A/B testing** (compare registry models on live traffic + experiments) | `references/ab-testing.md` | `/ab-tests` |
| **Avatars** (talking avatars: 3D, portrait, real-time lip-sync) | `references/avatars.md` | `/avatars` |
| **Account, org, notifications** (profile, members, credits, invitations, alerts) | `references/account.md` | `/users`, `/organizations`, `/notifications` |
| Doing any of the above **in Python** (e.g. inside a workspace or a training script) | `references/python-sdk.md` | the `strongly` package (`pip install strongly-ai`) |

Prefixes are a hint, not the contract: the reference for each area lists the exact
paths, methods, and params. Do not guess a path from the prefix. When you're
unsure which area a request falls in, list the relevant resource first
(`GET $BASE/apps`, `/agents`, `/workflows`, …) to orient, then load the reference.
