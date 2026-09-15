# Agents

A Strongly **agent** is a **workflow run in agent mode as a persistent pod**. You
build (or promote) a workflow, flip it to `mode: 'agent'`, start a pod for it,
and then chat with it over threads. Because an agent *is* a workflow, everything
in `references/workflows.md` applies to its node graph, and its language model is
an AI Gateway model (`references/ai-gateway.md`).

Read this when the task is: creating or promoting an agent, configuring its
brain (personality, model, policies), **starting it and confirming it is
actually running before you chat it**, holding a conversation, changing its
model, or tearing it down.

> **The one contract that bites everyone: an agent must be confirmed RUNNING
> before you chat it.** A freshly created agent is a DRAFT with no pod. Chatting
> a non-running agent is a DEPLOY failure, not the agent's answer. Always
> `start` then poll `GET /agents/:id/status` until it reports `healthy`, and read
> the logs on any empty or null response. Details in section 4.

**Auth** follows `SKILL.md`. Outside Strongly, set the host and key once; inside
Strongly the bearer is auto-injected and `$BASE` is `$STRONGLY_API_URL/api/v1`.

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # outside Strongly
```

All agent routes carry the `agents:read` or `agents:write` scope. Responses use
the standard envelope: `{ "success": true, "data": ... }`, or
`{ "success": false, "error": { "code", "message" } }` on failure.

---

## 1. The lifecycle (the golden path)

Every reliable agent flow is the same shape. Do not skip the poll.

1. **Create** an agent: `POST /agents/create-from-wizard` (recommended), or
   `POST /agents/promote` an existing workflow, or `POST /agents` (bare).
2. **Configure** the brain if needed: `GET/PATCH /agents/:id`,
   `GET /agents/:id/config`.
3. **Start** the pod: `POST /agents/:id/start`.
4. **Poll** `GET /agents/:id/status` until it reports `healthy`. Check the start
   result's `mcp_register_failures` first.
5. **Create a thread** (`POST /agents/:id/threads`), then **chat**
   (`POST /agents/:id/chat`, SSE).
6. Change model / stop / delete as needed.

A create leaves the agent in DRAFT (no pod). Bringing it LIVE is `start`, **not**
`redeploy` (redeploy only restarts an already-running pod, see section 6).

---

## 2. Create or promote an agent

### 2a. From the Agent Builder wizard (recommended)

`POST /agents/create-from-wizard` is the one-shot create the Agent Builder UI
uses. It auto-provisions required add-ons, builds the brain workflow, and seeds a
Library scoped to the agent. Only `name` is required. **Pass a real `aiModelId`**
(resolve one from `references/ai-gateway.md`, `GET $BASE/ai-models`) when building
programmatically: omit it and the brain keeps the literal `{{AI_MODEL_ID}}`
placeholder and `start` rejects it with `422 unresolved-model-placeholder`.

```bash
AGENT_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Support Bot","personality":"Warm, concise.",
       "aiModelId":"<ai-model-_id>"}' \
  "$BASE/agents/create-from-wizard" | jq -r '.data.workflowId // .data._id')
```

Notable optional fields on the wizard body: `personality`, `operatingPromptId`
or `operatingPromptName`, `referenceKey` (e.g. `"atlas"`), `responseFormat`
(`json_object` | `text`), `fallbackModelIds[]`, `contextPolicy`, `sessionPolicy`,
`heartbeat` (`{ enabled, cron, timezone }` for autonomous wakeups),
`connectors[]`, `training` (`{ memory[], rules[], skills[], tasks[] }`),
`sharedLinkedIds[]`, `builtInTools` (`{ disabled: [...] }` over families
`memory|rules|skills|tasks|prompts|artifacts|preferences|computer|code_execution`,
default is ALL disabled), and `workspace` (a persistent code-execution workspace,
provisioned at start).

Reference-agent starting points (for prefilling the wizard) are served by
`GET /agents/wizard/reference/{iris|atlas|sage|aria}`. Check a proposed name with
`GET /agents/check-name?name=...` (names are unique per user).

### 2b. Promote an existing workflow

If the user already has a workflow, promote it:

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"workflowId":"<workflow-_id>","toolWorkflowIds":["<wf-a>","<wf-b>"]}' \
  "$BASE/agents/promote"
```

Promote validates that the workflow has a function-calling node, a resolved LLM
model, and at least one trigger. On a validation failure it returns
`422 validation-failed` with the per-rule errors in `error.details`. The reverse
is `POST /agents/:id/demote` (flip back to a plain workflow; it does NOT tear
down a running pod, so `stop` first).

### 2c. Bare create

`POST /agents` creates a workflow and flips it to agent mode with no
provisioning. Prefer the wizard unless you are assembling the node graph
yourself. Body: `name` (required), `description`, `nodes[]`, `connections[]`.

---

## 3. Configure the brain

Read the current brain config with `GET /agents/:id/config` (personality,
operating prompt id, context/session policy, heartbeat, primary + fallback
models, running status). Get the full agent record (live status, config, node
graph) with `GET /agents/:id`.

Update flat brain-config keys with `PATCH /agents/:id`:

```bash
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"personality":"Terse and factual.","temperature":0.3,"maxIterations":8}' \
  "$BASE/agents/$AGENT_ID"
```

`PATCH /agents/:id` accepts `personality`, `operatingPromptId`, `contextPolicy`,
`sessionPolicy`, `heartbeatEnabled`, `heartbeatCron`, `heartbeatTimezone`,
`maxIterations`, `temperature` (0 to 2), `maxTokens`, `responseFormat`,
`builtInTools`, plus workflow-level `name` / `description` / `nodes` /
`connections`. **Operating-prompt changes live-reload; other config changes need
a redeploy** (section 6) to take effect on a running pod. `PUT /agents/:id`
does the same via a nested `config` object.

---

## 4. Start it, and CONFIRM it is running

Start the pod:

```bash
curl -s -X POST "${auth[@]}" "$BASE/agents/$AGENT_ID/start" | jq '.data'
```

The start result carries `tools_count` and `mcp_register_failures`. **A
non-empty `mcp_register_failures` means the pod started but is MISSING those
connectors' tools** (it will answer "I cannot do that" on first use). Do not
report the agent ready: read `GET /agents/:id/logs`, fix or re-provision the
connector, and start again. Start is idempotent (a second start returns
`alreadyRunning: true`). If the model was never resolved, start returns
`422 unresolved-model-placeholder`: set a real model (section 6) and retry.

Then **poll status until healthy**:

```bash
curl -s "${auth[@]}" "$BASE/agents/$AGENT_ID/status" | jq -r '.data.status'
# starting -> running -> healthy   (poll until "healthy")
```

Once the pod is up, `GET /agents/:id/status` proxies the pod's live `/health`, so
a truly ready agent reports `healthy`. Other values are `starting`, `running`
(briefly, before the health probe passes), `stopping`, `stopped`, and `error`.
`GET /agents` and `GET /agents/:id` report a coarser `running`/`stopped` from the
pod record.

**Why the poll is non-negotiable.** `POST /agents/:id/chat` returns
`409 agent-not-running` only when there is NO pod at all. A pod in `starting` is
not yet answering: chat it too early and the stream can come back empty or null.
That empty/null answer is a DEPLOY problem, not the agent's response. When it
happens, read `GET /agents/:id/logs?lines=200` rather than retrying blindly.

```bash
curl -s "${auth[@]}" "$BASE/agents/$AGENT_ID/logs?lines=200" | jq -r '.data'
```

---

## 5. Chat over threads

Chat is scoped to a **thread**. Create one first, then post messages into it.
`POST /agents/:id/chat` streams the response as **Server-Sent Events** and
requires both `message` (string, 100000 chars max) and `threadId`.

```bash
# 1) create a thread
THREAD_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"title":"First chat"}' \
  "$BASE/agents/$AGENT_ID/threads" | jq -r '.data.threadId // .data._id')

# 2) chat (SSE: use -N and read data: lines until data: [DONE])
curl -sN -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"message":"Summarize our refund policy.","threadId":"'"$THREAD_ID"'"}' \
  "$BASE/agents/$AGENT_ID/chat"
```

The stream is SSE `data:` lines terminated by `data: [DONE]`. A runtime failure
arrives as an event `data: {"event":"error","data":{"error":"...","code":"...",
"status":<n>}}` (for example a `session-cap-reached` 429 from the pod). The
thread must belong to this agent and to the caller, or chat returns 404/403.

Manage threads with `GET /agents/:id/threads` (list) and
`DELETE /agents/:id/threads?threadId=<id>` (delete one).

---

## 6. Change the model, then redeploy

Swapping the model is a two-step operation. `PATCH /agents/:id/model` sets the
primary model and optional ordered fallbacks and triggers a `STRONGLY_SERVICES`
bundle rebuild so the new id is resolvable. It does NOT restart the pod.

```bash
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"modelId":"<new-ai-model-_id>","fallbackModelIds":["<fallback-_id>"]}' \
  "$BASE/agents/$AGENT_ID/model"
```

To apply the change to a live agent, restart it:

- **Already running:** `POST /agents/:id/redeploy` (stops + starts the pod so
  pending brain-config and model changes take effect). Redeploy is a NO-OP on a
  draft or stopped agent.
- **Draft or stopped:** `POST /agents/:id/start`.

After either, poll `GET /agents/:id/status` back to `healthy` (section 4).

---

## 7. Stop and delete

```bash
curl -s -X POST "${auth[@]}" "$BASE/agents/$AGENT_ID/stop"      # stop the pod (idempotent)
curl -s -X DELETE "${auth[@]}" "$BASE/agents/$AGENT_ID"         # stop + remove agent mode + cleanup
```

`DELETE /agents/:id` stops the pod, removes agent mode from the workflow, and
cleans up records. Use `demote` (section 2b) instead if you want to keep the
workflow and just turn agent mode off.

---

## 8. Knowledge base (optional RAG)

Knowledge is **opt-in**; the wizard does not auto-provision it. Two steps:

1. `POST /agents/:id/knowledge/provision` builds and deploys the agent's
   document-ingest pipeline (document to chunk to embed to vector store) and a
   knowledge-search tool, provisions the agent's vector store, and attaches
   both. It is idempotent and SLOW (real workflow deploys, minutes). It fails
   loud with `422` if no embedding model or vector store is available.
2. `POST /agents/:id/knowledge` adds a document. Send the text inline as JSON
   `{ "content": "..." }` (the path a programmatic caller uses), or a file as
   `multipart/form-data`. Optional `filename`, `documentId`, `tags`,
   `description`. It requires the ingest workflow from step 1 to be attached,
   otherwise it returns `422 not-configured`.

```bash
curl -s -X POST "${auth[@]}" "$BASE/agents/$AGENT_ID/knowledge/provision"   # step 1
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"content":"Refunds are issued within 30 days...","tags":"policy"}' \
  "$BASE/agents/$AGENT_ID/knowledge"                                         # step 2
```

---

## 9. Skills, artifacts, analytics

- **Skills:** `GET/POST /agents/:id/skills`, `PUT/DELETE /agents/:id/skills/:sub`.
  Associate a Library skill with the agent (adding it also links it into the
  agent's recall scope).
- **Artifacts:** the files an agent produces live in the canonical Library, linked
  to the agent. `GET /agents/:id/artifacts` (metadata; filter by `type` or `tag`),
  `GET /agents/:id/artifacts/:sub` (metadata plus a short-lived signed
  `downloadUrl`), `POST /agents/:id/artifacts` (save `title` + `content`),
  `DELETE /agents/:id/artifacts/:sub`.
- **Analytics:** `GET /agents/:id/analytics?days=30` (1 to 365).

---

## 10. Inter-agent messages

Agents can message each other. These routes are scoped by agent authorization
(you may only act on messages involving an agent you can access).

- `GET /agent-messages` lists messages (filters: `type`, `category`, `since`,
  `agentId`, `limit`).
- `POST /agent-messages` sends one AS an agent you are authorized to. Requires
  `fromAgentId`, `fromAgentName`, `content`; add `toAgentId` for a direct message
  (omit for a broadcast), plus optional `toAgentName`, `category`, `metadata`,
  `expiresAt` (defaults to 24h).
- `DELETE /agent-messages/:id` and `POST /agent-messages/:id/read`
  (body `{ "agentId": "..." }`) delete or mark-read a message.

---

## Endpoint reference

| Method | Path | Purpose |
|---|---|---|
| GET | `/agents` | List agents with live status |
| POST | `/agents` | Bare create (workflow in agent mode) |
| POST | `/agents/create-from-wizard` | One-shot Agent Builder create (recommended) |
| POST | `/agents/promote` | Promote a workflow to agent mode |
| POST | `/agents/:id/demote` | Turn an agent back into a workflow |
| GET | `/agents/check-name` | Check name availability |
| GET | `/agents/wizard/reference/{iris\|atlas\|sage\|aria}` | Reference wizard payloads |
| GET | `/agents/:id` | Agent details + live status + node graph |
| GET | `/agents/:id/config` | Read brain config |
| PUT | `/agents/:id` | Update workflow fields and/or nested `config` |
| PATCH | `/agents/:id` | Flat partial brain-config update |
| DELETE | `/agents/:id` | Delete (stop pod + remove agent mode) |
| PATCH | `/agents/:id/model` | Swap primary model + fallbacks (rebuilds bundle) |
| POST | `/agents/:id/start` | Start the pod |
| POST | `/agents/:id/redeploy` | Restart a running pod to apply pending changes |
| POST | `/agents/:id/stop` | Stop the pod |
| GET | `/agents/:id/status` | Live pod status (poll to `healthy`) |
| GET | `/agents/:id/logs` | Recent pod log lines (`lines`, `container`) |
| POST | `/agents/:id/threads` | Create a conversation thread |
| GET | `/agents/:id/threads` | List threads |
| DELETE | `/agents/:id/threads?threadId=` | Delete a thread |
| POST | `/agents/:id/chat` | Send a message (SSE stream) |
| GET | `/agents/:id/analytics` | Usage analytics (`days`) |
| POST | `/agents/:id/knowledge/provision` | Enable a knowledge base (RAG) |
| POST | `/agents/:id/knowledge` | Add a document (JSON `content` or multipart file) |
| GET/POST | `/agents/:id/skills` | List / add skill associations |
| PUT/DELETE | `/agents/:id/skills/:sub` | Update / remove a skill association |
| GET | `/agents/:id/artifacts` | List agent artifacts (metadata) |
| GET | `/agents/:id/artifacts/:sub` | Get one artifact + signed download URL |
| POST | `/agents/:id/artifacts` | Save an artifact |
| DELETE | `/agents/:id/artifacts/:sub` | Delete an artifact |
| GET/POST | `/agent-messages` | List / send inter-agent messages |
| DELETE | `/agent-messages/:id` | Delete a message |
| POST | `/agent-messages/:id/read` | Mark a message read |

---

## Checklist

- [ ] Create with a real `aiModelId` (from `references/ai-gateway.md`), or `start` returns `422 unresolved-model-placeholder`.
- [ ] To bring a fresh or stopped agent LIVE use `start`, not `redeploy` (redeploy no-ops on a draft).
- [ ] After `start`, check `mcp_register_failures` is empty, then poll `GET /agents/:id/status` until `healthy`.
- [ ] Never chat a non-running agent: an empty/null answer is a DEPLOY failure, read `GET /agents/:id/logs`.
- [ ] Chat needs a `threadId`; create a thread first; it streams SSE ending in `data: [DONE]`.
- [ ] Model change is two steps: `PATCH /agents/:id/model` then `redeploy` (running) or `start` (stopped), then poll back to `healthy`.
- [ ] Knowledge is opt-in: `provision` first, then add documents.
- [ ] An agent is a workflow (`references/workflows.md`) whose model is an AI Gateway model (`references/ai-gateway.md`).
