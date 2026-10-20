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
Responses use the standard envelope (see `SKILL.md`): `data` on success, lists page with `cursor` / `meta.nextCursor`, and a failure is problem details whose `detail` and `code` to surface. Ids are opaque strings: take them from a list or create response.

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
curl -s "${auth[@]}" "$BASE/workflow-nodes?q=loop&limit=10" | jq '.data'

# Filter by category or execution mode.
curl -s "${auth[@]}" "$BASE/workflow-nodes?category=triggers" | jq '.data'
curl -s "${auth[@]}" "$BASE/workflow-nodes?workflowType=streaming" | jq '.data'

# Get a node's full config schema + input/output definitions before you use it.
# Pass ?category for a type that exists as BOTH a source and a destination.
curl -s "${auth[@]}" "$BASE/workflow-nodes/postgresql/schema?category=destinations" | jq '.data'
```

**Search the catalog before writing code.** For every step you would otherwise
put in a `code` node, search `/workflow-nodes?q=` for what the step DOES
(not "code"), in at least two phrasings ("parse JSON string" / "convert JSON
text to object"; "group and sum" / "aggregate by key"; "look up a value" /
"join two datasets"; "compare records"; "split text into chunks"; "parse CSV /
XML / Excel / PDF"), and use the node that does it. The catalog has ~480 nodes
(parsers, aggregation, lookup, merge, compare, chunking, formatting and more);
input mappings and `set-fields` also cover most reshaping with no extra node.
Use a `code` node only when those searches find nothing that does the step, and
say which searches you ran.

Categories are `triggers`, `sources`, `transform`, `ai`, `agents`,
`control-flow`, `destinations`, `utilities`. Some connector types
(`postgresql`, `mysql`, `mongodb`, `s3`, ...) exist as **both** a source and a
destination with different fields, so disambiguate with `category`.

Wire real connections, not invented ones. List what the user actually has:

| Method | Path | Purpose |
|---|---|---|
| GET | `/workflow-nodes` | List/search node types (`q`, `category`, `type`, `workflowType`, `active`, `isSystem`, `limit`, `cursor`) |
| GET | `/workflow-nodes/:id/schema` | Full config schema + I/O for a type (`?category` to disambiguate) |
| GET | `/workflow-nodes/:id` | One node type by id |
| GET | `/workflow-nodes/suggest-mappings` | Compare two types: source output fields, target input fields, suggested mappings (`sourceType`, `targetType`, optional categories) |
| GET | `/workflow-nodes/services/data-sources` | Connected data sources usable as nodes |
| GET | `/workflow-nodes/services/addons` | Connected addons usable as nodes |
| GET | `/workflow-nodes/services/models` | AI models the gateway will serve (ranked) |
| GET | `/workflow-nodes/services/data-source-fields/:id` | Credential fields a datasource type needs |
| POST · PUT · DELETE | `/workflow-nodes` · `/workflow-nodes/:id` | Register/update/delete a REUSABLE custom node type. For one-off logic inside a single workflow that no catalog node does, use the built-in `code` node instead. |
| POST | `/workflow-nodes/:id/duplicate` | Copy an existing node type into a new editable custom node ("copy & edit"), then edit it with `PATCH` |

Data sources, addons, and models come from their own areas
(`references/datasources.md`, `references/addons.md`, `references/ai-gateway.md`);
the `services/*` routes above just list what is connectable as a node here.

A custom node's packages (`functionDefinition.pipDependencies`, requirements.txt
format) install once per worker pod for each node version, shared by every item
running in parallel. Its code (and that of `code`, `exec`, `code-interpreter`,
`web-agent` and `ssh`'s clients; ssh upload/download carry `content`, no local paths) runs in the pod's sandbox container (`exec` has no `cwd`; env = PATH,
LANG, LC_ALL, TERM, TMPDIR, USER plus its `env` input): no cloud or cluster identity, none of the worker's env; platform calls
(storage, state, metrics, connected nodes) work through the worker. `self.get_addon()`
/ `self.get_datasource()` see only the add-ons and data sources its own config names
(`addonId`, `dataSourceId`, or a key ending in `AddonId`/`DataSourceId`). The Milvus source, destination and Semantic Memory nodes are
safe inside a Loop or Map with several parallel workers and pods.

The `llm` node's live output is at **`data.response`** (the model text), and its
model goes under **`config.model`** as a real model id from
`/workflow-nodes/services/models` (never a vendor name like `gpt-4o-mini`). If it
returns a JSON object (`config.defaultResponseFormat: "json_object"`), `response`
is a JSON string, so add a `json-parser` node with `inputMappings
{"text": "data.response"}`: its output `data` is the parsed object, so
downstream nodes read `data.<field>`.

A `code` node can log its own run metrics: `metric(name, value, unit)` in its
Python (e.g. `metric("values redacted", n, "count")`) records a span metric with
the node as source, shown in the run's Execution Metrics. `value` is a finite
number, `unit` optional text; a bad argument fails the node. In
`runOnceForEachItem` each item's calls count. A metric is saved only when a node
logs it (`log_metric` in a node, `metric` in Code): the platform adds none of
its own, and token counts are not metrics (see the run's AI usage below).

---

## 2. Build a workflow in one call

`POST /workflows/build` submits the **complete graph at once**: every node (with
`config` and `inputMappings`) and every connection. Prefer it over creating an
empty workflow and adding nodes one at a time.

Every save, draft run and deploy pins each node to the latest published
version of its catalog node. `PATCH /workflows/:id` returns
`inputsNoLongerDeclared`: mappings to inputs a node's newer version dropped,
which now feed nothing; remap them.

An input that is also a setting (a database source's `query`, the REST API
source's `url`, Google Sheets' `spreadsheetId`/`range`) takes its mapped value
when `inputMappings` maps it, and the `config` value otherwise: map it to make
the setting come from upstream data.

```bash
WID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{
    "name": "Enrich records",
    "nodes": [
      {"id":"in","type":"webhook"},
      {"id":"loop","type":"loop","inputMappings":{"items":"data.body.records"}},
      {"id":"llm","type":"llm","config":{"model":"<id from services/models>","defaultSystemPrompt":"Summarize the text in two sentences."},
       "inputMappings":{"userPrompt":"data.currentItem.text"}},
      {"id":"acc","type":"merge","inputMappings":{"data":"data"}},
      {"id":"db","type":"postgresql","category":"destinations","config":{"table":"summaries"},"inputMappings":{"data":"data.data"}}
    ],
    "connections": [
      {"source":"in","target":"loop"},
      {"source":"loop","target":"llm","sourcePort":"continue"},
      {"source":"llm","target":"acc"},
      {"source":"loop","target":"acc","sourcePort":"completed"},
      {"source":"acc","target":"db"}
    ]
  }' "$BASE/workflows/build" | jq -r '.data._id')
```

Rules the build enforces (it rejects the graph with an actionable error otherwise):
- `id` is your own reference, reused in `connections`.
- An edge leaves from one of the source node's declared outputs (`get_node_schema`
  lists them), and that output is the branch it runs on: a Loop body hangs off
  `"continue"`, a Map body off `"output"`; Conditional uses `"if"` / `"else"`;
  Switch-Case uses `"case_0"`.. (one per entry of `config.cases`, in order) and
  `"default"`.
- A Loop or Map body ends in a Loop Accumulator (`merge`) that receives the body's
  last node; the workflow continues from the accumulator. The loop returns there
  on its own: never connect the Loop or Map itself to the accumulator (on the
  canvas an iterator has one output handle, its body). The builder canvas
  frames exactly that body.
- The loop ends at the FIRST Loop Accumulator its body reaches. Only a `merge`
  ends a loop: `aggregate`, `data-aggregator`, `merge-data`, `consensus` and
  `priority-queue` are ordinary steps, so put one after the accumulator to work
  on every item's result (`inputMappings: {"data": "data.data"}`). Every body
  path that reaches an accumulator reaches the same one (validation names them
  otherwise); a branch inside the body rejoins at a plain step, never at a
  merge; a nested loop ends at its own accumulator and the outer body goes on.
- To spread a loop's items over pods, set its `config.scaling`:
  `{"enabled": true, "maxPods": 3, "targetItemsPerPod": 50, "maxWorkers": 4, "retryAttempts": 2}`.
  Pods = ceil(items / `targetItemsPerPod`), at most `maxPods` (default 10, counts
  the workflow's own pod); `maxWorkers` is threads per worker pod (default 10);
  `retryAttempts` is optional. Worker pods are sized to the largest resources of
  the loop body's nodes. A map runs in the workflow's pod only: its concurrency is
  its own `config.maxWorkers` (default 10), `config.inputArrayPath` is the path
  to the array in its mapped inputs (`items`, or e.g. `data.rows` with `data`
  mapped), and `config.maxItems` keeps the first N (0 = all).
- A Goal Loop (and a While Loop) body hangs off `"continue"` and ends in an
  accumulator, where the loop returns on its own once it ends; never connect the
  loop itself to the accumulator.
- Parallel Branch runs the branches wired from its `"output"` at the same time
  (`config.maxWorkers`, default 10); a node every branch feeds (e.g. a merge with
  `inputMappings: {"data": "data"}`) is their join and runs after them. A branch
  cannot hold a Loop or Map.
- Retry re-runs the one node wired into its input until it succeeds
  (`config.maxRetries`, `retryDelay`, `backoffType`); wire the next step from
  `"success"` and the failure path from `"failed"`. That node's failure does not
  stop the run. Wait holds the run (`config.mode` `delay` + `duration` seconds,
  or `until` + `untilTime`). Stop and Error always stops the run.
- An **ambiguous** type (source-and-destination connectors) must set `category`
  (`"sources"` to read, `"destinations"` to write), or both nodes resolve to the
  same one and the write silently never happens.
- `inputMappings` paths are relative to the data arriving at the node (a webhook
  payload arrives under `data.body.<field>`); a wrong path yields empty output on
  a green run, so verify with a real execution.
- The run's inputs (a webhook's request, an app's or REST call's `triggerInputs`)
  reach the trigger node, which outputs them. Every node also gets the run's own
  parameters, without the request's headers and signature, at
  `inputs.workflow_inputs` (mapping path `$root.<path>`); never as loose inputs.
- `continueOnError` is a node parameter in its config (`PATCH` the node; the Loop
  shows it as Continue on Iteration Error). A node whose required input is
  missing or empty FAILS ("required input missing: <name>"); only a node on a
  conditional branch that did not run is skipped.
- To call a Strongly app on this platform, use the REST API node (`api`) with
  `config.target: "app"`, `appId` (the app's id) and `appPath` (or map the
  `appPath` input). It calls the app's in-cluster route as the run's owner (the
  app gets their `X-Strongly-User-Token`); no auth settings. An External URL on
  the platform's public address under `/api/proxy/` is refused: a workflow
  cannot sign in there (401).
- A node's resources are `config.resourcesOverride` `{cpu, memory, gpu, gpuType,
  disk}` (the Resources tab; memory/disk in Mi/Gi); unset fields use the
  definition's defaults.
- Give each config field the shape its schema type saves: `tags`/`multiselect`
  a list of strings, `fieldBuilder`/`array` a list of objects (Data Aggregator
  `operations`, Notification `channels`), `keyValue`/`object`/`json` an object
  (API Caller `defaultHeaders`). A `code` field with `language: json` (Edit
  Fields `jsonData`, a Mongo filter) is JSON text, so `$`-prefixed keys are
  kept. For `json`/`object` fields JSON text is also parsed before the node
  runs; text that is not valid JSON fails the node naming the field.
- There is **no `{{ }}` templating** in node configs or mappings: data reaches a node
  only through `inputMappings` paths into its directly connected upstream node's
  output. A loop body node reads the current item at `data.currentItem`; the node
  after a Loop Accumulator reads the collected array at `data.data` (count at
  `data.count`). Only a few nodes substitute `{{name}}` inside their own template
  fields (Send Email, Notification, Exchange, PDF Generator, String Transform).
- A node that connects to a database, queue or store takes the connection only by id:
  `dataSourceId` (a data source), or, for the platform's add-on types (PostgreSQL,
  MySQL, MongoDB, Redis, Neo4j, Milvus, RabbitMQ, Greenplum, SurrealDB, Kafka, MQTT;
  a DuckDB add-on is picked in the PostgreSQL source and destination),
  `connectionType` `addon` + `addonId` or `datasource` + `dataSourceId`. The run
  receives it through STRONGLY_SERVICES; a node never takes a host or password. An
  unset `connectionType` runs as the default its definition shows.

Pass `"workflowType": "streaming"` to build a streaming graph (see section 6).

### How runs execute
- A **draft** run (workflow not deployed) runs on the caller's own worker pool: 2
  pre-warmed workers while they are in the builder, one worker per run, removed
  after it. A run needing more than 1 vCPU / 1 GB, or reaching data sources or
  add-ons, gets a worker started for it (allow up to a minute). Deployed runs use
  the deployment. One in-flight run per workflow unless its concurrency is raised.
- An unscaled (sequential) loop's trace is one `LOOP` span for the whole loop;
  its control passes sit under it and each item's body spans under that item's
  `ITERATION` span ("Iteration N", failed when the item errored). A node span
  starts when the node does (its code load included).
- Loop Pod Scaling works in draft and deployed runs alike; the trace has a
  `DISTRIBUTED` span for the loop (at every tracing level but off), every body
  span is drawn under it by worker pod and item, and the accumulator collects
  every item. A body span's `mapped_input` is what the item received (its
  mappings and `data.currentItem`), never the node's settings; its
  `_metadata.loops` carries the loop's `currentIteration`/`totalIterations`
  as in an unscaled loop. Each node span has `duration_ms` (wall time) and
  `cpu_ms` (the node's own CPU, its sandbox's included), and a body span
  `metadata.concurrent_items` (items its pod ran at once). A worker pod runs
  `maxWorkers` items as threads on the pod's CPU: CPU-bound items (PDF
  parsing) gain nothing from more threads, only from more CPU or more pods.
- Node data is cached in three tiers (memory for items up to 100 KB, pod disk up to
  10 MB, object storage for everything, shared across pods). Nothing to configure.
  A run's cache is deleted 24 h after it ends, except the newest finished run of
  each workflow (kept for resume).
- Built-in nodes log **metrics** with `log_metric` (judge scores, `rows_affected`,
  item counts, an LLM call's `response_time_ms`): each span's `metrics` in
  `/workflows/-/executions/:id/spans`, at the level the node gave. Nothing else is
  a metric. A run's tokens are the AI Gateway's:
  `GET /workflows/-/executions/:id/ai-usage` (requests, input/output/total
  tokens, per model).

### Create or edit incrementally

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows` | Create (only `name` required; `description`, `status`, `workflowType`, `nodes`, `connections`, `tags`, `settings`) |
| GET | `/workflows` | List (`q`, `status`, `tag`, `limit`, `cursor`); summaries only, no graph; templates are not listed |
| GET | `/workflows/stats` | Workflow counts, templates not counted: by state (total / active / paused / draft / archived; an agent is active while it runs) and by kind (batch / streaming / agents, adding up to total) |
| GET | `/workflows/:id` | Full detail including all nodes and connections |
| PATCH | `/workflows/:id` | Partial update (`name`, `description`, `status`, `tags`, `settings`, `deploymentEnvironmentId`, `environmentVariables`) |
| DELETE | `/workflows/:id` | Delete (409 if deployed or running: undeploy and stop first). An agent's workflow is deleted as the agent (`DELETE /agents/:id`) |
| POST | `/workflows/:id/duplicate` | Copy the workflow; returns the copy |
| POST | `/workflows/:id/nodes` | Add one node (`nodeType` required; `label`, `config`, `position`) |
| GET | `/workflows/:id/nodes` | List nodes with inbound/outbound connection counts |
| PATCH | `/workflows/:workflowId/nodes/:id` | Set a node's `config` / `label`: `config` keys you send replace those keys whole, a key sent as `null` is removed, the rest stay |
| DELETE | `/workflows/:workflowId/nodes/:id` | Remove a node and its connections (`204`) |
| PUT | `/workflows/:workflowId/nodes/:id/input-mappings` | Set `inputMappings` (`{ targetField: "data.sourceField" }`), saved to `node.data.inputMappings`, the one place the builder and the run read them (`GET /workflows/:id` shows them there) |
| PUT | `/workflows/:workflowId/nodes/:id/passthrough-values` | Set `passThroughValues` (`values`: `{outputKey: "inputName"}`, saved to `node.config`): copies the node's input `inputName` (one of its `inputMappings` keys, so map it first) into its output as `data.<outputKey>` |
| POST | `/workflows/:id/connections` | Connect nodes (`sourceNodeId`, `targetNodeId`, `sourcePort`, `targetPort`; agent nodes use `targetPort` `"ai"` or `"tools"`; streaming feedback edges pair `feedback` with `maxIterations`) |
| DELETE | `/workflows/:workflowId/connections/:id` | Remove a connection (`204`; use a REAL id from `GET /workflows/:id`; never invent one) |
| POST | `/workflows/:id/arrange` | Auto-arrange nodes left-to-right |

Templates (including the platform's public `scaffold` starters) are listed only by
`GET /workflows/templates`; `POST /workflows/from-template`
(`templateId`), `POST /workflows/:id/save-as-template`. Sharing:
`GET·PATCH /workflows/:id/permissions` (owner, members, `visibility`),
`POST /workflows/:id/permissions/members` `{ userId, role }`,
`DELETE /workflows/:workflowId/permissions/members/:userId`. An agent
(`mode: 'agent'`) is never shared: those calls refuse it (409), and only its owner
(and admins) reach it.
Versions: `GET·POST /workflows/:id/versions` (a commit takes a `message`; the
platform assigns the integer `versionNumber`), `GET /workflows/:workflowId/versions/:id`
(one version plus its full `.strongly.json` definition), and
`POST /workflows/:workflowId/versions/:id/deploy` to roll back or promote a saved
version as the live deployment (202; poll status).

---

## 3. Validate before deploying

Two complementary checks. Run **both**; `valid: false` or a structural error means
deploy would fail.

```bash
curl -s -X POST "${auth[@]}" "$BASE/workflows/$WID/validate"          | jq '.data'  # control-flow / loop wiring
curl -s -X POST "${auth[@]}" "$BASE/workflows/$WID/structure-check" | jq '.data'  # broken/disconnected/missing-trigger
```

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/:id/validate` | Control-flow and loop wiring; returns errors with messages, suggestions, machine-readable fixes |
| GET | `/workflows/:id/structure-check` | Structural checks: broken connections, disconnected nodes, missing trigger, unconfigured service nodes |

---

## 4. Run (batch) and poll to a real result

`POST /workflows/:id/execute` test-runs a draft (runs are for drafts: a deployed
workflow runs only when its triggers fire, so a hand-started run of one is refused,
409; undeploy to test a change). It waits briefly and, when
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
curl -s "${auth[@]}" "$BASE/workflows/-/executions/$EID/progress" | jq '.data'
# -> repeat while .status is "pending" or "running"; it ends completed |
#    completed_with_gaps | partial_success | failed | stopped | cancelled.
#    A node that failed under continueOnError, or a loop/map whose items partly
#    failed, ends partial_success; a loop whose items all failed ends failed.
#    error_message names each: "Score failed: ValueError ...; loop: 6 of 12 items failed".

# On completion, read the full per-node outputs and VERIFY they are non-empty.
curl -s "${auth[@]}" "$BASE/workflows/-/executions/$EID" | jq '.data.outputs'

# On failure, read the per-node error (error_message is on the failed span).
# Spans are a cursor-paged list, oldest first: meta.total counts them, and
# meta.nextCursor (as ?cursor=) reaches the next page.
curl -s "${auth[@]}" "$BASE/workflows/-/executions/$EID/spans?status=failed" | jq '.data'
```

A workflow is capped at **3 in-flight executions**; a 4th returns `429
concurrency-limit`. These are your disposable test runs, so cancel one
(`POST /workflows/-/executions/:id/cancel`) and re-run the same input rather than waiting.

### A run waiting for a person

Wait for Input, Human Feedback and Human Checkpoint keep a run `running` until
someone answers. `GET /workflows/-/executions/:id/human-requests` lists each pending request
with `type`, `requestId`, `nodeId` and what it asks. Answer with
`POST /workflows/-/executions/:executionId/human-requests/:id/respond` `{data}`: `input` takes any JSON
(matching the node's input schema when set); `feedback` takes text, a rating
from 1 to `ratingScale`, one of `choices`, or a form object; `checkpoint` takes
`{"decision": "approved" | "rejected", "message", "input"}` and only from an
approver when `approvers` are set. Never decide a checkpoint for the user.
In the builder the same requests show in the **Waiting for you** panel.

### Execution endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/:id/execute` | Test-run a draft with `triggerInputs`; returns `{executionId, status, outputs, invocation?}`. A deployed workflow: 409 |
| GET | `/workflows/-/executions` | List runs (`status`, `triggerType`, `since`, `until`, `limit`, `cursor`); one workflow's runs are `/workflows/:id/executions` |
| GET | `/workflows/-/executions/:id` | Full execution: definition + per-node `outputs` |
| GET | `/workflows/-/executions/:id/progress` | Status + progress; **settles** the run and returns the outputs preview on completion |
| GET | `/workflows/-/executions/:id/spans` | Per-node spans, oldest first, cursor-paged; read `error_message` here on failure (`nodeId`, `name`, `status`, `slim`, `limit`, `cursor`) |
| GET | `/workflows/-/executions/:id/logs` | Execution logs (`level`, `limit`) |
| GET | `/workflows/-/executions/:id/ai-usage` | The run's AI Gateway usage: requests and input/output/total tokens, in all and per model (the run's one token figure) |
| POST | `/workflows/-/executions/:id/stop` | Graceful stop (only when `running`) |
| POST | `/workflows/-/executions/:id/cancel` | Hard-cancel any non-terminal run; idempotent |
| POST | `/workflows/-/executions/:id/resume` | Resume a failed/paused run (`trigger_data`) |
| GET · POST | `/workflows/-/executions/:id/human-requests` · `/workflows/-/executions/:executionId/human-requests/:id/respond` | Discover, then answer, what a running run waits on from a person (Wait for Input, Human Feedback, Human Checkpoint); the answer's `data` is shaped by the request type (see above) |
| POST | `/workflows/-/executions/:executionId/human-requests/:id/notify` | Send a waiting request's notification again |
| GET | `/workflows/:workflowId/dead-letters` | Runs that could not be submitted (dead letters) of a workflow, or of every workflow with `-`; `status` filters (`pending`, `retrying`, `resolved`, `exhausted`, `discarded`) |
| GET · POST | `/workflows/-/dead-letters/:id` · `…/:id/retry` · `…/:id/discard` | One dead letter; retry it now as you, or give up on it (`notes`) |

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
A webhook with a Respond to Webhook node answers the caller with that node's
status, headers and body once it runs (the request waits); without one it
answers `{success, executionId}` at once. A Sub-Workflow node's child run has
trigger `sub-workflow` and records its parent (`parentExecutionId` on
`POST /workflows/:id/execute`).
A generic webhook signs `X-Webhook-Signature: sha256=<hex HMAC of the raw body>`;
with `config.requireTimestamp` on, the caller also sends `X-Webhook-Timestamp`
(Unix seconds) and signs `"<timestamp>.<raw body>"`, and a timestamp more than
`config.maxTimestampAge` seconds either side of now is refused (401).
A **Form** trigger's block gives its public URL (`POST /api/v1/forms/<id>`, no auth,
multipart or JSON) and `captcha`: with CAPTCHA on, `config.captchaSecretKey` must be
set or every submission is refused. A refused submission tells the submitter only
"busy" (409), "not accepting submissions" (402) or "Submission failed". A **Schedule** trigger's block gives the
schedule as it runs (`cron`, `dailyTime` or `intervalMinutes`, plus `timezone`);
it runs only while deployed, and undeploying stops it. **Email**, **RSS** and **File**
triggers poll: the deployed workflow checks the mailbox / feed / S3 location every
`config.pollInterval` minutes (same even intervals; default 15) and runs with only
what is new; their block gives `pollIntervalMinutes` and no URL. A **Queue** trigger
consumes its SQS / RabbitMQ / Kafka queue (`config.connectionType` `datasource` +
`dataSourceId`, or `addon` + `addonId` for a RabbitMQ or Kafka add-on; `config.queue` for RabbitMQ/Kafka) and runs once
per message, up to `maxConcurrentExecutions` (1-10, default 1, set with `PATCH
/workflows/:id`); its lifecycle must be `always-on` or `scheduled-window`. Put messages on
the queue itself (an sqs-dest / rabbitmq-dest / kafka-dest node), not through the API.

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/:id/deploy` | Deploy to production (202; poll status). Body optional: `environmentId`, `cpu`/`memory`/`disk`, `gpu`/`gpuType`, `useSpot` (the deployed worker on spot capacity) + `spotFallback` (default true: on-demand when no spot is free); a redeploy keeps the last spot choice. `autoscaling` `{minReplicas, maxReplicas, executionsPerReplica}` (each 1-50): pods added for runs that find no room, idle ones given back (never a busy one); run limit becomes maxReplicas x executionsPerReplica; `null` = one pod (10 runs at once); omitted keeps the last; refused for schedule-only workflows |
| GET | `/workflows/:id/status` | Deployment status, pod/replica health, and the `invocation` block |
| POST | `/workflows/:id/stop` | Scale to zero, $0 cost, deployment preserved (202) |
| POST | `/workflows/:id/start` | Scale a stopped workflow back up (202; `replicas`) |
| POST | `/workflows/:id/undeploy` | Tear down the pod |
| PATCH | `/workflows/:id` | Set the workflow `status` (`draft`, `active`, `paused`, `archived`), with any other field |
| GET · PUT | `/workflows/:id/lifecycle` | Get / set the lifecycle policy (`always-on`, `idle-shutdown`, `on-demand`, `scheduled-window`; PUT takes `type`, `idleTimeoutMinutes`, `schedule`) |
| GET | `/workflows/:id/logs` | Recent worker pod logs (`lines`, `container`) |
| GET | `/workflows/:id/metrics` | Aggregated run metrics (`window` = `1h`/`24h`/`7d`/`30d`) |

To delete: undeploy, stop any running execution, then `DELETE /workflows/:id`.

### Environment variables (batch)

A batch workflow has its own environment variables, for the code its author
supplies: custom nodes and the code node read them with `os.environ`. Use them
for a key or setting that code needs; an add-on's or data source's credentials
reach a node through STRONGLY_SERVICES when its config names it, not here.

```bash
# Patched name by name (JSON Merge Patch of the map): a string sets a name,
# null removes it, names left out are kept; "environmentVariables": null
# removes them all. Allowed on a DEPLOYED workflow: its worker rolls with the
# change (a new worker starts with it before the old one goes, no downtime).
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"environmentVariables": {"MYZOE_DATA_KEY": "a-key", "OLD_SETTING": null}}' \
  "$BASE/workflows/$WID" | jq '.data.environmentVariables'
```

Values are strings. A name the sandbox sets (`PATH`, `HOME`, `PYTHONPATH`,
`WORKFLOW_ID`, `EXECUTION_ID`, `NODE_ID`, ...) and `STRONGLY_API_KEY` are refused
(400); a streaming workflow or an agent takes none. A draft run gets them as they
are when it starts. They are not part of a version (a restore keeps the current
ones), `GET /workflows` lists omit them, and a duplicate, clone, template or
export carries the names with empty values, never a value. `POST /workflows`
takes `environmentVariables` too. SDK: `client.workflows.update(wid,
environment_variables={"MYZOE_DATA_KEY": key})`.

### Chain workflows and alert on run ends

When a run ends the platform emits `workflow.completed` (completed,
completed_with_gaps, partial_success) or `workflow.failed` (failed, error,
timeout); stopped and cancelled runs emit nothing. A **deployed** workflow whose
first node is an Event trigger (`event`) with `eventTypes: ["workflow.completed"]`
and `sourceWorkflowId: "<A>"` starts each time A's run completes, as its deployer
(who must be able to use A), with `event_data = {workflow_id, workflow_name,
execution_id, status, duration_ms, error_message, trigger_type}`. Drafts never
auto-run, and a workflow's own run never restarts it. Custom events:
`POST /workflows/events` `{event_type, event_data, source}`.

To be told yourself, create an alert rule (in-app needs no credentials):

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/workflows/alert-rules" \
  -d '{"name":"A failed","workflowId":"'$WID'","condition":"execution_failed","channels":[{"type":"in_app","config":{}}]}'
curl -s "${auth[@]}" "$BASE/workflows/alerts?workflowId=$WID" | jq '.data'   # each alert + channel outcomes
```

| Method | Path | Purpose |
|---|---|---|
| POST | `/workflows/events` | Emit an event; starts the deployed workflows you may use whose Event trigger listens for it |
| GET · POST | `/workflows/alert-rules` | List (`workflowId`) / create alert rules: `condition` = execution_failed, execution_timeout, execution_completed, duration_exceeded (`conditionConfig.durationThresholdMs`), node_failed (`nodeTypes`), consecutive_failures (`failureCount`), dlq_threshold (`dlqCountThreshold`); `channels` = in_app, email (`emailAddresses`), slack (`slackWebhookUrl`), webhook (`webhookUrl`); `throttle` `{enabled, intervalMinutes}` |
| GET · PATCH · DELETE | `/workflows/alert-rules/:id` | Read / update (`isEnabled: false` pauses) / delete a rule |
| GET | `/workflows/alerts` | Alerts sent (`workflowId`, `ruleId`, `limit` <= 200) with each channel's outcome |

---

## 6. Streaming workflows (real-time sessions)

Streaming workflows (`workflowType: "streaming"`, e.g. a voice agent) run as a
long-lived **session**, not as a batch execution. Build them with the same node
tools (filter the catalog with `workflowType=streaming`; it includes the model
pickers `llm`, `embeddings`, `speech-to-text`, `text-to-speech` and
`streaming-realtime`), then use the streaming surface to deploy, start a
session, drive it, and inspect it.

Wiring rules (the graph is validated at save/deploy and at session start):

- **Named ports.** Every streaming node's ports are its `streaming_ports`
  (e.g. websocket-trigger `audio_out`/`text_out`/`control_out`, streaming-llm
  `request_in`/`response_out`, websocket-response `media_in`/`text_in`/...).
  Every frame connection sets BOTH `sourcePort` and `targetPort` to declared
  port names whose frame types intersect; read them from
  `GET /workflow-nodes/:id/schema` (`streaming_ports`). Routers
  (conditional, switch, llm-router, confidence-router, language-router,
  tool-router) emit on ports named in their config
  (`streaming_ports.dynamic_outputs`) plus `default`.
- **Models.** A node with an `ai` dependency (streaming-llm, streaming-stt,
  streaming-tts, turn-detection, translation, intent-classifier, eval judges,
  ...) has no model field. Add the matching picker node, set its
  `config.model` to a model id, and connect **picker -> node** with
  `sourcePort: "output"`, `targetPort: "ai"`. The streaming-realtime-agent's
  picker is `streaming-realtime`; streaming-embed's is `embeddings`;
  streaming-stt / speaker-diarization take `speech-to-text`; streaming-tts
  takes `text-to-speech`; everything chat-shaped takes `llm`.
- One trigger, at least one response, every required input and connector wired.

```bash
# Deploy (202; poll the deployments list until status is "deployed").
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"idle_timeout_seconds":300,"max_session_duration_seconds":3600,"autoscaling":{"enabled":false}}' \
  "$BASE/streaming-workflows/$WID/deploy"
curl -s "${auth[@]}" "$BASE/streaming-workflows/$WID/deployments" | jq '.data[] | {status, ephemeral}'

# Start a session (mode "production" on the deployment, "draft" = saved
# definition on your own test worker; default: production when deployed).
# Returns sessionId + wsUrl + wsToken (+ publicWsUrl for in-platform callers).
SID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"workflowId\":\"$WID\"}" "$BASE/streaming-sessions" | jq -r '.data.sessionId')

# Gate readiness on the live pod health before connecting the WS.
curl -s "${auth[@]}" "$BASE/streaming-sessions/$SID/status" | jq '.data.deployment.health.replicas'

# Inspect a session, then end it.
curl -s "${auth[@]}" "$BASE/streaming-sessions/$SID/transcript" | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/streaming-sessions/$SID"
```

| Method | Path | Purpose |
|---|---|---|
| GET | `/streaming-workflows` · `/streaming-workflows/:id` | List / get streaming workflows |
| POST | `/streaming-workflows/:id/deploy` | Deploy (202; validates the graph first; body `cpu`+`memory` (or neither: sized from the nodes), `disk`, `gpu` (string), `gpu_type`, `useSpot` + `spotFallback` (spot capacity, as batch deploy), `idle_timeout_seconds` 60-86400, `max_session_duration_seconds` 300-604800, `max_concurrent_sessions` 1-10000, `autoscaling` `{enabled, min_replicas 0-20, max_replicas 1-50, target_sessions_per_pod 1-100, scale_down_cooldown_seconds 60-900}`; omitted settings keep the previous deploy's) |
| POST | `/streaming-workflows/:id/undeploy` | Tear down; return to draft |
| GET | `/streaming-workflows/:id/deployments` · `/sessions` | Deployments (`status` deploying / deployed / undeploying / undeployed / failed; `ephemeral: true` rows are builder test workers) / sessions for a workflow |
| POST | `/streaming-sessions` | Start a session (`workflowId` required, `mode` production / draft); returns `sessionId`, `wsUrl`, `wsToken` (and `publicWsUrl` when called from inside the platform) |
| GET | `/streaming-sessions` · `/streaming-sessions/:id` | List / get sessions (a `failed` session's `failure_reason` says why: `deployment_failed` = its pod could never start, and the session fails at once instead of waiting in `pending`; Kubernetes' reason is in the last `state_history` entry) |
| GET | `/streaming-sessions/:id/status` | Live deployment readiness (gate on `deployment.health.replicas.ready >= 1`) |
| POST | `/streaming-sessions/:id/inject` | Inject a text message (`text` required, `role`) |
| DELETE | `/streaming-sessions/:id` | End the live session |
| GET | `/streaming-sessions/:id/transcript` · `/logs` · `/recordings` · `/errors` · `/handoffs` | Inspect a session; `errors` is the first stop when a voice session misbehaves |

---

## 7. Export / import

A workflow is portable as a single `.strongly.json` document (format `2.0`): its
name, description, trigger, nodes (each config with secret fields stripped and
your resource ids replaced by `$ref` dependency declarations), connections,
layout, and `environmentVariableNames` (the names of its environment variables,
never their values: the imported workflow has each with an empty value). It is
NOT a version's definition: for that, read `GET /workflows/:workflowId/versions/:id`
(section 2).

```bash
# Export: a read like any other ({data, meta}); data is the .strongly.json
# document, the same file the dashboard's Export downloads.
curl -s "${auth[@]}" "$BASE/workflows/$WID/export" | jq '.data' > workflow.strongly.json

# Import is two calls. FIRST (no resolvedDeps) VALIDATES and returns the
# dependencies it needs mapped (data sources, addons, models, custom nodes).
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"exportData\": $(cat workflow.strongly.json)}" \
  "$BASE/workflows/import" | jq '.data'

# SECOND, with resolvedDeps ({"<refId>": "<resource id here>"} for each dependency
# the first call listed; {} when none) EXECUTES the import (201) and answers the
# new workflow. Import reads export format version 2.0 only (camelCase keys).
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"exportData": {...}, "resolvedDeps": {...}}' "$BASE/workflows/import" | jq '.data'
```

| Method | Path | Purpose |
|---|---|---|
| GET | `/workflows/:id/export` | Export the workflow: `data` is its `.strongly.json` document |
| POST | `/workflows/import` | Import from `.strongly.json` (`exportData`; call once to validate + list dependencies, again with `resolvedDeps` to create the workflow) |

---

## Checklist
- [ ] Node types discovered from `/workflow-nodes` (searched, not hardcoded); ambiguous connectors given a `category`.
- [ ] Graph built with `/workflows/build` (nodes + connections in one call); `inputMappings` paths match the arriving data.
- [ ] `llm` nodes: real model id under `config.model`; downstream reads `data.response`.
- [ ] Both `validate` and `validate-structure` pass before deploy.
- [ ] Executed with real `triggerInputs` and **polled to a terminal state**; outputs verified non-empty; failures read from `/workflows/-/executions/:id/spans`.
- [ ] Deploy is 202 + poll `/workflows/:id/status` to `deploymentStatus: active` and `health.replicas.ready >= 1` before claiming success.
- [ ] Invocation URL, auth mode, and signing header relayed to the user; webhook `config.secret` set if a signed caller needs it.
- [ ] Streaming: deployed, session readiness gated on live pod health, session ended after testing.
- [ ] Cleanup: undeploy and stop before `DELETE`.
