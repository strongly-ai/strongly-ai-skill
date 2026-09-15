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

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key: $STRONGLY_API_KEY"`
to `$HOST/api/v1`; inside Strongly call `$STRONGLY_API_URL/api/v1` with the bearer
auto-injected. Below, `$BASE` is whichever applies and `auth` is the header:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # outside Strongly
# inside Strongly: BASE="$STRONGLY_API_URL/api/v1"; auth=()      # bearer injected
```

## Conventions that hold across every primitive

- **Envelope.** Success is `{ "success": true, "data": … }`; lists add
  `pagination`. Read `data`; surface `error.message` on failure. (Same as `SKILL.md`.)
- **Scopes.** Reads need `<primitive>:read`, writes need `<primitive>:write`
  (`memory:read`, `rules:write`, `tasks:read`, …). A missing scope returns `403`.
- **Visibility is user-level:** owner, then rows shared with you, then public.
  Memory, rules, tasks, and preferences expose `POST /:id/share` and `/:id/unshare`
  (a `userId`) plus `POST /:id/toggle-public`; memory adds org-global promotion.
  Prompts and skills have no per-row share endpoints.
- **`linkedIds` = agent membership.** Pass agent `workflowId`s to attach a row to
  agents (a row can belong to many). On **list/GET** filters, `linkedIds` is AND
  (a row must belong to ALL supplied ids). On **recall** endpoints
  (`/search`, `/applicable`, `/relevant`) it is ANY (match rows in any linked pool).
- **`tags`** on list endpoints are comma-separated with AND semantics (a row must
  carry every supplied tag).
- **Versioning.** Memory, rules, prompts, and skills keep full version history:
  each has `GET /:id/versions` plus a restore that appends a new version rather than
  mutating history. Memory and rules also expose a single-version read
  (`GET /:id/versions/:n`) and restore by path (`POST /:id/versions/:n/restore`);
  prompts and skills restore via `POST /:id/restore` with `versionNumber` in the body.
- **Retrieval blocks.** `POST /memory/search`, `POST /rules/applicable`,
  `POST /skills/relevant`, and `POST /preferences/relevant` each return both the
  matched rows and a canonical markdown `contextBlock` an agent drops straight into
  its system prompt. Use these for injection; use plain `GET` lists to browse.

---

## 1. Memory

Durable facts and episodes an agent recalls. Bitemporal (`validFrom`/`validUntil`
+ `asOf`), hybrid-searchable, versioned, and graph-linkable.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /memory` | List | `kind, tags, linkedIds, search, asOf, includeInvalidated, limit, offset` |
| `POST /memory` | Create | body: `kind*, content*, summary, tags, category, importance, confidence, links, linkedIds, source, eventTime, validFrom, validUntil` |
| `GET /memory/:id` · `PUT /memory/:id` · `DELETE /memory/:id` | Fetch / update (content change appends a version) / delete | update body adds `changeNote` |
| `POST /memory/search` | Hybrid BM25 + dense-vector search with RRF fusion and temporal-decay re-rank; returns `contextBlock` | body: `query*, k, kind, tags, linkedIds, weights, rrfK, decayHalfLifeDaysOverride, asOf, rerank, rerankModel, includeInvalidated` |
| `POST /memory/ingest` | Mem0-style judge that decides ADD/UPDATE/DELETE/NOOP against similar rows | body: `content*, kind*, tags, model, candidateK, linkedIds` |
| `POST /memory/consolidate` | Sleep-time pass: dedup, evict stale, promote used. `dryRun` to preview | body: `config, dryRun` |
| `POST /memory/:id/assess` | Run the quality ruleset, cache the score | |
| `POST /memory/:id/invalidate` | Mark contradicted/superseded (sets `validUntil=now`) | body: `supersededBy` |
| `POST /memory/:id/access` | Increment `usageCount` + `lastAccessedAt` | |
| `POST /memory/:id/links` · `DELETE /memory/:id/links/:targetId` · `GET /memory/:id/linked-to` | Add/update, remove, and reverse-lookup graph edges | link body: `targetId*, relation*, weight` |
| `GET /memory/:id/versions` · `/versions/:n` · `POST /versions/:n/restore` | Version history + restore | |
| `POST /memory/:id/share` · `/unshare` · `/toggle-public` | Per-user share/revoke, public toggle | share body: `userId*` |
| `POST /memory/:id/share-to-org` · `DELETE` same path | Promote/demote to org-global so EVERY agent in the org reads it | |
| `GET /memory/export` · `POST /memory/import` | Bulk JSON dump / re-ingest | |

`kind`: `fact | episodic | semantic | instruction | preference`. Link `relation`:
`supports | contradicts | refines | related`.

```bash
# Store a fact for an agent, then recall it with the ready-to-inject context block.
curl -s -X POST "${auth[@]}" "$BASE/memory" -H 'Content-Type: application/json' \
  -d '{"kind":"fact","content":"ACME renews on 2026-03-01","tags":["acme","renewal"],
       "importance":0.8,"linkedIds":["<agentWorkflowId>"]}'                 # -> data.memoryId

curl -s -X POST "${auth[@]}" "$BASE/memory/search" -H 'Content-Type: application/json' \
  -d '{"query":"when does ACME renew","k":5,"linkedIds":["<agentWorkflowId>"]}' \
  | jq '.data.contextBlock'
```

Checklist:
- [ ] `kind` + `content` on create; attach agents via `linkedIds`.
- [ ] Recall with `POST /memory/search` (ANY pool) and inject `data.contextBlock`.
- [ ] Supersede, do not delete, when a fact changes: `POST /:id/invalidate`.

---

## 2. Rules

Hard constraints and preferences the agent must honour. Trigger-matched, hierarchy-
ordered (`system > org > user > agent`), enforceable at the tool boundary, versioned.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /rules` | List | `category, severity, hierarchyScope, enabled, tags, linkedIds, search, limit, offset` |
| `POST /rules` | Create | body: `description*, content*, category, severity, hierarchyScope, triggers, enabled, enforcementMode, tags, source, linkedIds` |
| `GET /rules/:id` · `PUT /rules/:id` · `DELETE /rules/:id` | Fetch / update (new version) / delete | |
| `POST /rules/applicable` | Enabled rules matching turn/tool/scope, hierarchy-sorted; returns `contextBlock` | body: `userTurn, toolName, linkedIds` |
| `POST /rules/tool-gate` | Deterministic pre-tool-call gate; returns `refused` + blocking rule | body: `toolName*, args, userTurn, linkedIds` |
| `POST /rules/check` | Pattern pre-call gate; returns `allowed, blockedBy, reason` | body: `toolName, description, args, userTurn` |
| `POST /rules/:id/assess` | Quality ruleset score | |
| `POST /rules/:id/violation` · `GET /rules/:id/violations` | Record / list violations (list paginated) | violation body: `attemptedAction*, detectedBy, threadId, runId, evidence` |
| `GET /rules/violations/aggregate` | Cross-rule stats over the last N days | `days, topRules, topTools` |
| `POST /rules/:id/toggle-enabled` · `/toggle-public` · `/share` · `/unshare` | Enable/disable, public toggle, per-user share/revoke | share body: `userId*` |
| `GET /rules/:id/versions` · `/versions/:n` · `POST /versions/:n/restore` | Version history + restore | |
| `GET /rules/export` · `POST /rules/import` · `POST /rules/import-github` | Bulk dump / re-ingest / import `RULE.md` from a repo | github body: `githubUrl*` |

`category`: `must | must-not | should`. `severity`: `critical | high | medium | low`.
`hierarchyScope`: `system | org | user | agent`. `enforcementMode`:
`inject | gate | both`. `triggers`: `{keywords?, toolName?, embedding?, always?}`.

```bash
# A hard constraint, then the pre-tool-call gate an agent runs before a dangerous tool.
curl -s -X POST "${auth[@]}" "$BASE/rules" -H 'Content-Type: application/json' \
  -d '{"description":"Never email customers without approval","content":"Refuse send_email unless approved.",
       "category":"must-not","enforcementMode":"gate","triggers":{"toolName":"send_email"},
       "linkedIds":["<agentWorkflowId>"]}'                                  # -> data.ruleId

curl -s -X POST "${auth[@]}" "$BASE/rules/tool-gate" -H 'Content-Type: application/json' \
  -d '{"toolName":"send_email","linkedIds":["<agentWorkflowId>"]}' | jq '.data.refused'
```

Checklist:
- [ ] `must-not` + `enforcementMode:"gate"` (or `both`) for anything you want the gate to block.
- [ ] Inject matched rules with `POST /rules/applicable` (`contextBlock`) AND gate with `/tool-gate` before dispatch.
- [ ] Editing a rule creates a new version; restore from `/versions/:n/restore`.

---

## 3. Prompts

Reusable prompt text (system, user, or template) with variables, versions, and
semantic search.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /prompts` | List | `search, type, tags, linkedIds, limit, offset` |
| `GET /prompts/search` | Semantic search with keyword fallback | `q, type, limit, popularity, mmr, mmr_lambda` |
| `POST /prompts` | Create | body: `name*, content*, type, description, variables, tags, linkedIds, source` |
| `GET /prompts/:id` · `PUT /prompts/:id` · `DELETE /prompts/:id` | Fetch / update (new version) / delete | |
| `GET /prompts/:id/versions` · `POST /prompts/:id/restore` | Versions + restore | restore body: `versionNumber*` |
| `POST /prompts/:id/duplicate` | Copy to a new prompt | |
| `POST /prompts/:id/render` | Substitute variables and return the rendered text | body: `variables` |
| `POST /prompts/:id/usage` | Record a usage event | |

`type`: `system-prompt | user-prompt | template` (an unrecognised type is coerced
to `user-prompt`).

```bash
curl -s -X POST "${auth[@]}" "$BASE/prompts" -H 'Content-Type: application/json' \
  -d '{"name":"Weekly summary","type":"template","content":"Summarize {{topic}} for {{audience}}.",
       "variables":["topic","audience"],"linkedIds":["<agentWorkflowId>"]}'  # -> data.promptId

curl -s -X POST "${auth[@]}" "$BASE/prompts/<id>/render" -H 'Content-Type: application/json' \
  -d '{"variables":{"topic":"sales","audience":"the board"}}' | jq '.data'
```

Checklist:
- [ ] `name` + `content` on create; pick a `type` or accept the `user-prompt` default.
- [ ] Declare `{{variables}}` and fill them with `POST /:id/render`.
- [ ] Find by meaning with `GET /prompts/search`, not just tag/name filters.

---

## 4. Tasks

Scheduled work an agent does: recurring or one-off, heartbeat- or cron-fired,
claim-locked so a task shared by several agents is never worked twice.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /tasks` | List | `kind, status, tags, linkedIds, includeCompleted, searchText, dueOnly, triggerType, limit, offset` |
| `POST /tasks` | Create | body: `description*, recurrence, due_at, trigger_type, notes, tags, subject_ref, linkedIds, assigned_to_agent, created_by_agent` |
| `GET /tasks/:id` · `PUT /tasks/:id` · `DELETE /tasks/:id` | Fetch / update (recurrence change recomputes `next_due_at`) / delete | |
| `GET /tasks/:id/status` | Lightweight status + scheduling fields only | |
| `POST /tasks/:id/complete` | Mark done; recurring advances to the next occurrence | body: `notes, execution_id` |
| `POST /tasks/:id/claim` | First-claim-wins execution lock | body: `claimant_id*` |
| `POST /tasks/:id/cancel` | Cancel | body: `reason` |
| `POST /tasks/:id/skip-next` · `/end-recurrence` | Skip one fire / stop recurring | |
| `POST /tasks/:id/share` · `/unshare` · `/toggle-public` | Share/revoke (accepts `userIds` array or a single `userId`), public toggle | |

`status`: `open | fired | done | failed | cancelled`. `trigger_type`: `heartbeat`
(the agent completes it when it next wakes) or `scheduled` (platform cron fires it
at an exact time). `recurrence`: `{kind, time_of_day?, day_of_week?, day_of_month?,
cron?, timezone, until?, max_fires?}` where `kind` is `daily | weekly | monthly |
cron`. **For any repeating schedule set `recurrence` and leave `due_at` empty; use
`due_at` only for a single one-off time.**

```bash
# Recurring: every weekday 9am ET. NOTE recurrence, not due_at.
curl -s -X POST "${auth[@]}" "$BASE/tasks" -H 'Content-Type: application/json' \
  -d '{"description":"Post the standup summary","trigger_type":"scheduled",
       "recurrence":{"kind":"cron","cron":"0 9 * * 1-5","timezone":"America/New_York"},
       "linkedIds":["<agentWorkflowId>"]}'                                   # -> data.taskId

# An agent claims a due task before executing it (skip if it loses the claim).
curl -s -X POST "${auth[@]}" "$BASE/tasks/<id>/claim" -H 'Content-Type: application/json' \
  -d '{"claimant_id":"<agentWorkflowId>"}' | jq '.data.claimed'
```

Checklist:
- [ ] Repeating schedule => `recurrence` with an IANA `timezone`, no `due_at`.
- [ ] Poll `GET /tasks?dueOnly=true` to find work ready to run; `claim` before executing.
- [ ] `complete` a recurring task to advance it; `end-recurrence` to stop it.

---

## 5. Skills

Directory-style skills (instructions plus bundled files) an agent loads on demand,
with hybrid relevance retrieval, versions, and a quality assessor.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /skills` | List | `search, tags, linkedIds, category, limit, offset` |
| `POST /skills` | Create (deduped: response `action` is `created`, `superseded`, or `unchanged`) | body: `name*, content*, description, category, tags, linkedIds, mcpTools, variables, source` |
| `GET /skills/:id` | Read full content | |
| `GET /skills/:id/files` · `GET /skills/:id/file?path=` | List bundled files (paths + sizes) / read one file | |
| `PUT /skills/:id` · `DELETE /skills/:id` | Update / delete | |
| `POST /skills/relevant` | Hybrid (semantic + keyword) relevance; returns `contextBlock` | body: `userTurn, limit, tags, linkedIds` |
| `POST /skills/:id/render` | Variable substitution | body: `variables` |
| `POST /skills/:id/assess` | Score against the skill-building guide | |
| `POST /skills/:id/duplicate` · `/usage` | Copy / record usage | |
| `GET /skills/:id/versions` · `POST /skills/:id/restore` | Versions + restore | restore body: `versionNumber*` |
| `POST /skills/import-github` | Import a skill from a GitHub URL | body: `githubUrl*` |

Skill content is markdown instructions; bundled files load on demand, so never bulk-
read a whole bundle. Report the `action` from create truthfully (say "updated" for
`superseded`, "you already have that" for `unchanged`).

```bash
curl -s -X POST "${auth[@]}" "$BASE/skills" -H 'Content-Type: application/json' \
  -d '{"name":"invoice-parser","description":"Extract totals from PDFs",
       "content":"# Invoice Parser\n...","tags":["finance"],"linkedIds":["<agentWorkflowId>"]}' \
  | jq '.data.action'                                                        # created | superseded | unchanged

curl -s -X POST "${auth[@]}" "$BASE/skills/relevant" -H 'Content-Type: application/json' \
  -d '{"userTurn":"parse this invoice","linkedIds":["<agentWorkflowId>"]}' | jq '.data.contextBlock'
```

Checklist:
- [ ] Before creating, call `/skills/relevant` or `GET /skills` to update an existing skill instead of forking a duplicate.
- [ ] Progressive disclosure: `/files` then `/file?path=`, never a bulk bundle read.
- [ ] Surface the create `action` accurately to the user.

---

## 6. Preferences

Learned user preferences (`key=value`), upserted by key, turn-relevant, versioned via
supersession.

| Endpoint | Purpose | Key params / body |
|---|---|---|
| `GET /preferences` | List | `search, category, preferenceSource, tags, linkedIds, includeSuperseded, limit, offset` |
| `POST /preferences` | Set (idempotent upsert on `(owner, key)`) | body: `key*, value*, category, preferenceSource, confidence, evidence, tags, linkedIds` |
| `GET /preferences/:id` | Read one by id | |
| `GET /preferences/by-key/:key` | Look up the active value for a key (null if unset) | `touch` |
| `PATCH /preferences/:id` | Update only supplied mutable fields | body: `value, category, preferenceSource, confidence, evidence, tags, linkedIds` |
| `DELETE /preferences/:id` · `POST /preferences/forget` | Delete by id / delete by key (idempotent) | forget body: `key*` |
| `POST /preferences/relevant` | Turn-aware relevance; returns `contextBlock` | body: `userTurn, category, limit, tags, linkedIds` |
| `POST /preferences/:id/share` · `/unshare` · `/toggle-public` | Per-user share/revoke, public toggle | share body: `userId*` |

`preferenceSource` must be one of the platform's allowed sources (an invalid value
returns a `400` listing the accepted set).

```bash
curl -s -X POST "${auth[@]}" "$BASE/preferences" -H 'Content-Type: application/json' \
  -d '{"key":"preferred_language","value":"Python","confidence":0.9,
       "evidence":"User said so on 2026-09-10","linkedIds":["<agentWorkflowId>"]}'  # idempotent by key

curl -s "${auth[@]}" "$BASE/preferences/by-key/preferred_language" | jq '.data.value'
```

Checklist:
- [ ] Setting the same `key` again upserts (no duplicate); do not delete-then-recreate.
- [ ] Read a single value with `GET /preferences/by-key/:key`; inject a set with `POST /preferences/relevant`.
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
| `GET /pools` | List pools you can see | `?scope=custom\|imprint\|org-global\|agent`, `?counts=true` for per-primitive usage counts (`memory:read`) |
| `POST /pools` | Create a named pool; returns its id | body: `name*, description, scope` (`custom` default, or `imprint`) (`memory:write`) |
| `POST /pools/ensure-org-global` | Get-or-create the org-global pool | promote a memory here so the whole org sees it (`memory:read`) |
| `GET /pools/:id` | Get one pool with usage counts | (`memory:read`) |
| `PUT /pools/:id` · `DELETE /pools/:id` | Update / delete a pool | (`memory:write`) |

Pools ride the `memory:read` / `memory:write` scopes (they are part of the
memory/skill bundle system). The returned pool id is what you pass in `linkedIds`
when creating the memory, skills, etc. that should belong to the bundle.

```bash
POOL_ID=$(curl -s -X POST "${auth[@]}" "$BASE/pools" -H 'Content-Type: application/json' \
  -d '{"name":"Helicopter Piloting","scope":"imprint"}' | jq -r '.data.poolId')
# attach primitives to it via linkedIds: ["$POOL_ID"] when you create them
```

Checklist:
- [ ] Create or find the pool first, then put its id in `linkedIds` on the primitives that belong to it.
- [ ] `scope:"imprint"` for a distributable skills+memory bundle; `ensure-org-global` for the org-wide pool.

---

## Checklist (all primitives)
- [ ] Right scope on the key: `<primitive>:read` for reads, `<primitive>:write` for writes.
- [ ] Attach rows to agents with `linkedIds` (agent `workflowId`); AND on list filters, ANY on recall.
- [ ] Inject with the retrieval endpoint's `data.contextBlock`; browse with plain `GET` lists.
- [ ] Prefer supersede/version over destructive delete (memory `invalidate`, rules/prompts/skills versions, preferences upsert).
- [ ] Repeating tasks use `recurrence` (never a one-off `due_at`); claim before executing shared tasks.
- [ ] Artifacts live in `references/apps.md`; the agent runtime that consumes all of this lives in `references/agents.md`.
