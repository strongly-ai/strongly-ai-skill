# Imprints

An **Imprint** is a named, distributable bundle of Library primitives (skills,
memories, rules, prompts, tasks, preferences) that an agent can **learn in one
step**. Build an imprint once (say "Helicopter Piloting" or "Invoice Handling"),
fill it with the skills and memories that make an agent good at that job, then
**install** it on any agent. The agent starts recalling everything in the bundle,
no per-row wiring.

Read this when the task is: packaging a set of skills/memories so it can be reused
or shared as a unit, browsing the imprints you can install, or teaching an agent a
whole capability at once by installing an imprint onto it.

> **An Imprint is a pool with `scope:"imprint"`.** The generic mechanics of pools
> and of the primitives inside them (memory, rules, prompts, tasks, skills,
> preferences, and how `linkedIds` attaches a row to a bundle) live in
> `references/library.md`. This file is the imprint-specific surface; it does not
> re-document pools. Read `references/library.md` for the primitives themselves.

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key: $STRONGLY_API_KEY"`
to `$HOST/api/v1`; inside Strongly call `$STRONGLY_API_URL/api/v1` with the bearer
auto-injected. Below, `$BASE` is whichever applies and `auth` is the header:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # outside Strongly
# inside Strongly: BASE="$STRONGLY_API_URL/api/v1"; auth=()      # bearer injected
```

Every read needs the **`memory:read`** scope; every write needs **`memory:write`**
(imprints ride the same scopes as the memory/skill bundle system). A missing scope
returns `403`. Envelope is the standard `{ "success": true, "data": … }`; read
`data`, surface `error.message` on failure.

## Endpoints

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/imprints` | List imprints you can see, with per-primitive content counts | `memory:read` |
| POST | `/imprints` | Create an imprint; returns its id | `memory:write` |
| GET | `/imprints/:id` | Get one imprint with its contents (rows grouped by primitive) + counts | `memory:read` |
| DELETE | `/imprints/:id` | Delete an imprint | `memory:write` |
| POST | `/imprints/:id/items` | Add an existing library row to the imprint | `memory:write` |
| DELETE | `/imprints/:id/items/:resourceType/:resourceId` | Remove a row from the imprint | `memory:write` |
| POST | `/imprints/:id/install` | Install the imprint on an agent | `memory:write` |
| DELETE | `/imprints/:id/install/:agentId` | Uninstall the imprint from an agent | `memory:write` |

---

## 1. List imprints

Find an imprint to install, or check what already exists before building a new one.
Each row carries content counts so you can see how much a bundle holds.

```bash
curl -s "${auth[@]}" "$BASE/imprints" | jq '.data'
```

---

## 2. Create an imprint

Give it a name and a one-line description of what an agent learns from it. The
response returns the new id as both `_id` and `imprintId`.

```bash
IMPRINT_ID=$(curl -s -X POST "${auth[@]}" "$BASE/imprints" -H 'Content-Type: application/json' \
  -d '{"name":"Helicopter Piloting","description":"What an agent needs to fly a helicopter"}' \
  | jq -r '.data.imprintId')
```

Body: `name` (required), `description` (optional). `name` is the only required
field; a create without it returns `400`.

---

## 3. Fill it with skills and memories

There are two ways to put a primitive into an imprint:

1. **Attach an existing row** with `POST /imprints/:id/items`. This adds a row you
   already created (skill, memory, rule, prompt, task, preference) to the imprint
   **without disturbing its other memberships**, and it is **idempotent** (adding
   the same row twice is a no-op).
2. **Create the row with the imprint in `linkedIds`.** When you create the memory
   or skill itself (see `references/library.md`), pass the imprint id in its
   `linkedIds`. Same result, done at creation time.

Attach an existing skill and an existing memory to the imprint:

```bash
curl -s -X POST "${auth[@]}" "$BASE/imprints/$IMPRINT_ID/items" -H 'Content-Type: application/json' \
  -d '{"resourceType":"skills","resourceId":"<skillId>"}' | jq '.data'

curl -s -X POST "${auth[@]}" "$BASE/imprints/$IMPRINT_ID/items" -H 'Content-Type: application/json' \
  -d '{"resourceType":"memory","resourceId":"<memoryId>"}' | jq '.data'
```

`resourceType` is one of `memory | rules | skills | prompts | tasks | artifacts |
preferences`; `resourceId` is the id of the row to add. Both are required. Remove a
row from the bundle (it stays in your Library, only its membership is dropped):

```bash
curl -s -X DELETE "${auth[@]}" "$BASE/imprints/$IMPRINT_ID/items/skills/<skillId>"
```

---

## 4. Inspect an imprint

Get the imprint plus everything it bundles, grouped by primitive type, with usage
counts. Use this to confirm a bundle is complete before installing it.

```bash
curl -s "${auth[@]}" "$BASE/imprints/$IMPRINT_ID" | jq '.data.contents'
```

An unknown id returns `404 not-found`.

---

## 5. Install an imprint on an agent

Installing subscribes an agent to the imprint's recall: from then on the agent
recalls the bundle's skills and memories as its own. Pass the agent's id (its
workflow id, see `references/agents.md`). **Restart the agent to apply.**

```bash
curl -s -X POST "${auth[@]}" "$BASE/imprints/$IMPRINT_ID/install" -H 'Content-Type: application/json' \
  -d '{"agentId":"<agentId>"}' | jq '.data'
```

`agentId` is required; an unknown agent returns `404 not-found`. Uninstall to
detach the bundle from that agent again:

```bash
curl -s -X DELETE "${auth[@]}" "$BASE/imprints/$IMPRINT_ID/install/<agentId>"
```

---

## Checklist
- [ ] Right scope on the key: `memory:read` to list/get, `memory:write` to create/fill/install.
- [ ] Reuse before you build: `GET /imprints` to see if a bundle already covers the capability.
- [ ] Fill by attaching existing rows (`POST /:id/items`, idempotent) or by setting the imprint id in a primitive's `linkedIds` at creation time.
- [ ] `GET /imprints/:id` and check `data.contents` before installing, so you install a complete bundle.
- [ ] After `install`, restart the agent so it picks up the imprint's recall.
- [ ] The primitives inside an imprint (memory, rules, skills, …) and pool mechanics live in `references/library.md`; the agent side lives in `references/agents.md`.
