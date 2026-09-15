# A/B Testing

Strongly **A/B tests** put live inference traffic behind a router that splits it
across two or more **model variants**, so you can compare models on real requests
instead of guessing. A test picks one **strategy**: `weighted_random` (fixed
traffic weights per variant), `feature_based` (route by input features),
`multi_armed_bandit` (auto-optimize weights from a reward signal), or `canary`
(gradual rollout of a new variant). Once deployed the router serves through the
AI Gateway; metrics, per-variant predictions, and formal statistical experiments
sit on top.

Read this when the task is: creating or listing an A/B test, deploying it and
starting/stopping the router, tuning per-variant traffic weights, enabling or
disabling a variant, reading metrics and prediction logs, recording reward
feedback (for the bandit strategy), or running a formal control-vs-treatment
experiment with significance testing.

The variants under test are **AI Gateway models**, so pick real model `_id`s
first, see `references/ai-gateway.md`. The formal experiments here are specific to
an A/B router; for broader MLOps experiment tracking see `references/mlops.md`.

**Auth** follows `SKILL.md`. Outside Strongly send `-H "X-API-Key:
$STRONGLY_API_KEY"` to `$HOST/api/v1`; inside Strongly the bearer is
auto-injected against `$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever
applies, and `auth=(-H "X-API-Key: $STRONGLY_API_KEY")` outside Strongly.

**Scopes.** Reads need `mlops:read`, writes need `mlops:write`. A missing scope
returns `403 scope-required`; tell the user which scope to add, do not work
around it.

---

## 1. Pick the model variants first (AI Gateway)

Each variant references a model by its AI Gateway `_id`. List the user's real
models and choose the ones to compare, never hardcode a model name (see
`references/ai-gateway.md`).

```bash
curl -s "${auth[@]}" "$BASE/ai/models?status=active" | jq '.data[] | {_id,name,provider,modelType}'
MODEL_A=...   # e.g. the current production model (the control)
MODEL_B=...   # e.g. the challenger
```

---

## 2. Create, list, inspect, update, delete a test

Create needs `name`, `strategy`, and `variants` (at least 2). A variant is
`{ variantId, modelId, weight?, isControl? }`. **`weight` is a 0-1 fraction**
(for example `0.5`), NOT a 0-100 percentage, and the enabled variants' weights
must sum to 1 (for example `0.5 + 0.5`). Mark the baseline with
`isControl: true`.

```bash
# weighted_random: a straight 50/50 split between two models
ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ab-tests" \
  -d '{"name":"prod vs challenger","strategy":"weighted_random",
       "variants":[{"variantId":"control","modelId":"'"$MODEL_A"'","weight":0.5,"isControl":true},
                   {"variantId":"challenger","modelId":"'"$MODEL_B"'","weight":0.5}]}' \
  | jq -r '.data.abTestId')

# List (filter by status or strategy)
curl -s "${auth[@]}" "$BASE/ab-tests?status=running&strategy=weighted_random" | jq '.data'

# Inspect one (variants, weights, strategy config, deployment status)
curl -s "${auth[@]}" "$BASE/ab-tests/$ID" | jq '.data'
```

Strategy-specific config passed at create time:

- `featureRules` (array): routing rules for `feature_based`.
- `banditConfig` (object): `{ explorationRate, rewardMetric, windowSize }` for
  `multi_armed_bandit`.
- `canaryConfig` (object): `{ initialWeight, incrementStep, successThreshold,
  rollbackThreshold }` for `canary`.

`PUT /ab-tests/:id` edits only `name`, `description`, and `tags`; change traffic
weights with the variant route in section 4, not here. Delete is a soft delete.

| Method / path | Does | Scope |
|---|---|---|
| `GET /ab-tests` | List (`status`, `strategy`) | `mlops:read` |
| `POST /ab-tests` | Create (`name`, `strategy`, `variants`; optional `description`, `tags`, `featureRules`, `banditConfig`, `canaryConfig`) | `mlops:write` |
| `GET /ab-tests/:id` | Full detail: variants, weights, strategy config, deployment status | `mlops:read` |
| `PUT /ab-tests/:id` | Update `name` / `description` / `tags` only | `mlops:write` |
| `DELETE /ab-tests/:id` | Delete the test (soft delete) | `mlops:write` |

---

## 3. Deploy, start, stop the router (async)

`deploy` publishes the routing endpoint through the AI Gateway so live requests
start splitting across variants. `stop` tears the router down; `start`
re-deploys a stopped test. These are **asynchronous**: the call returns
immediately and the router settles afterward, so poll `GET /ab-tests/:id` for the
deployment `status` and let real traffic accumulate before you read anything into
the numbers (Golden Rule 3).

```bash
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/$ID/deploy"   | jq '.data'   # { deployed: true }

# Poll status until the router is live, then let traffic flow
curl -s "${auth[@]}" "$BASE/ab-tests/$ID" | jq '.data.status'

curl -s -X POST "${auth[@]}" "$BASE/ab-tests/$ID/stop"     | jq '.data'   # { stopped: true }
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/$ID/start"    | jq '.data'   # { started: true }
```

Do not draw a winner from a handful of requests. Read `/metrics` (section 5) and
confirm each variant has served enough traffic first; for a rigorous call, run a
formal experiment (section 6).

| Method / path | Does | Scope |
|---|---|---|
| `POST /ab-tests/:id/deploy` | Deploy the router to the AI Gateway | `mlops:write` |
| `POST /ab-tests/:id/stop` | Stop the running router | `mlops:write` |
| `POST /ab-tests/:id/start` | Re-deploy a stopped test | `mlops:write` |

---

## 4. Tune traffic: variant weight and toggle

For a `weighted_random` test, adjust one variant's share of traffic. The
`weight` body field is a **0-1 fraction** (for example `0.5`) and must be between
0 and 1 or the call is rejected; the other enabled variants are auto-renormalized
so all enabled weights still sum to 1. Weight edits apply to the
`weighted_random` strategy only. `variantId` is the variant's `variantId` from
the test (it must be an enabled variant).

```bash
# Shift 70% of traffic to the challenger; the rest is rescaled to fill 1 - 0.7
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/ab-tests/$ID/variants/challenger/weight" \
  -d '{"weight":0.7}' | jq '.data'
```

Toggle a variant on or off. Disabled variants receive no traffic, and **at least
2 variants must remain enabled**.

```bash
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/ab-tests/$ID/variants/challenger/toggle" \
  -d '{"enabled":false}' | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `PUT /ab-tests/:id/variants/:variantId/weight` | Set one enabled variant's weight (0-1 fraction; others auto-rescaled to sum to 1). `weighted_random` only | `mlops:write` |
| `PUT /ab-tests/:id/variants/:variantId/toggle` | Enable/disable a variant (`enabled`; at least 2 must stay enabled) | `mlops:write` |

---

## 5. Measure: metrics, predictions, feedback

`metrics` aggregates the router: total requests, success rate, average latency,
and per-variant breakdowns. `predictions` is the request-level log showing which
variant served each request, its latency, and any recorded feedback.

```bash
# Aggregate metrics (optional ISO 8601 date window)
curl -s "${auth[@]}" "$BASE/ab-tests/$ID/metrics?startDate=2026-09-01&endDate=2026-09-15" | jq '.data'

# Per-request log (paginate; filter to one variant)
curl -s "${auth[@]}" "$BASE/ab-tests/$ID/predictions?limit=50&variantId=challenger" | jq '.data'
```

Record **feedback** on a routed prediction. This is the reward signal the
`multi_armed_bandit` strategy uses to auto-optimize variant weights. Note the
path takes the **prediction id** (from the predictions log), not the test id.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/ab-tests/predictions/$PREDICTION_ID/feedback" \
  -d '{"reward":1,"label":"correct"}' | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /ab-tests/:id/metrics` | Requests, success rate, latency, per-variant (`startDate`, `endDate` ISO 8601) | `mlops:read` |
| `GET /ab-tests/:id/predictions` | Per-request log: variant served, latency, feedback (`limit`, `offset`, `variantId`) | `mlops:read` |
| `POST /ab-tests/predictions/:predictionId/feedback` | Record reward/label for a prediction (`reward` 0-1, `label`) | `mlops:write` |

---

## 6. Formal experiments (control vs treatment)

An **experiment** turns an A/B test into a statistical comparison: one control
(baseline) variant against one or more treatment variants, with significance
testing. Create it on the test, start data collection, analyze for significance,
then stop. `controlVariantId` and `treatmentVariantIds` are `variantId` values
from the test. The router id is filled from the path automatically, so you send
`name`, `controlVariantId`, and `treatmentVariantIds` plus any optional
statistical fields. `confidenceLevel` defaults to `0.95`.

```bash
# 1. Create the experiment on a (deployed) A/B test
EXP=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ab-tests/$ID/experiments" \
  -d '{"name":"challenger beats prod?","controlVariantId":"control",
       "treatmentVariantIds":["challenger"],"primaryMetric":"latency",
       "hypothesis":"challenger is faster","confidenceLevel":0.95,"minSamplePerVariant":500}' \
  | jq -r '.data.experimentId')

# 2. Start collecting
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/experiments/$EXP/start" | jq '.data'

# 3. Analyze once enough samples exist: p-values, confidence intervals,
#    whether treatment beats control (auto-concludes if sequential test hits significance)
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/experiments/$EXP/analyze" | jq '.data'

# 4. Analyze BEFORE stopping (stop freezes data collection)
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/experiments/$EXP/stop" | jq '.data'
```

Give the experiment time to reach `minSamplePerVariant` before trusting the
analysis; a low sample count means the result is not yet conclusive.

Optional create fields: `description`, `hypothesis`, `primaryMetric` (for example
`latency`, `accuracy`, `reward`), `confidenceLevel` (default `0.95`),
`minimumDetectableEffect`, `minSamplePerVariant`.

| Method / path | Does | Scope |
|---|---|---|
| `POST /ab-tests/:id/experiments` | Create experiment (`name`, `controlVariantId`, `treatmentVariantIds`; optional statistical fields) | `mlops:write` |
| `POST /ab-tests/experiments/:experimentId/start` | Begin data collection | `mlops:write` |
| `POST /ab-tests/experiments/:experimentId/analyze` | Statistical analysis (p-values, CIs, winner) | `mlops:read` |
| `POST /ab-tests/experiments/:experimentId/stop` | Freeze data collection | `mlops:write` |
| `DELETE /ab-tests/experiments/:experimentId` | Delete the experiment and its data | `mlops:write` |

---

## Checklist
- [ ] Variants reference real AI Gateway model `_id`s (`GET /ai/models`); never hardcode a model name.
- [ ] Create needs `name`, `strategy`, and at least 2 variants; enabled `weight`s are 0-1 fractions that sum to 1; mark the baseline `isControl:true`.
- [ ] `deploy`/`start`/`stop` are async: poll `GET /ab-tests/:id` for `status` and let real traffic accumulate before reading the numbers.
- [ ] Change traffic with the variant weight route (0-1 fraction, others auto-rescaled), not `PUT /ab-tests/:id`; keep at least 2 variants enabled.
- [ ] Compare variants from `/metrics` and `/predictions` with enough samples; do not conclude from a handful of requests.
- [ ] For `multi_armed_bandit`, feed reward via `POST /ab-tests/predictions/:predictionId/feedback` (note: prediction id, not test id).
- [ ] For a rigorous call, run an experiment: create, start, `analyze` (before `stop`), and wait for `minSamplePerVariant`.
- [ ] Report real status and `error.message` on failure; do not fabricate a winner.
