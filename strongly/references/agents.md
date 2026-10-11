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
# Inside Strongly (a workspace, app or job): BASE="$STRONGLY_API_URL/api/v1"; auth=()   # signed in as you, no key
```

All agent routes carry the `agents:read` or `agents:write` scope. Responses use
the standard envelope (see `SKILL.md`): `data` on success, lists page with `cursor` / `meta.nextCursor`, and a failure is problem details whose `detail` and `code` to surface.

---

## 1. The lifecycle (the golden path)

Every reliable agent flow is the same shape. Do not skip the poll.

1. **Create** an agent: `POST /agents` (the Agent Builder create), or
   `POST /workflows/:id/promote` an existing workflow.
2. **Configure** the brain if needed: `GET/PATCH /agents/:id/config`
   (name, description and graph: `PATCH /agents/:id`).
3. **Start** the pod: `POST /agents/:id/start`.
4. **Poll** `GET /agents/:id/status` until it reports `healthy`. Check the start
   result's `mcpRegisterFailures` first.
5. **Create a thread** (`POST /agents/:id/threads`), then **chat**
   (`POST /agents/:agentId/threads/:id/runs`, SSE).
6. Change model / stop / delete as needed.

A create leaves the agent in DRAFT (no pod). Bringing it LIVE is `start`, **not**
`redeploy` (redeploy only restarts an already-running pod, see section 6).

---

## 2. Create or promote an agent

### 2a. From the Agent Builder wizard (recommended)

`POST /agents` is the one-shot create the Agent Builder UI
uses. It auto-provisions required add-ons, builds the brain workflow, and seeds a
Library scoped to the agent. Only `name` is required. **Pass a real `aiModelId`**
(resolve one from `references/ai-gateway.md`, `GET $BASE/ai-gateway/models`) when building
programmatically: omit it and the brain keeps the literal `{{AI_MODEL_ID}}`
placeholder and `start` rejects it with `422 unresolved-model-placeholder`.

```bash
AGENT_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Support Bot","personality":"Warm, concise.",
       "aiModelId":"<ai-model-_id>"}' \
  "$BASE/agents" | jq -r '.data._id')
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
`GET /agents/templates` (and one: `GET /agents/templates/:key`, key
`iris|atlas|sage|aria`). Check a proposed name with
`GET /agents/name-availability?name=...` (names are unique per user).

### 2b. Promote an existing workflow

If the user already has a workflow, promote it:

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"toolWorkflowIds":["<wf-a>","<wf-b>"]}' \
  "$BASE/workflows/$WORKFLOW_ID/promote"
```

Promote validates that the workflow has a function-calling node, a resolved LLM
model, and at least one trigger. On a validation failure it returns
`422 validation-failed` with the per-rule errors in the problem's `errors`. The reverse
is `POST /agents/:id/demote` (flip back to a plain workflow; it does NOT tear
down a running pod, so `stop` first).

---

## 3. Configure the brain

Read the current brain config with `GET /agents/:id/config` (personality,
operating prompt id, context/session policy, heartbeat, primary + fallback
models, running status). Get the full agent record (live status, config, node
graph) with `GET /agents/:id`.

Update brain-config keys with `PATCH /agents/:id/config` (only the keys sent change;
it returns the config):

```bash
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"personality":"Terse and factual.","temperature":0.3,"maxIterations":8}' \
  "$BASE/agents/$AGENT_ID/config"
```

`PATCH /agents/:id/config` accepts `personality`, `operatingPromptId`, `contextPolicy`,
`sessionPolicy`, `heartbeatEnabled`, `heartbeatCron`, `heartbeatTimezone`,
`maxIterations`, `temperature` (0 to 2), `maxTokens`, `responseFormat`,
`builtInTools` and `knowledgeBaseIds`. The workflow-level `name` / `description` /
`nodes` / `connections` are `PATCH /agents/:id`. **Edits to the operating prompt's text and the session policy
apply live; every other change, including switching to a different operating
prompt, needs a redeploy** (section 6) to take effect on a running pod.
`GET /agents/:id/config` returns `applyPending: true` while one is waiting.

---

## 4. Start it, and CONFIRM it is running

Start the pod:

```bash
curl -s -X POST "${auth[@]}" "$BASE/agents/$AGENT_ID/start" | jq '.data'
```

Start answers the agent (as `GET /agents/:id` shows it) with `mcpRegisterFailures`. **A
non-empty `mcpRegisterFailures` means the pod started but is MISSING those
connectors' tools** (it will answer "I cannot do that" on first use). Do not
report the agent ready: read `GET /agents/:id/logs`, fix or re-provision the
connector, and start again. Start is idempotent (a second start answers the
running agent). If the model was never resolved, start returns
`422 unresolved-model-placeholder`: set a real model (section 6) and retry.

Then **poll status until healthy**:

```bash
curl -s "${auth[@]}" "$BASE/agents/$AGENT_ID/status" | jq -r '.data.status'
# starting -> running -> healthy   (poll until "healthy")
```

Once the pod is up, `GET /agents/:id/status` reflects the pod's live health, so
a truly ready agent reports `healthy`. Other values are `starting`, `running`
(briefly, before the health probe passes), `stopping`, `stopped`, and `error`.
`GET /agents` and `GET /agents/:id` report only the raw pod-record status
(`starting`, `running`, or `stopped`), never the live `healthy`, so poll
`GET /agents/:id/status` for readiness.

**Why the poll is non-negotiable.** A chat run (`POST /agents/:agentId/threads/:id/runs`) returns
`409 agent-not-running` only when there is NO pod at all. A pod in `starting` is
not yet answering: chat it too early and the stream can come back empty or null.
That empty/null answer is a DEPLOY problem, not the agent's response. When it
happens, read `GET /agents/:id/logs?lines=200` rather than retrying blindly.

```bash
curl -s "${auth[@]}" "$BASE/agents/$AGENT_ID/logs?lines=200" | jq -r '.data'
```

---

## 5. Chat over threads

Chat is scoped to a **thread**. Create one first, then run a message in it.
`POST /agents/:agentId/threads/:id/runs` streams the response as
**Server-Sent Events** and requires `message` (string, 100000 chars max).

```bash
# 1) create a thread
THREAD_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"title":"First chat"}' \
  "$BASE/agents/$AGENT_ID/threads" | jq -r '.data.threadId // .data._id')

# 2) chat (SSE: use -N and read data: lines until data: [DONE])
curl -sN -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"message":"Summarize the notes in the shared folder."}' \
  "$BASE/agents/$AGENT_ID/threads/$THREAD_ID/runs"
```

The stream is SSE `data:` lines terminated by `data: [DONE]`. A runtime failure
arrives as an event `data: {"event":"error","data":{"error":"...","code":"...",
"status":<n>}}` (for example a `session-cap-reached` 429 from the pod). The
thread must belong to this agent and to the caller, or chat returns 404/403.

Manage threads with `GET /agents/:id/threads` (list) and
`DELETE /agents/:agentId/threads/:id` (delete one).

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

## 8. Knowledge bases

An agent answers from **knowledge bases**: Library resources whose documents the platform
indexes into section trees. There is no vector store and no chunking: the agent sees what each
base holds, finds sections by keyword or by a document's outline, and reads the ones it needs.

1. `POST /library/knowledge-bases` `{ "name", "description", "indexModelId" }` creates one and
   returns it (`data._id`). `indexModelId` is an AI Gateway **chat** model that writes each
   section's summary while a document is indexed (billed to whoever adds the document); ask
   the user which of their chat models to use.
2. Add documents:
   - `POST /library/knowledge-bases/:id/documents` `{ "filename": "notes.md", "content": "..." }`
     for text (Markdown headings become sections), or `{ "filename", "fileBase64",
     "contentType" }` for a file (`.pdf .md .markdown .txt .html .htm .docx .csv .json`).
   - `POST /library/knowledge-bases/:id/documents/import` `{ "artifactIds": [...] }` adds
     Library artifacts. They are read where they are stored (never copied), indexed again when
     they change, and dropped from answers if the person who added them can no longer open
     them. Images cannot be indexed.
   Indexing runs in the background: `GET /library/knowledge-bases/:id` lists each document's
   `status` (`pending`, `indexing`, `ready`, `failed`), its `error`, and what indexing found.
   Poll it until every document is `ready` (or `failed`, then fix and
   `POST /library/knowledge-bases/:knowledgeBaseId/documents/:id/reindex`).
3. Give the agent the knowledge base: `PATCH /agents/:id/config` `{ "knowledgeBaseIds": [...] }`
   (the complete list; each one added must be one you may use). A running agent gets its
   knowledge tools at the next restart (`POST /agents/:id/redeploy`, or Settings, Apply
   changes).

Sharing uses the one permissions shape: `GET /library/knowledge-bases/:id/permissions`,
`POST …/permissions/members` `{ "userId", "role": "editor" }` (knowledge bases have no
use-only tier, so `"user"` is refused; an editor can read the base, add and remove documents,
and give it to their own agents), `DELETE …/permissions/members/:userId`, and
`PATCH …/permissions` `{ "visibility": "public" | "private" }`.

What the agent does with them (and what you can call to check):
`GET /agents/:id/knowledge` (catalog), `GET /agents/:id/knowledge/search?q=…` (keyword search,
best first), `GET /agents/:agentId/knowledge/documents/:id/outline`,
`GET /agents/:agentId/knowledge/documents/:documentId/sections/:id`. Documents carry `_id`;
an outline's sections carry `id`. Inside the agent these are its `knowledge_catalog`,
`knowledge_search`, `knowledge_outline` and `knowledge_read` tools.

```bash
KB=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Meeting notes","indexModelId":"'"$MODEL_ID"'"}' \
  "$BASE/library/knowledge-bases" | jq -r .data._id)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"filename":"rooms.md","content":"# Rooms\n\nThe planning meeting is held in Room 4B."}' \
  "$BASE/library/knowledge-bases/$KB/documents"
curl -s "${auth[@]}" "$BASE/library/knowledge-bases/$KB" | jq '.data.documents[] | {name, status}'
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"knowledgeBaseIds":["'"$KB"'"]}' "$BASE/agents/$AGENT_ID/config"
curl -s -X POST "${auth[@]}" "$BASE/agents/$AGENT_ID/redeploy"
```

`GET /library/knowledge-bases` lists the ones you can use (cursor-paged: `limit`, `cursor` from
`meta.nextCursor`). `PATCH /library/knowledge-bases/:id` renames it, changes its description or
its indexing model. `DELETE /library/knowledge-bases/:id` deletes a knowledge base with its
documents and removes it from every agent (artifacts added to it are kept). Errors are RFC 9457
problem details: read `code` and `detail`.

---

## 9. Skills, artifacts, analytics

- **Skills:** `GET/POST /agents/:id/skills`, `PATCH/DELETE /agents/:agentId/skills/:id`.
  Associate a Library skill with the agent (adding it also links it into the
  agent's recall scope).
- **Artifacts:** the files an agent produces are Library artifacts linked to the
  agent: `GET /library/artifacts?linkedIds=<agentId>` (metadata; filter by
  `artifactType` or `tags`), `GET /library/artifacts/:id` and
  `GET /library/artifacts/:id/download-url` (a short-lived signed URL),
  `POST /library/artifacts` (`title`, `content`, `linkedIds: [agentId]`),
  `DELETE /library/artifacts/:id`.
- **Analytics:** `GET /agents/:id/analytics?days=30` (1 to 365).

---

## 10. Inter-agent messages

Agents can message each other. These routes are scoped by agent authorization
(you may only act on messages involving an agent you can access).

- `GET /agents/-/messages` lists the messages of every agent you can see, and
  `GET /agents/:id/messages` one agent's (filters: `type`, `category`, `since`;
  `limit`, `cursor`).
- `POST /agents/:id/messages` sends one AS that agent (one you are authorized
  to; its name is the agent's own). Requires `content`; add `toAgentId` for a
  direct message (omit for a broadcast), plus optional `category`, `metadata`,
  `expiresAt` (defaults to 24h).
- `DELETE /agents/:agentId/messages/:id` and
  `POST /agents/:agentId/messages/:id/read` delete or mark-read a message (as
  the agent in the path).

---

## Endpoint reference

| Method | Path | Purpose |
|---|---|---|
| GET | `/agents` | List agents with live status (`q`, `status`, `limit`, `cursor`) |
| POST | `/agents` | Create an agent, as the Agent Builder does |
| POST | `/workflows/:id/promote` | Promote a workflow to an agent (`toolWorkflowIds`); answers the agent with `warnings` |
| POST | `/agents/:id/demote` | Turn an agent back into a workflow; answers the workflow |
| GET | `/agents/name-availability` | Check a name (`name`) |
| GET | `/agents/templates`, `/agents/templates/:key` | Reference agent payloads (`iris`, `atlas`, `sage`, `aria`) |
| GET | `/agents/:id` | Agent details + live status + node graph |
| PATCH | `/agents/:id` | Update `name`, `description`, `nodes`, `connections` |
| GET/PATCH | `/agents/:id/config` | Read / update the brain config (only the fields sent change) |
| DELETE | `/agents/:id` | Delete (stop pod + remove agent mode) |
| PATCH | `/agents/:id/model` | Swap primary model + fallbacks (rebuilds bundle) |
| POST | `/agents/:id/start` | Start the pod |
| POST | `/agents/:id/redeploy` | Restart a running pod to apply pending changes |
| POST | `/agents/:id/stop` | Stop the pod |
| GET | `/agents/:id/status` | Live pod status (poll to `healthy`) |
| GET | `/agents/:id/logs` | Recent pod log lines (`lines`, `container`) |
| POST/GET | `/agents/:id/threads` | Create / list conversation threads |
| DELETE | `/agents/:agentId/threads/:id` | Delete a thread |
| POST | `/agents/:agentId/threads/:id/runs` | Send a message (SSE stream) |
| GET | `/agents/:id/analytics` | Usage analytics (`days`) |
| GET | `/agents/:id/sessions` | Chat sessions (`state`) |
| GET | `/agents/:id/knowledge` | The agent's knowledge catalog |
| GET | `/agents/:id/knowledge/search?q=` | Search the agent's document sections |
| GET | `/agents/:agentId/knowledge/documents/:id/outline` | A document's section tree |
| GET | `/agents/:agentId/knowledge/documents/:documentId/sections/:id` | One section's text |
| GET/POST | `/library/knowledge-bases` | List (cursor-paged) / create knowledge bases |
| GET/PATCH/DELETE | `/library/knowledge-bases/:id` | One knowledge base (with documents) / update / delete |
| GET/PATCH | `/library/knowledge-bases/:id/permissions` | Owner, members, visibility / set visibility |
| POST | `/library/knowledge-bases/:id/permissions/members` | Share with a user (`role: "editor"`) |
| DELETE | `/library/knowledge-bases/:knowledgeBaseId/permissions/members/:userId` | Remove a member |
| POST | `/library/knowledge-bases/:id/documents` | Add a document (text `content` or `fileBase64`) |
| POST | `/library/knowledge-bases/:id/documents/import` | Add artifacts (`artifactIds`) |
| POST | `/library/knowledge-bases/:knowledgeBaseId/documents/:id/reindex` | Index a document again |
| DELETE | `/library/knowledge-bases/:knowledgeBaseId/documents/:id` | Remove a document |
| GET/POST | `/agents/:id/skills` | List / add skill associations |
| PATCH/DELETE | `/agents/:agentId/skills/:id` | Update / remove a skill association |
| GET | `/library/artifacts?linkedIds=<agentId>` | The agent's artifacts (Library artifacts linked to it) |
| GET | `/agents/-/messages`, `/agents/:id/messages` | Inter-agent messages: all you can see / one agent's |
| POST | `/agents/:id/messages` | Send a message as the agent |
| DELETE | `/agents/:agentId/messages/:id` | Delete a message |
| POST | `/agents/:agentId/messages/:id/read` | Mark a message read |

---

## Checklist

- [ ] Create with a real `aiModelId` (from `references/ai-gateway.md`), or `start` returns `422 unresolved-model-placeholder`.
- [ ] To bring a fresh or stopped agent LIVE use `start`, not `redeploy` (redeploy no-ops on a draft).
- [ ] After `start`, check `mcpRegisterFailures` is empty, then poll `GET /agents/:id/status` until `healthy`.
- [ ] Never chat a non-running agent: an empty/null answer is a DEPLOY failure, read `GET /agents/:id/logs`.
- [ ] Chat runs in a thread (`POST /agents/:agentId/threads/:id/runs`); create the thread first; it streams SSE ending in `data: [DONE]`.
- [ ] Model change is two steps: `PATCH /agents/:id/model` then `redeploy` (running) or `start` (stopped), then poll back to `healthy`.
- [ ] Knowledge: create a knowledge base (`/library/knowledge-bases`) with a chat `indexModelId`, add documents, wait for `ready`, then `PATCH /agents/:id/config` `knowledgeBaseIds` and restart the agent.
- [ ] An agent is a workflow (`references/workflows.md`) whose model is an AI Gateway model (`references/ai-gateway.md`).
