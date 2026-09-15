# Governance

Strongly **governance** is how an org states what must be true before a resource
ships and proves it stayed true. Three things make it up:

- **Policies** are the rules (stages and gates) that apply to given resource
  types (models, apps, workflows, and more).
- **Solutions** are resources put through governance: gates get submitted,
  reviewed, and either pass, fail, or are waived, with **evidence** files
  attached as proof. An **enforcement check** turns that state into a
  deploy allow/deny.
- **Guardrails** are AI Gateway content rules (PII, jailbreak, toxicity) that
  block or modify a model's inputs and outputs at inference time.

Read this when the task is: authoring or editing a policy, running a resource
through its gates, approving or waiving a gate, downloading evidence, checking
whether a resource is allowed to deploy, or configuring guardrails on a gateway
model.

**Auth** follows the two-context rule in `SKILL.md`: outside Strongly send
`X-API-Key` to `$HOST/api/v1`; inside Strongly the bearer is auto-injected on
`$STRONGLY_API_URL/api/v1`. `$BASE` is whichever applies. Set once (outside
Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # see SKILL.md
```

Scopes: `governance:read` / `governance:write` on `/governance/*`;
`guardrails:read` / `guardrails:write` on `/guardrails/*`. Every response is the
standard envelope (`data` on success, `error.message` on failure).

---

## 1. Policies

A policy is the rule set. It carries a `category`, a `severity`, the
`applicableResourceTypes` it governs, and a `stages` array (each stage holds the
gates a resource must clear). `create` returns `data.policyId`.

```bash
# List (optional filters: category, severity, isActive, search)
curl -s "${auth[@]}" "$BASE/governance/policies?isActive=true&category=compliance" | jq '.data'

# Create -> data.policyId
POLICY=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "name":"Model card required",
  "description":"Every AI model ships a completed model card before deploy",
  "category":"compliance",
  "severity":"high",
  "applicableResourceTypes":["mlModel","aiGatewayModel"],
  "stages":[],
  "isActive":true,
  "isDraft":false
}' "$BASE/governance/policies" | jq -r '.data.policyId')

# Get, update, delete
curl -s "${auth[@]}" "$BASE/governance/policies/$POLICY" | jq '.data'
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"isActive":false}' "$BASE/governance/policies/$POLICY" | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/governance/policies/$POLICY"
```

`stages` is an array of stage objects (each containing gates); the shape is what
the policy builder produces. Do not hand-author it blind. `GET` an existing
policy and copy its `stages` shape rather than guessing field names.

`applicableResourceTypes` must be drawn from the platform's fixed list. Fetch it:

```bash
curl -s "${auth[@]}" "$BASE/governance/resource-types" | jq -r '.data[].id'
# app workflow addon dataSource volume mlModel aiGatewayModel workspace project
# skill prompt agent codeSession abTest marketplaceApp
```

Org-wide views:

```bash
curl -s "${auth[@]}" "$BASE/governance/metrics" | jq '.data'                 # aggregate counts
curl -s "${auth[@]}" "$BASE/governance/audit?action=approve" | jq '.data'    # admin only
```

| Method + path | Scope | Does |
|---|---|---|
| `GET /governance/policies` | `governance:read` | List policies (`category`, `severity`, `isActive`, `search`) |
| `POST /governance/policies` | `governance:write` | Create a policy, returns `data.policyId` |
| `GET /governance/policies/:id` | `governance:read` | Get one policy |
| `PUT /governance/policies/:id` | `governance:write` | Update a policy |
| `DELETE /governance/policies/:id` | `governance:write` | Delete a policy |
| `GET /governance/resource-types` | `governance:read` | Resource types a policy can target |
| `GET /governance/metrics` | `governance:read` | Aggregate governance metrics |
| `GET /governance/audit` | `governance:read` (admin) | Governance audit log (admin only; filters `entityType`, `action`, `userId`, `startDate`, `endDate`) |

---

## 2. Solutions and gates

A **solution** is a resource under governance. Create it, ask what it needs, then
submit each gate, get it reviewed, and check whether it may deploy. `create`
returns `data.solutionId`.

```bash
# Create -> data.solutionId
SOL=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Fraud model v2","description":"Q3 fraud scoring model"}' \
  "$BASE/governance/solutions" | jq -r '.data.solutionId')

# What must this solution clear? (policies + gates that apply)
curl -s "${auth[@]}" "$BASE/governance/solutions/$SOL/requirements" | jq '.data'

# Submit one gate. gateId is in the path; body names the owning policy + payload.
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"policyId":"'"$POLICY"'","data":{"answer":"yes","notes":"attached"}}' \
  "$BASE/governance/solutions/$SOL/gates/$GATE_ID/submit" | jq '.data'

# Recompute the solution's overall status after submissions change
curl -s -X POST "${auth[@]}" "$BASE/governance/solutions/$SOL/recompute" | jq '.data'
```

Review side (the approver):

```bash
# Gates awaiting YOUR approval
curl -s "${auth[@]}" "$BASE/governance/gate-submissions/pending-reviews" | jq '.data'

# Decide a submission: decision is approved | denied | conditional
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"decision":"approved","comments":"LGTM"}' \
  "$BASE/governance/gate-submissions/$SUB_ID/approve" | jq '.data'

# Admin only: waive a gate with a reason (reason is required)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"reason":"Accepted risk, signed off by CISO"}' \
  "$BASE/governance/gate-submissions/$SUB_ID/waive" | jq '.data'
```

Enforcement turns governance state into a deploy decision. Both query params are
required:

```bash
curl -s "${auth[@]}" \
  "$BASE/governance/enforcement/check?resourceType=mlModel&resourceId=$RES_ID" | jq '.data'
```

| Method + path | Scope | Does |
|---|---|---|
| `GET /governance/solutions` | `governance:read` | List solutions (`status`, `search`) |
| `POST /governance/solutions` | `governance:write` | Create a solution, returns `data.solutionId` |
| `GET /governance/solutions/:id` | `governance:read` | Get one solution |
| `PUT /governance/solutions/:id` | `governance:write` | Update a solution (`name`, `description`) |
| `DELETE /governance/solutions/:id` | `governance:write` | Delete a solution |
| `GET /governance/solutions/:id/requirements` | `governance:read` | Policies + gates that apply to it |
| `POST /governance/solutions/:id/gates/:gateId/submit` | `governance:write` | Submit gate data (body: `policyId`, `data`) |
| `POST /governance/solutions/:id/recompute` | `governance:write` | Recompute the solution's status |
| `GET /governance/gate-submissions/pending-reviews` | `governance:read` | Gates awaiting the caller's approval |
| `POST /governance/gate-submissions/:id/approve` | `governance:write` | Approve, deny, or conditionally approve (body: `decision`, `comments`) |
| `POST /governance/gate-submissions/:id/waive` | `governance:write` | Admin-only waive (body: `reason`) |
| `GET /governance/enforcement/check` | `governance:read` | Can a resource deploy? (query: `resourceType`, `resourceId`) |

---

## 3. Evidence

Evidence files are the proof attached to a solution's gate submissions. This
endpoint streams one file's bytes by id. Access is checked against the owning
solution first, so the caller must be able to read that solution. The response is
binary with a `Content-Disposition: attachment` filename, so write it to disk:

```bash
curl -s "${auth[@]}" "$BASE/governance/evidence/$FILE_ID" -o evidence.pdf
```

| Method + path | Scope | Does |
|---|---|---|
| `GET /governance/evidence/:id` | `governance:read` | Stream an evidence file blob (attachment) |

---

## 4. Guardrails (AI Gateway)

Guardrails are content rules enforced on a gateway model's inputs and outputs.
They live on the model, so the full picture (how they run during a call, provider
keys, inference) is in `references/ai-gateway.md`. This section is the config
surface only.

A model's config is `enabled` plus two lists: `guardrail_rules` (template rule
IDs from `GET /guardrails/templates`) and `custom_rules` (rule objects). `PUT`
replaces the whole config, so send the full desired state; an empty array clears
a list.

```bash
# Which models can be protected, and are guardrails on?
curl -s "${auth[@]}" "$BASE/guardrails/models" | jq '.data'

# Built-in template rule IDs to use in guardrail_rules
curl -s "${auth[@]}" "$BASE/guardrails/templates" | jq -r '.data[].id'

# Replace a model's config (both arrays required; empty clears)
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "guardrail_rules":["<template-id>","<template-id>"],
  "custom_rules":[]
}' "$BASE/guardrails/models/$MODEL_ID" | jq '.data'

# Dry-run rules on sample text before enabling (direction: input | output)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"model_id":"'"$MODEL_ID"'","input":"sample text","direction":"input"}' \
  "$BASE/guardrails/test" | jq '.data'

# Turn enforcement on/off without touching the rules
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"enabled":true}' "$BASE/guardrails/models/$MODEL_ID/toggle" | jq '.data'

# What fired, and aggregate stats
curl -s "${auth[@]}" "$BASE/guardrails/logs?limit=50" | jq '.data'
curl -s "${auth[@]}" "$BASE/guardrails/statistics" | jq '.data'
```

| Method + path | Scope | Does |
|---|---|---|
| `GET /guardrails/models` | `guardrails:read` | Models with guardrail on/off status |
| `GET /guardrails/models/:id` | `guardrails:read` | A model's guardrail config (`enabled`, `guardrail_rules`, `custom_rules`) |
| `PUT /guardrails/models/:id` | `guardrails:write` | Replace config (`guardrail_rules`, `custom_rules`, both required) |
| `POST /guardrails/models/:id/toggle` | `guardrails:write` | Enable/disable enforcement (body: `enabled`) |
| `POST /guardrails/test` | `guardrails:write` | Dry-run rules on text (body: `model_id`, `input`; optional `rules`, `direction`) |
| `GET /guardrails/templates` | `guardrails:read` | Built-in rule templates |
| `GET /guardrails/logs` | `guardrails:read` | Blocked/modified request logs (query: `modelId`, `limit`) |
| `GET /guardrails/statistics` | `guardrails:read` | Aggregate guardrail statistics |

---

## Checklist
- [ ] Policy `stages` copied from an existing policy's shape, not hand-guessed.
- [ ] `applicableResourceTypes` values drawn from `GET /governance/resource-types`.
- [ ] Solution flow in order: create, read `requirements`, `submit` each gate, review, `recompute`.
- [ ] `decision` is one of `approved`, `denied`, `conditional`; `waive` needs a `reason` and is admin-only.
- [ ] Deploy gating read from `GET /governance/enforcement/check` (both `resourceType` and `resourceId`), not assumed.
- [ ] Evidence streamed to a file; caller has read access to the owning solution.
- [ ] Guardrail `PUT` sends the full desired state; `guardrail_rules` IDs come from `GET /guardrails/templates`; test before `toggle` on. See `references/ai-gateway.md` for enforcement at inference.
