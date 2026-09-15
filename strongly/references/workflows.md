# Workflows

A Strongly **workflow** is a graph of **nodes** (trigger, sources, transforms, AI,
control-flow, destinations) wired by **connections**. The platform runs it two
ways: **batch** (a graph that runs to completion per trigger, the default) and
**streaming** (a long-lived real-time session, e.g. a voice agent). Everything is
reachable through `/api/v1`: discover node types, build the graph, validate, run
and verify, then deploy.

Read this when the task is: building or editing a node graph, running a workflow
and confirming its output, deploying it so a trigger URL goes live, or operating a
streaming (voice/real-time) workflow.

**Auth** follows `SKILL.md`. Show it once, send it on every call:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # outside Strongly
# Inside Strongly (workspace/app): BASE="$STRONGLY_API_URL/api/v1"; no auth header.
```

`$BASE` is whichever applies. Scopes used below: `workflows:read`,
`workflows:write`, `workflows:execute`; streaming adds `streaming-workflows:read`,
`streaming-workflows:deploy`, `streaming-sessions:read`, `streaming-sessions:write`.
Responses use the standard envelope (`data` on success, `error.message` on
failure). Ids are 24-char hex.

The happy path: **discover nodes -> build -> validate -> execute + poll to a real
passing run -> deploy -> relay the invocation URL.** Never report a workflow ready
off anything but a settled, non-empty execution.

---

## 1. Discover node types (never hardcode them)

The catalog is data, not a fixed list. Query it and match the user's intent to a
real `type` + `category`.

```bash
# Search the catalog (natural-language search works: "http request" -> api,
# "language model" -> llm, "loop over items" -> loop).
curl -s "${auth[@]}" "$BASE/workflow-nodes?search=loop&limit=10" | jq '.data'

# Filter by category or execution mode.
curl -s "${auth[@]}" "$BASE/workflow-nodes?category=triggers" | jq '.data'
curl -s "${auth[@]}" "$BASE/workflow-nodes?workflowType=streaming" | jq '.data'

# Get a node's full config schema + input/output definitions before you use it.
# Pass ?category for a type that exists as BOTH a source and a destination.
curl -s "${auth[@]}" "$BASE/workflow-nodes/postgresql/schema?category=destinations" | jq '.data'
```

Categories are `triggers`, `sources`, `transform`, `ai`, `agents`,
`control-flow`, `destinations`, `utilities`. Some connector types
(`postgresql`, `mysql`, `mongodb`, `s3`, ...) exist as **both** a source and a
destination with different fields, so disambiguate with `category`.

Wire real connections, not invented ones. List what the user actually has:

| Method | Path | Purpose |
|---|---|---|
| GET | `/workflow-nodes` | List/search node types (`search`, `category`, `type`, `workflowType`, `active`, `isSystem`, `limit`, `offset`) |
| GET | `/workflow-nodes/:type/schema` | Full config schema + I/O for a type (`?category` to disambiguate) |
| GET | `/workflow-nodes/:id` | One node type by id |
| GET | `/workflow-nodes/suggest-mappings` | Compare two types: source output fields, target input fields, suggested mappings (`sourceType`, `targetType`, optional categories) |
| GET | `/workflow-nodes/services/datasources` | Connected data sources usable as nodes |
| GET | `/workflow-nodes/services/addons` | Connected addons usable as nodes |
| GET | `/workflow-nodes/services/models` | AI models the gateway will serve (ranked) |
| GET | `/workflow-nodes/services/datasource-fields/:type` | Credential fields a datasource type needs |
| POST · PUT · DELETE | `/workflow-nodes` · `/workflow-nodes/:id` | Register/update/delete a REUSABLE custom node type. For one-off logic inside a single workflow, prefer the built-in `code` node instead. |
| POST | `/workflow-nodes/:id/duplicate` | Copy an existing node type into a new editable custom node ("copy & edit"), then edit it with `PUT` |

Data sources, addons, and models come from their own areas
(`references/datasources.md`, `references/addons.md`, `references/ai-gateway.md`);
the `services/*` routes above just list what is connectable as a node here.

The `llm` node's live output is at **`data.response`** (the model text), and its
model goes under **`config.model`** as a real model id from
`/workflow-nodes/services/models` (never a vendor name like `gpt-4o-mini`). If it
returns a JSON object, `response` is a JSON string, so add a `code` node to parse
it before downstream nodes read the fields.

---

## 2. Build a workflow in one call

`POST /workflows/build` submits the **complete graph at once**: every node (with
`config` and `inputMappings`) and every connection. Prefer it over creating an
empty workflow and adding nodes one at a time.

```bash
WID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{
    "name": "Enrich records",
    "nodes": [
      {"id":"in","type":"webhook"},
      {"id":"loop","type":"loop","inputMappings":{"items":"data.body.records"}},
      {"id":"llm","type":"llm","config":{"model":"<id from services/models>","prompt":"Summarize: {{item}}"}},
      {"id":"db","type":"postgresql","category":"destinations","config":{"table":"summaries"}}
    ],
    "connections": [
      {"source":"in","target":"loop"},
      {"source":"loop","target":"llm","sourcePort":"continue"},
      {"source":"llm","target":"db"}
    ]
  }' "$BASE/workflows/build" | jq -r '.data.workflowId')
```

Rules the build enforces (it rejects the graph with an actionable error otherwise):
- `id` is your own reference, reused in `connections`.
- A loop **body** edge hangs off `sourcePort: "continue"`.
- An **ambiguous** type (source-and-destination connectors) must set `category`
  (`"sources"` to read, `"destinations"` to write), or both nodes resolve to the
  same one and the write silently never happens.
- `inputMappings` paths are relative to the data arriving at the node (a webhook
  payload arrives under `data.body.<field>`); a wrong path yields empty output on
  a green run, so verify with a real execution.

Pass `"workflowType": "streaming"` to build a streaming graph (see section 6).

### Create or edit incrementally

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows` | Create (only `name` required; `description`, `status`, `workflowType`, `nodes`, `connections`, `tags`, `settings`) |
| GET | `/workflows` | List (`search`, `status`, `tag`, `limit`, `offset`); summaries only, no graph |
| GET | `/workflows/stats` | Workflow counts by status (total / active / paused / draft / archived) |
| GET | `/workflows/:id` | Full detail including all nodes and connections |
| PUT | `/workflows/:id` | Partial update (`name`, `description`, `status`, `tags`, `settings`, `deploymentEnvironmentId`) |
| DELETE | `/workflows/:id` | Delete (409 if deployed or running: undeploy and stop first) |
| POST | `/workflows/:id/duplicate` | Copy the workflow |
| POST | `/workflows/:id/nodes` | Add one node (`nodeType` required; `label`, `config`, `position`) |
| GET | `/workflows/:id/nodes` | List nodes with inbound/outbound connection counts |
| PUT | `/workflows/:id/nodes/:nodeId` | Set a node's `config` / `label` |
| DELETE | `/workflows/:id/nodes/:nodeId` | Remove a node and its connections |
| PUT | `/workflows/:id/nodes/:nodeId/input-mappings` | Set `inputMappings` (`{ targetField: "data.sourceField" }`) |
| PUT | `/workflows/:id/nodes/:nodeId/passthrough-values` | Set `passThroughValues` that copy straight from input to output (`values`) |
| POST | `/workflows/:id/connections` | Connect nodes (`sourceNodeId`, `targetNodeId`, `sourcePort`, `targetPort`; agent nodes use `targetPort` `"ai"` or `"tools"`; streaming feedback edges pair `feedback` with `maxIterations`) |
| DELETE | `/workflows/:id/connections/:connectionId` | Remove a connection (use a REAL id from `GET /workflows/:id`; never invent one) |
| POST | `/workflows/:id/layout` | Auto-arrange nodes left-to-right |

Templates: `GET /workflows/templates`, `POST /workflows/from-template`
(`templateId`), `POST /workflows/:id/save-as-template`. Sharing:
`GET·POST /workflows/:id/share`, `DELETE /workflows/:id/share/:userId`.
Versions: `GET·POST /workflows/:id/versions` (a commit takes a `message`; the
platform assigns the integer `versionNumber`), `GET /workflows/:id/versions/:versionId`
(one version plus its full `.strongly.json` definition), and
`POST /workflows/:id/deploy-version` (`versionId`) to roll back or promote a saved
version as the live deployment (202; poll status).

---

## 3. Validate before deploying

Two complementary checks. Run **both**; `valid: false` or a structural error means
deploy would fail.

```bash
curl -s -X POST "${auth[@]}" "$BASE/workflows/$WID/validate"          | jq '.data'  # control-flow / loop wiring
curl -s -X POST "${auth[@]}" "$BASE/workflows/$WID/validate-structure" | jq '.data'  # broken/disconnected/missing-trigger
```

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/:id/validate` | Control-flow and loop wiring; returns errors with messages, suggestions, machine-readable fixes |
| POST | `/workflows/:id/validate-structure` | Structural checks: broken connections, disconnected nodes, missing trigger, unconfigured service nodes |

---

## 4. Run (batch) and poll to a real result

`POST /workflows/:id/execute` test-runs the workflow. It waits briefly and, when
the run settles fast, returns a compact per-node `outputs` preview inline. If it is
still `running`, poll to a terminal state before claiming anything.

```bash
# Trigger. triggerInputs matches the trigger payload; for a webhook/rest-api
# trigger a flat body is auto-wrapped, and the payload lands under data.body.
EID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"triggerInputs":{"records":[{"id":1,"text":"hello"}]}}' \
  "$BASE/workflows/$WID/execute" | jq -r '.data.executionId')

# Poll to terminal. get_execution_status SETTLES: it waits up to ~9s and on
# completion returns the per-node outputs preview + a nextAction hint.
curl -s "${auth[@]}" "$BASE/executions/$EID/progress" | jq '.data'
# -> repeat while .status is "running"; stop at completed | failed | cancelled.

# On completion, read the full per-node outputs and VERIFY they are non-empty.
curl -s "${auth[@]}" "$BASE/executions/$EID" | jq '.data.outputs'

# On failure, read the per-node error (error_message is on the failed span).
curl -s "${auth[@]}" "$BASE/executions/$EID/spans?status=failed" | jq '.data'
```

A workflow is capped at **3 in-flight executions**; a 4th returns `429
concurrency-limit`. These are your disposable test runs, so cancel one
(`POST /executions/:id/cancel`) and re-run the same input rather than waiting.

### Execution endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/:id/execute` | Test-run with `triggerInputs`; returns `{executionId, status, outputs, invocation?}` |
| POST | `/workflows/:id/enqueue` | Run via a queue-trigger node (`message`, `priority`) |
| POST | `/workflows/:id/email-trigger` | Run via an email-trigger node (`from`, `to`, `subject`, `body_text`) |
| GET | `/executions` | List runs (`workflow_id`, `status`, `trigger_type`, `since`, `until`, `limit`, `offset`) |
| GET | `/executions/:id` | Full execution: definition + per-node `outputs` |
| GET | `/executions/:id/progress` | Status + progress; **settles** the run and returns the outputs preview on completion |
| GET | `/executions/:id/spans` | Per-node spans; read `error_message` here on failure (`node_id`, `name`, `status`, `slim`, `limit`) |
| GET | `/executions/:id/logs` | Execution logs (`level`, `limit`) |
| POST | `/executions/:id/stop` | Graceful stop (only when `running`) |
| POST | `/executions/:id/cancel` | Hard-cancel any non-terminal run; idempotent |
| POST | `/executions/:id/resume` | Resume a failed/paused run (`trigger_data`) |
| GET · POST | `/executions/:id/pending-inputs` · `/executions/:id/input` | Discover, then answer, a run waiting for external input (`request_id`, `data`) |

---

## 5. Deploy and operate (batch)

Deploy is **async**: it returns `202`, then the K8s controller works for ~30s to a
few minutes. Poll status; gate readiness on `health.replicas.ready >= 1`.

```bash
curl -s -X POST "${auth[@]}" "$BASE/workflows/$WID/deploy"    # 202 Accepted

# Poll: deploymentStatus queued -> deploying -> active | failed.
curl -s "${auth[@]}" "$BASE/workflows/$WID/status" | jq '.data'
```

The `status` response carries an **`invocation`** block once a trigger exists:
after a successful deploy, relay `invocation.url`, the auth mode(s), and the exact
signing header to the user, so they can actually call their workflow. For a webhook
whose `secretConfigured` is false, set `config.secret` first or callers get a 401.

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/:id/deploy` | Deploy to production (202; poll status) |
| GET | `/workflows/:id/status` | Deployment status, pod/replica health, and the `invocation` block |
| POST | `/workflows/:id/stop` | Scale to zero, $0 cost, deployment preserved (202) |
| POST | `/workflows/:id/start` | Scale a stopped workflow back up (202; `replicas`) |
| POST | `/workflows/:id/undeploy` | Tear down the pod |
| PUT | `/workflows/:id/status` | Set the workflow status (`draft`, `active`, `paused`, `archived`) |
| GET · PUT | `/workflows/:id/lifecycle` | Get / set the lifecycle policy (`always-on`, `idle-shutdown`, `on-demand`, `scheduled-window`; PUT takes `type`, `idleTimeoutMinutes`, `schedule`) |
| GET | `/workflows/:id/logs` | Recent worker pod logs (`lines`, `container`) |
| GET | `/workflows/:id/metrics` | Aggregated run metrics (`window` = `1h`/`24h`/`7d`/`30d`) |

To delete: undeploy, stop any running execution, then `DELETE /workflows/:id`.

---

## 6. Streaming workflows (real-time sessions)

Streaming workflows (`workflowType: "streaming"`, e.g. a voice agent) run as a
long-lived **session** against a deployment, not as a batch execution. Build them
with the same node tools (filter the catalog with `workflowType=streaming`), then
use the streaming surface to deploy, start a session, drive it, and inspect it.

```bash
# Deploy (202; poll the deployments list until a replica is ready).
curl -s -X POST "${auth[@]}" "$BASE/streaming-workflows/$WID/deploy"
curl -s "${auth[@]}" "$BASE/streaming-workflows/$WID/deployments" | jq '.data'

# Start a session. Returns session_id + ws_url (Meteor WS proxy) + ws_token.
SID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"workflowId\":\"$WID\"}" "$BASE/streaming-sessions" | jq -r '.data.session_id')

# Gate readiness on the live pod health before connecting the WS.
curl -s "${auth[@]}" "$BASE/streaming-sessions/$SID/status" | jq '.data.deployment.health.replicas'

# Inspect a session, then end it.
curl -s "${auth[@]}" "$BASE/streaming-sessions/$SID/transcript" | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/streaming-sessions/$SID"
```

| Method | Path | Purpose |
|---|---|---|
| GET | `/streaming-workflows` · `/streaming-workflows/:id` | List / get streaming workflows |
| POST | `/streaming-workflows/:id/deploy` | Deploy (202; body `cpu`, `memory`, `disk`, `gpu`, `gpu_type`, `idle_timeout_seconds`, `max_session_duration_seconds`, `max_concurrent_sessions`) |
| POST | `/streaming-workflows/:id/undeploy` | Tear down; return to draft |
| GET | `/streaming-workflows/:id/deployments` · `/sessions` | Deployments (readiness) / sessions for a workflow |
| POST | `/streaming-sessions` | Start a session (`workflowId` required); returns `session_id`, `ws_url`, `ws_token` |
| GET | `/streaming-sessions` · `/streaming-sessions/:id` | List / get sessions |
| GET | `/streaming-sessions/:id/status` | Live deployment readiness (gate on `deployment.health.replicas.ready >= 1`) |
| POST | `/streaming-sessions/:id/inject` | Inject a text message (`text` required, `role`) |
| DELETE | `/streaming-sessions/:id` | End the live session |
| GET | `/streaming-sessions/:id/transcript` · `/logs` · `/recordings` · `/errors` · `/handoffs` | Inspect a session; `errors` is the first stop when a voice session misbehaves |

---

## 7. Export / import

A workflow is portable as a single `.strongly.json` document: every node with its
full config, the connections, settings, scopes, workflow type, mode, environment
pin, and metadata. It is the same artefact a version commit holds (the definition
returned by `GET /workflows/:id/versions/:versionId`, section 2).

```bash
# Export -> the .strongly.json body (the response also sets Content-Disposition
# for a browser download).
curl -s "${auth[@]}" "$BASE/workflows/$WID/export" | jq '.data' > workflow.strongly.json

# Import is two calls. FIRST (no resolvedDeps) VALIDATES and returns the
# dependencies it needs mapped (data sources, addons, models, custom nodes).
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"exportData\": $(cat workflow.strongly.json)}" \
  "$BASE/workflows/import" | jq '.data'

# SECOND, with resolvedDeps filled in, EXECUTES the import (201) and creates the
# new workflow.
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"exportData": {...}, "resolvedDeps": {...}}' "$BASE/workflows/import" | jq '.data'
```

| Method | Path | Purpose |
|---|---|---|
| GET | `/workflows/:id/export` | Export the workflow as a `.strongly.json` document |
| POST | `/workflows/import` | Import from `.strongly.json` (`exportData`; call once to validate + list dependencies, again with `resolvedDeps` to create the workflow) |

---

## Checklist
- [ ] Node types discovered from `/workflow-nodes` (searched, not hardcoded); ambiguous connectors given a `category`.
- [ ] Graph built with `/workflows/build` (nodes + connections in one call); `inputMappings` paths match the arriving data.
- [ ] `llm` nodes: real model id under `config.model`; downstream reads `data.response`.
- [ ] Both `validate` and `validate-structure` pass before deploy.
- [ ] Executed with real `triggerInputs` and **polled to a terminal state**; outputs verified non-empty; failures read from `/executions/:id/spans`.
- [ ] Deploy is 202 + poll `/workflows/:id/status` to `deploymentStatus: active` and `health.replicas.ready >= 1` before claiming success.
- [ ] Invocation URL, auth mode, and signing header relayed to the user; webhook `config.secret` set if a signed caller needs it.
- [ ] Streaming: deployed, session readiness gated on live pod health, session ended after testing.
- [ ] Cleanup: undeploy and stop before `DELETE`.
