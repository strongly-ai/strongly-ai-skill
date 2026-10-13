# Library

The Strongly **Library** is the persistent brain your work runs on: **memory**,
**rules**, **prompts**, **tasks**, **skills**, and **preferences**. These are the
primitives an agent reads at the start of a turn and writes back during one. An
agent is a workflow, and every Library row can belong to one or many agents
through its `linkedIds` (the agent's `workflowId`); the same row is equally
reachable by you over REST. See `references/agents.md` for the agent side.

Read this when the task is: giving an agent durable memory, adding rules or
preferences it must honour, saving reusable prompts or skills, scheduling
recurring or one-off tasks, or reading/writing any of these from your own client.

> **Artifacts** are also a Library primitive, but they are files an app or agent
> produces for the user. They are documented in `references/apps.md` (Artifacts).
> Do not look for them here.
>
> **Knowledge bases** (`/library/knowledge-bases`) are the Library's documents agents
> answer from: uploads and artifacts indexed into section trees. They are documented in
> `references/agents.md` section 8.

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key: $STRONGLY_API_KEY"`
to `$HOST/api/v1`; inside Strongly call `$STRONGLY_API_URL/api/v1` with the bearer
auto-injected. Below, `$BASE` is whichever applies and `auth` is the header:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # outside Strongly
# inside Strongly: BASE="$STRONGLY_API_URL/api/v1"; auth=()      # bearer injected
```

## Conventions that hold across every primitive

- **Envelope.** The standard envelope (see `SKILL.md`): `data` on success, lists page with `cursor` / `meta.nextCursor`, and a failure is problem details whose `detail` and `code` to surface.
- **Scopes.** Reads need `<primitive>:read`, writes need `<primitive>:write`
  (`memory:read`, `rules:write`, `tasks:read`, …). A missing scope returns `403`.
- **Visibility is user-level:** owner, then rows shared with you, then public.
  Memory, rules, tasks, and preferences share the platform's one way:
  `GET …/:id/permissions`, `POST …/:id/permissions/members` `{ userId, role }`,
  `DELETE …/:{name}Id/permissions/members/:userId`, `PATCH …/:id/permissions`
  `{ visibility }`; memory adds org-global promotion. Prompts and skills have no
  per-row sharing.
- **An agent reads as its owner, never as an admin.** A request a workload makes
  (an agent, a workflow, an app, with its signed token) reaches only the owner's own
  rows plus rows shared with the owner or public, even when the owner is a platform
  or org admin. A person calling with an API key or from the UI keeps the admin reach.
- **`linkedIds` = agent membership.** Pass agent `workflowId`s to attach a row to
  agents (a row can belong to many). On **list/GET** filters, `linkedIds` is AND
  (a row must belong to ALL supplied ids). On **recall** endpoints
  (the `…/search` endpoints) it is ANY (match rows in any linked pool).
- **`tags`** on list endpoints are comma-separated with AND semantics (a row must
  carry every supplied tag).
- **Versioning.** Memory, rules, prompts, and skills keep full version history:
  each has `GET …/:id/versions` plus `POST …/versions/:version/restore`, which
  appends a new version rather than mutating history. Memory and rules also
  expose a single-version read (`GET …/versions/:version`).
- **Retrieval blocks.** `POST /primitives/memories/search`, `POST /primitives/rules/search`,
  `POST /library/skills/search`, and `POST /primitives/preferences/search` each return both the
  matched rows and a canonical markdown `contextBlock` an agent drops straight into
  its system prompt. Use these for injection; use plain `GET` lists to browse.
- **Meaning runs through one model.** Memories, prompts, skills and rules are embedded by the
  platform's embedding model when saved, and every search embeds its query with it. A failed
  embedding fails the save or the search with the error (no keyword-only answer, no row
  without a vector): retry the same call once the AI Gateway is back.

---

## 1. Memory

Durable facts and episodes an agent recalls. Bitemporal (`validFrom`/`validUntil`
+ `asOf`), hybrid-searchable, versioned, and graph-linkable.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /primitives/memories` | List | `kind, tags, linkedIds, q, asOf, includeInvalidated, limit, cursor` |
| `POST /primitives/memories` | Create | body: `kind*, content*, summary, tags, category, importance, confidence, links, linkedIds, source, eventTime, validFrom, validUntil` |
| `GET /primitives/memories/:id` · `PATCH /primitives/memories/:id` · `DELETE /primitives/memories/:id` | Fetch / update (content change appends a version) / delete | update body adds `changeNote` |
| `POST /primitives/memories/search` | Hybrid BM25 + dense-vector search with RRF fusion and temporal-decay re-rank; returns `contextBlock` | body: `q*, limit, kind, tags, linkedIds, weights, rrfK, decayHalfLifeDaysOverride, asOf` |
| `POST /primitives/memories/ingest` | Mem0-style judge that decides ADD/UPDATE/DELETE/NOOP against similar rows | body: `content*, kind*, tags, model, candidateK, linkedIds` |
| `GET` · `PATCH /primitives/memory-settings` | The ingest judge model used when an ingest sends no `model` (PATCH: platform admins; only a chat model every user may call, else `400` naming the eligible ones) | PATCH body: `ingestModel*` |
| `POST /primitives/memories/consolidate` | Sleep-time pass: dedup, evict stale, promote used. `dryRun` to preview | body: `config, dryRun` |
| `POST /primitives/memories/:id/assess` | The quality ruleset's full report (each check); the score is also kept on the row (`scoreResult`) by every write | |
| `POST /primitives/memories/:id/invalidate` | Mark contradicted/superseded (sets `validUntil=now`) | body: `supersededBy` |
| `POST /primitives/memories/:id/access-events` | Record a use (`usageCount`, `lastAccessedAt`); `201` with `{ usageCount }` | |
| `POST /primitives/memories/:id/links` · `DELETE /primitives/memories/:memoryId/links/:id` · `GET /primitives/memories/:id/backlinks` | Add/update, remove, and reverse-lookup graph edges | link body: `targetId*, relation*, weight` |
| `GET /primitives/memories/:id/versions` · `GET /primitives/memories/:memoryId/versions/:version` · `POST …/versions/:version/restore` | Version history + restore | |
| `GET/PATCH /primitives/memories/:id/permissions` · `POST …/permissions/members` · `DELETE /primitives/memories/:memoryId/permissions/members/:userId` | Who can reach it / visibility, share with a user, stop sharing | member body: `userId*, role*` |
| `POST /primitives/memories/:id/promote` · `POST /primitives/memories/:id/demote` | Promote/demote to org-global so EVERY agent in the org reads it | |
| `GET /primitives/memories/export` · `POST /primitives/memories/import` | Bulk JSON dump / re-ingest (returns `imported, unchanged, skipped, errors`) | import body: `memories*` |

`kind`: `fact | episodic | semantic | instruction | preference`. Link `relation`:
`supports | contradicts | refines | related`.

```bash
# Store a fact for an agent, then recall it with the ready-to-inject context block.
curl -s -X POST "${auth[@]}" "$BASE/primitives/memories" -H 'Content-Type: application/json' \
  -d '{"kind":"fact","content":"ACME renews on 2026-03-01","tags":["acme","renewal"],
       "importance":0.8,"linkedIds":["<agentWorkflowId>"]}'                 # -> data.memoryId

curl -s -X POST "${auth[@]}" "$BASE/primitives/memories/search" -H 'Content-Type: application/json' \
  -d '{"q":"when does ACME renew","limit":5,"linkedIds":["<agentWorkflowId>"]}' \
  | jq '.data.contextBlock'
```

Checklist:
- [ ] `kind` + `content` on create; attach agents via `linkedIds`.
- [ ] Recall with `POST /primitives/memories/search` (ANY pool) and inject `data.contextBlock`.
- [ ] Supersede, do not delete, when a fact changes: `POST /primitives/memories/:id/invalidate`.

---

## 2. Rules

Hard constraints and preferences the agent must honour. Trigger-matched, hierarchy-
ordered (`system > org > user > agent`), enforceable at the tool boundary, versioned.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /primitives/rules` | List | `category, severity, hierarchyScope, enabled, tags, linkedIds, q, limit, cursor` |
| `POST /primitives/rules` | Create | body: `description*, content*, category, severity, hierarchyScope, triggers, enabled, enforcementMode, tags, source, linkedIds` |
| `GET /primitives/rules/:id` · `PATCH /primitives/rules/:id` · `DELETE /primitives/rules/:id` | Fetch / update (new version) / delete | |
| `POST /primitives/rules/search` | Enabled rules matching turn/tool/scope, hierarchy-sorted; returns `contextBlock` | body: `userTurn, toolName, linkedIds` |
| `POST /primitives/rules/check` | Deterministic pre-tool-call gate; returns `refused` + the blocking rule | body: `toolName*, args, userTurn, linkedIds` |
| `POST /primitives/rules/:id/assess` | The quality ruleset's full report; the score is also kept on the row (`scoreResult`) by every write | |
| `POST /primitives/rules/:id/violations` · `GET /primitives/rules/:id/violations` | Record / list violations (list paginated, newest first; `limit` up to 200) | violation body: `attemptedAction*, detectedBy, agentId, threadId, runId, evidence` |
| `GET /primitives/rules/violation-summary` | Cross-rule stats over the last N days | `days, topRules, topTools` |
| `PATCH /primitives/rules/:id` `{ enabled }` | Enable/disable | |
| `GET/PATCH /primitives/rules/:id/permissions` · `POST …/permissions/members` · `DELETE /primitives/rules/:ruleId/permissions/members/:userId` | Who can reach it / visibility, share with a user, stop sharing | member body: `userId*, role*` |
| `GET /primitives/rules/:id/versions` · `GET /primitives/rules/:ruleId/versions/:version` · `POST …/versions/:version/restore` | Version history + restore | |
| `GET /primitives/rules/export` · `POST /primitives/rules/import` | Bulk dump / import: export rows (returns `imported, unchanged, skipped, errors`), or `RULE.md` files from a repo | body: `rules` or `githubUrl` |

`category`: `must | must-not | should`. `severity`: `critical | high | medium | low`.
`hierarchyScope`: `system | org | user | agent`. `enforcementMode`:
`inject | gate | both`. `triggers`: `{keywords?, toolName?, embedding?, always?}`.
A `critical` or `high` rule loads on every turn whatever its triggers; a `medium` or
`low` rule loads when `always` is set, a keyword or tool name matches, or the turn is
close in meaning to it (and with no keywords or tool names, on every turn of the agents
it is linked to). Assess checks report `status` `pass | fail | skipped`; skipped ones
do not apply and are not scored.

```bash
# A hard constraint, then the pre-tool-call gate an agent runs before a dangerous tool.
curl -s -X POST "${auth[@]}" "$BASE/primitives/rules" -H 'Content-Type: application/json' \
  -d '{"description":"Never email customers without approval","content":"Refuse send_email unless approved.",
       "category":"must-not","enforcementMode":"gate","triggers":{"toolName":"send_email"},
       "linkedIds":["<agentWorkflowId>"]}'                                  # -> data.ruleId

curl -s -X POST "${auth[@]}" "$BASE/primitives/rules/check" -H 'Content-Type: application/json' \
  -d '{"toolName":"send_email","linkedIds":["<agentWorkflowId>"]}' | jq '.data.refused'
```

Checklist:
- [ ] `must-not` + `enforcementMode:"gate"` (or `both`) for anything you want the gate to block.
- [ ] Inject matched rules with `POST /primitives/rules/search` (`contextBlock`) AND gate with `/tool-gate` before dispatch.
- [ ] Editing a rule creates a new version; restore from `/versions/:n/restore`.

---

## 3. Prompts

Reusable prompt text (system, user, or template) with variables, versions, and
semantic search.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /library/prompts` | List | `q, type, tags, linkedIds, limit, cursor` |
| `GET /library/prompts/search` | Search by meaning and words at once (vector + text, fused), best first; each hit has a rank `score` | `q*, type, tags, limit, popularity, mmr, mmrLambda` |
| `POST /library/prompts` | Create | body: `name*, content*, type, description, variables, tags, linkedIds, source` |
| `GET /library/prompts/:id` · `PATCH /library/prompts/:id` · `DELETE /library/prompts/:id` | Fetch / update (new version) / delete | |
| `GET /library/prompts/:id/versions` · `POST /library/prompts/:promptId/versions/:version/restore` | Versions (each with its full `content`) + restore | |
| `POST /library/prompts/:id/duplicate` | Copy to a new prompt | |
| `POST /library/prompts/:id/render` | Substitute variables and return the rendered text; a variable with no default is required (400 naming it when missing) | body: `variables` |
| `POST /library/prompts/:id/usage-events` | Record a use; `201` with `{ usageCount }` | |

`type`: `system-prompt | user-prompt | template` (an unrecognised type is coerced
to `user-prompt`).

```bash
curl -s -X POST "${auth[@]}" "$BASE/library/prompts" -H 'Content-Type: application/json' \
  -d '{"name":"Weekly summary","type":"template","content":"Summarize {{topic}} for {{audience}}.",
       "variables":[{"name":"audience","defaultValue":"the team"}],"linkedIds":["<agentWorkflowId>"]}'  # -> data.promptId

curl -s -X POST "${auth[@]}" "$BASE/library/prompts/<id>/render" -H 'Content-Type: application/json' \
  -d '{"variables":{"topic":"sales","audience":"the board"}}' | jq '.data'
```

Checklist:
- [ ] `name` + `content` on create; pick a `type` or accept the `user-prompt` default.
- [ ] `{{variables}}` are detected from the content; give one a `defaultValue` to make it optional, and pass every variable without a default to `POST /library/prompts/:id/render`.
- [ ] Find by meaning with `GET /library/prompts/search`, not just tag/name filters.

---

## 4. Tasks

Scheduled work an agent does: recurring or one-off, heartbeat- or cron-fired,
claim-locked so a task shared by several agents is never worked twice.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /primitives/tasks` | List | `kind, status, tags, linkedIds, includeCompleted, q, dueOnly, triggerType, limit, cursor` |
| `POST /primitives/tasks` | Create | body: `description*, recurrence, dueAt, triggerType, notes, tags, subjectRef, linkedIds, assignedToAgent, createdByAgent` |
| `GET /primitives/tasks/:id` · `PATCH /primitives/tasks/:id` · `DELETE /primitives/tasks/:id` | Fetch (with its status and scheduling fields) / update (a recurrence change recomputes `nextDueAt`) / delete | |
| `POST /primitives/tasks/:id/complete` | Mark done; recurring advances to the next occurrence | body: `notes, executionId` |
| `POST /primitives/tasks/:id/claim` | First-claim-wins execution lock: answers the task, or `409` when another agent holds it | body: `claimantId*` |
| `POST /primitives/tasks/:id/cancel` | Cancel | body: `reason` |
| `POST /primitives/tasks/:id/skip-next` · `/end-recurrence` | Skip one fire / stop recurring | |
| `GET/PATCH /primitives/tasks/:id/permissions` · `POST …/permissions/members` · `DELETE /primitives/tasks/:taskId/permissions/members/:userId` | Who can reach it / visibility, share with a user, stop sharing | member body: `userId*, role*` |

`status`: `open | fired | done | failed | cancelled`. `triggerType`: `heartbeat`
(the agent completes it when it next wakes) or `scheduled` (platform cron fires it
at an exact time). `recurrence`: `{kind, timeOfDay?, dayOfWeek?, dayOfMonth?,
cron?, timezone, until?, maxFires?}` where `kind` is `daily | weekly | monthly |
cron`. **For any repeating schedule set `recurrence` and leave `dueAt` empty; use
`dueAt` only for a single one-off time.** A heartbeat task with neither `dueAt`
nor `recurrence` is intent-only: no heartbeat runs it on its own. `linkedIds` says
which agents work a task; `assignedToAgent` is only a label a Task Due workflow
trigger filters on. `PATCH` with `dueAt`, `assignedToAgent` or `subjectRef` set
to `null` removes that field. Completing a claimed task counts the run
(`fireCount`, `lastFiredAt` = claim time).

```bash
# Recurring: every weekday 9am ET. NOTE recurrence, not dueAt.
curl -s -X POST "${auth[@]}" "$BASE/primitives/tasks" -H 'Content-Type: application/json' \
  -d '{"description":"Post the standup summary","triggerType":"scheduled",
       "recurrence":{"kind":"cron","cron":"0 9 * * 1-5","timezone":"America/New_York"},
       "linkedIds":["<agentWorkflowId>"]}'                                   # -> the task, its id in data._id

# An agent claims a due task before executing it: 200 answers the task (claimedBy = you);
# 409 conflict means another agent has it (skip it).
curl -s -X POST "${auth[@]}" "$BASE/primitives/tasks/<id>/claim" -H 'Content-Type: application/json' \
  -d '{"claimantId":"<agentWorkflowId>"}' | jq '.data.claimedBy // .detail'
```

Checklist:
- [ ] Repeating schedule => `recurrence` with an IANA `timezone`, no `dueAt`.
- [ ] Poll `GET /primitives/tasks?dueOnly=true` to find work ready to run; `claim` before executing.
- [ ] `complete` a recurring task to advance it; `end-recurrence` to stop it.

---

## 5. Skills

Directory-style skills (instructions plus bundled files) an agent loads on demand,
with hybrid relevance retrieval, versions, and a quality assessor.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /library/skills` | List | `q, tags, linkedIds, category, limit, cursor` |
| `POST /library/skills` | Create (deduped: response `action` is `created`, `superseded`, or `unchanged`). `name` is kebab-case (`unit-converter`, up to 64 chars); any other name is refused | body: `name*, content*, description, category, tags, linkedIds, mcpTools, variables, source` |
| `GET /library/skills/:id` | Read full content | |
| `GET /library/skills/:id/files` · `GET /library/skills/:id/contents?path=` | List bundled files (paths + sizes) / read one file | |
| `PATCH /library/skills/:id` · `DELETE /library/skills/:id` | Update / delete | |
| `POST /library/skills/search` | Hybrid (semantic + keyword) relevance to a turn; returns `contextBlock`. No turn = `400` | body: `userTurn*, limit, tags, linkedIds` |
| `POST /library/skills/:id/render` | Variable substitution | body: `variables` |
| `POST /library/skills/:id/assess` | Score against the skill-building guide | |
| `POST /library/skills/:id/duplicate` · `POST /library/skills/:id/usage-events` | Copy / record a use (`201` with `{ usageCount }`) | |
| `GET /library/skills/:id/versions` · `POST /library/skills/:skillId/versions/:version/restore` | Versions + restore | |
| `POST /library/skills/import` | Import a skill from a GitHub URL | body: `githubUrl*` |

Skill content is markdown instructions; bundled files load on demand, so never bulk-
read a whole bundle. Report the `action` from create truthfully (say "updated" for
`superseded`, "you already have that" for `unchanged`).

```bash
curl -s -X POST "${auth[@]}" "$BASE/library/skills" -H 'Content-Type: application/json' \
  -d '{"name":"invoice-parser","description":"Extract totals from PDFs",
       "content":"# Invoice Parser\n...","tags":["finance"],"linkedIds":["<agentWorkflowId>"]}' \
  | jq '.data.action'                                                        # created | superseded | unchanged

curl -s -X POST "${auth[@]}" "$BASE/library/skills/search" -H 'Content-Type: application/json' \
  -d '{"userTurn":"parse this invoice","linkedIds":["<agentWorkflowId>"]}' | jq '.data.contextBlock'
```

Checklist:
- [ ] Before creating, call `POST /library/skills/search` or `GET /library/skills?q=` to update an existing skill instead of forking a duplicate.
- [ ] Progressive disclosure: `/files` then `/contents?path=`, never a bulk bundle read.
- [ ] Surface the create `action` accurately to the user.

---

## 6. Preferences

Learned user preferences (`key=value`), upserted by key, turn-relevant, versioned via
supersession.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /primitives/preferences` | List | `q, category, preferenceSource, tags, linkedIds, includeSuperseded, limit, cursor` |
| `POST /primitives/preferences` | Set (idempotent upsert on `(owner, key)`) | body: `key*, value*, category, preferenceSource, confidence, evidence, tags, linkedIds` |
| `GET /primitives/preferences/:id` | Read one by id | |
| `GET /primitives/preferences/by-key/:key` | Look up the active value for a key (null if unset) | `touch` |
| `PATCH /primitives/preferences/:id` | Update only supplied fields; a new `value` supersedes (old value kept as history) and returns the new row, with a new id | body: `value, category, preferenceSource, confidence, evidence, tags, linkedIds` |
| `DELETE /primitives/preferences/:id` · `POST /primitives/preferences/forget` | Delete by id / by key (idempotent): the current value goes with its earlier values; a superseded value goes alone | forget body: `key*` |
| `POST /primitives/preferences/search` | Turn-aware relevance; returns `contextBlock` | body: `userTurn, category, limit, tags, linkedIds` |
| `GET/PATCH /primitives/preferences/:id/permissions` · `POST …/permissions/members` · `DELETE /primitives/preferences/:preferenceId/permissions/members/:userId` | Who can reach it / visibility, share with a user, stop sharing | member body: `userId*, role*` |

`preferenceSource` must be one of the platform's allowed sources (an invalid value
returns a `400` listing the accepted set).

```bash
curl -s -X POST "${auth[@]}" "$BASE/primitives/preferences" -H 'Content-Type: application/json' \
  -d '{"key":"preferred_language","value":"Python","confidence":0.9,
       "evidence":"User said so on 2026-09-10","linkedIds":["<agentWorkflowId>"]}'  # idempotent by key

curl -s "${auth[@]}" "$BASE/primitives/preferences/by-key/preferred_language" | jq '.data.value'
```

Checklist:
- [ ] Setting the same `key` again upserts (no duplicate); do not delete-then-recreate.
- [ ] Read a single value with `GET /primitives/preferences/by-key/:key`; inject a set with `POST /primitives/preferences/search`.
- [ ] `forget` by key is idempotent (`removedId:null` when nothing was set).

---

## 7. Pools (named bundles of primitives)

A **pool** is a named collection that groups Library primitives (memory, skills,
and the rest) so they can be shared or reused as a unit. You attach a primitive to
a pool by putting the pool id in that primitive's `linkedIds`. Scopes: `custom` (a
private bundle), `imprint` (a distributable skills+memory bundle), `org-global`
(the single pool every agent in the org reads), `agent`.

| Endpoint | Purpose | Notes |
|---|---|---|
| `GET /library/pools` | List pools you can see | `?scope=custom\|imprint\|org-global\|agent`, `?counts=true` for per-primitive usage counts (`memory:read`) |
| `POST /library/pools` | Create a named pool; returns its id | body: `name*, description, scope` (`custom` default, or `imprint`) (`memory:write`) |
| `GET /library/pools?scope=org-global` | Get-or-create the org-global pool | promote a memory here so the whole org sees it (`memory:read`) |
| `GET /library/pools/:id` | Get one pool with usage counts | (`memory:read`) |
| `PATCH /library/pools/:id` · `DELETE /library/pools/:id` | Update / delete a pool | (`memory:write`) |

Pools ride the `memory:read` / `memory:write` scopes (they are part of the
memory/skill bundle system). The returned pool id is what you pass in `linkedIds`
when creating the memory, skills, etc. that should belong to the bundle.

```bash
POOL_ID=$(curl -s -X POST "${auth[@]}" "$BASE/library/pools" -H 'Content-Type: application/json' \
  -d '{"name":"Helicopter Piloting","scope":"imprint"}' | jq -r '.data._id')
# attach primitives to it via linkedIds: ["$POOL_ID"] when you create them
```

Checklist:
- [ ] Create or find the pool first, then put its id in `linkedIds` on the primitives that belong to it.
- [ ] `scope:"imprint"` for a distributable skills+memory bundle; `GET /library/pools?scope=org-global` for the org-wide pool.

---

## Checklist (all primitives)
- [ ] Right scope on the key: `<primitive>:read` for reads, `<primitive>:write` for writes.
- [ ] Attach rows to agents with `linkedIds` (agent `workflowId`); AND on list filters, ANY on recall.
- [ ] Inject with the retrieval endpoint's `data.contextBlock`; browse with plain `GET` lists.
- [ ] Prefer supersede/version over destructive delete (memory `invalidate`, rules/prompts/skills versions, preferences upsert).
- [ ] Repeating tasks use `recurrence` (never a one-off `due_at`); claim before executing shared tasks.
- [ ] Artifacts live in `references/apps.md`; the agent runtime that consumes all of this lives in `references/agents.md`.
