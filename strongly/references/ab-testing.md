# A/B Testing

A Strongly **A/B test** splits live predictions across two or more
**variants**, each serving a **model registry** model (for example two versions
of a churn model registered as two models, or a challenger against the
current model). You compare them on real traffic instead of offline scores. A
test has one **strategy**:

- `weighted_random`: each variant gets its weight's share of traffic;
- `feature_based`: the first matching rule (by priority) picks the variant, else the control;
- `multi_armed_bandit`: routes by the rewards you record (epsilon-greedy,
  Thompson sampling, UCB1, or LinUCB, which routes by the prediction's context
  features);
- `canary`: the target variant gets a growing share of traffic in stages; once
  deployed, the platform advances it while it stays as healthy as the control,
  or rolls it back to 0% with the reason.

Every prediction a test routes is recorded with the variant that served it
(`references/model-evaluation.md`). On top sit counters, traffic over time, and
**experiments** that decide a winner with a statistical test.

A/B tests are for registry models (traditional ML). They do not route AI
Gateway models (LLMs, third-party vendors).

Read this when the task is: creating, deploying, stopping or deleting an A/B
test; predicting through it; tuning weights or turning a variant off; reading
its counters, traffic and routed predictions; recording rewards or outcomes; or
running an experiment to pick a winner.

**Auth** follows `SKILL.md`; `$BASE` and `auth` as there. **Scopes:** reads
need `mlops:read`, writes need `mlops:write`. A missing scope returns
`403 scope-required`; tell the user which scope to add.

---

## 1. Pick the models, then create the test

Each variant's `modelId` is a registry model `_id`. List the user's real models
and deploy the ones to compare (a test can only deploy when its variants'
models are deployed, see `references/model-registry.md`):

```bash
curl -s "${auth[@]}" "$BASE/model-registry/models?search=churn" | jq '.data[] | {_id,name,activeVersion,deployment}'
MODEL_A=...   # the current model (the control)
MODEL_B=...   # the challenger
```

Create needs `name`, `strategy` and at least 2 `variants` of `{ variantId,
modelId, weight?, isControl? }`. `variantId`s must be unique; at most one
variant is the control (the first, unless one is marked). **`weight` is a 0-1
fraction** (default an equal share). For `weighted_random` the weights must sum
to 1 (`0.5 + 0.5`, not `50 + 50`). Each `modelId` must be a registry model
the caller can use (own, shared or public); any other id is refused with `403`
naming it. Pick deployed models: only they can serve the test.

```bash
ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ab-tests" \
  -d '{"name":"churn: current vs challenger","strategy":"weighted_random",
       "variants":[{"variantId":"control","modelId":"'"$MODEL_A"'","weight":0.5,"isControl":true},
                   {"variantId":"challenger","modelId":"'"$MODEL_B"'","weight":0.5}]}' \
  | jq -r '.data.abTestId')
```

Optional at create:

- `stickyRouting: true`: an entity keeps its variant for the test's life, keyed
  on the `entityId` sent with each prediction. Every predict must then send
  `entityId` (`400` without it). With a canary, an entity moves to the target
  only as the share grows past it, and back on a rollback.
- `featureRules` (**required** for `feature_based`, at least one):
  `[{ featureName, operator (equals, not_equals, in, not_in, greater_than,
  less_than, contains, regex), value, targetVariantId, priority? }]`, lower
  priority first (default the order given). `value` is a list for
  `in`/`not_in`, a number for `greater_than`/`less_than`, a valid pattern for
  `regex`. A rule serving could not apply is refused with `400` naming it.
- `banditConfig` (for `multi_armed_bandit`): `{ algorithm (epsilon_greedy
  default, thompson_sampling, ucb1, linucb), epsilon (default 0.1),
  explorationBonus (default 2.0; alpha for linucb), contextFeatures,
  rewardMetric (success_rate default, latency, custom) }`. For `linucb`,
  `contextFeatures` are numeric input features that **every** variant model
  declares as numbers (check `schema.input.fields` on each model), and every
  variant model needs Record inputs on (`PUT /model-registry/models/:id/monitoring`
  with `recordInputs: true`), because LinUCB learns from each prediction's
  recorded inputs. Create refuses otherwise, saying why.
- `canaryConfig` (for `canary`): `{ controlVariantId, targetVariantId (default
  the second variant), stages (default 1, 5, 10, 25, 50, 100),
  currentPercentage (default the first stage), targetPercentage (default 100),
  bakeMinutes (default 30), errorRateDelta (default 0.01), latencyP95DeltaMs
  (default 500), minRequestsForDecision (default 20) }`. Once deployed, a stage
  advances after `bakeMinutes` and `minRequestsForDecision` canary predictions
  in it, while the canary's error rate and p95 latency in that stage stay
  within the deltas of the control's; otherwise it rolls back to 0% and stays
  there. `GET /ab-tests/:id` shows `canaryConfig.currentPercentage`,
  `rollbackReason` and `lastCheck` (`{ at, action: advance | rollback | wait |
  complete, reason }`): read `lastCheck.reason` to tell the user why a canary
  is waiting or rolled back.
- `description`, `tags`, `workspaceId`.

A new test's status is `registered`. `PUT /ab-tests/:id` changes only `name`,
`description` and `tags`; change traffic with section 3. `DELETE` stops a
running test first; its recorded predictions are kept for their retention.

---

## 2. Deploy, predict, stop

```bash
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/$ID/deploy" | jq '.data'   # { deployed: true }
```

Deploy returns once the test is routing: its status is `running`. If it could
not deploy, the call fails (`deployment-failed`, with the reason) and the test's
status is `failed`. Check `GET /ab-tests/:id` (`deployment.status`:
`registered`, `deploying`, `running`, `stopped`, `failed`).

Predict through the running test; it picks the variant by its strategy:

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"input_data":{"tenure":12,"plan":"pro"},"entityId":"cust-4821"}' \
  "$BASE/ab-tests/$ID/predict" | jq '.data'
# the serving model's output, plus prediction_id and variant_id
```

A test that is not running refuses predictions (`not-running`, with its
status). `stop` stops routing (status `stopped`; predictions, counters and
experiments are kept); `start` re-deploys a stopped test.

| Method / path | Does |
|---|---|
| `POST /ab-tests/:id/deploy` | Start routing (the variants' models must be deployed) |
| `POST /ab-tests/:id/predict` | Predict through the test (`input_data`, `entityId?`) -> output + `prediction_id`, `variant_id` |
| `POST /ab-tests/:id/stop` | Stop routing |
| `POST /ab-tests/:id/start` | Re-deploy a stopped test |

---

## 3. Tune traffic

For `weighted_random`, set one enabled variant's weight (a 0-1 fraction); the
other enabled variants are rescaled so the enabled weights still sum to 1:

```bash
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"weight":0.7}' "$BASE/ab-tests/$ID/variants/challenger/weight"
```

Turn a variant off or on. A disabled variant gets no traffic, and at least 2
must stay enabled:

```bash
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"enabled":false}' "$BASE/ab-tests/$ID/variants/challenger/toggle"
```

---

## 4. Measure: counters, traffic, routed predictions, feedback

```bash
# Totals since the test was created, overall and per variant (variantMetrics)
curl -s "${auth[@]}" "$BASE/ab-tests/$ID/metrics" | jq '.data'
# Requests, errors and latency over time, per variant
curl -s "${auth[@]}" "$BASE/ab-tests/$ID/traffic" | jq '.data'
# The routed predictions, a page at a time
curl -s "${auth[@]}" "$BASE/ab-tests/$ID/predictions?variantId=challenger&limit=50" | jq '.data'
```

- `metrics`: `totalRequests`, `successCount`, `errorCount`, `successRate` and
  `avgLatencyMs` (serving latency of successful predictions), overall and per
  variant. Rates are `null` before any request.
- `traffic`: `bucketMs`, `buckets` (ISO start of each), and per variant the
  requests, errors and `avgLatencyMs` per bucket (`null` for a bucket without a
  successful prediction).
- `predictions`: which variant served each and why, latency, success, and its
  actual and reward when recorded. Query: `variantId`, `search`, `sort`
  (`-timestamp` default, `latencyMs`, `variantId`, `success`, `confidence`),
  `limit`, `offset`.

**Feedback** on a routed prediction (the path takes the **prediction id** from
`predict`, not the test id). Send `reward`, `label` or both:

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"reward":1,"label":"churn"}' "$BASE/ab-tests/predictions/$PREDICTION_ID/feedback"
```

- `reward` (0 to 1) is kept on the prediction; sending it again replaces it
  (a bandit counts only the difference). A `multi_armed_bandit` test learns
  from it (`linucb` over the prediction's recorded inputs: refused when the
  model does not record them), and an experiment on the `custom` metric
  measures it.
- `label` is the prediction's actual (its true outcome), recorded with the
  model's actuals.

Do not call a winner from a handful of requests. Run an experiment (section 5).

---

## 5. Experiments: pick a winner with a statistical test

An experiment compares each treatment variant with the control on **one primary
metric**, over the predictions the test routes while the experiment runs.

```bash
EXP=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ab-tests/$ID/experiments" \
  -d '{"name":"challenger beats current?","controlVariantId":"control",
       "treatmentVariantIds":["challenger"],"primaryMetric":"success_rate",
       "confidenceLevel":0.95,"minSamplePerVariant":500}' | jq -r '.data.experimentId')

curl -s -X POST "${auth[@]}" "$BASE/ab-tests/experiments/$EXP/start"     # status running
curl -s -X POST "${auth[@]}" "$BASE/ab-tests/experiments/$EXP/analyze" | jq '.data'
```

- **`primaryMetric`** (required): `success_rate` (higher is better), `latency`
  (lower is better) or `custom` (the reward from feedback, higher is better).
- Optional: `description`, `hypothesis`, `confidenceLevel` (default 0.95),
  `minimumDetectableEffect` (default 0.05), `minSamplePerVariant` (default 100),
  `maxSamplePerVariant`, `maxDurationDays` (default and maximum: the prediction
  retention).
- **`analyze`** returns `controlStats` and `treatmentStats` (mean, sample size,
  p-value, confidence interval, relative improvement, significance), a
  `recommendation` (`treatment`, `control` or `inconclusive`) and
  `winnerVariantId`, and keeps them on the experiment. It concludes a running
  experiment (status `completed`) when a sequential test is significant,
  `maxSamplePerVariant` is reached or `maxDurationDays` has passed
  (`concludedReason`).
- **`conclude`** ends a running experiment as a finished run (status
  `completed`, reason `manual`). **`stop`** cancels a draft or running one
  (status `cancelled`). Either way its analysis covers the predictions until
  then.

Report `inconclusive` as inconclusive, and say when a variant has fewer samples
than `minSamplePerVariant`.

| Method / path | Does | Scope |
|---|---|---|
| `POST /ab-tests/:id/experiments` | Create (status `draft`) | `mlops:write` |
| `GET /ab-tests/:id/experiments` | The test's experiments, a page at a time, with their latest results | `mlops:read` |
| `POST /ab-tests/experiments/:experimentId/start` | Start (status `running`) | `mlops:write` |
| `POST /ab-tests/experiments/:experimentId/analyze` | Analyze, and conclude when its limits are met | `mlops:read` |
| `POST /ab-tests/experiments/:experimentId/conclude` | End a running experiment as finished | `mlops:write` |
| `POST /ab-tests/experiments/:experimentId/stop` | Cancel it | `mlops:write` |
| `DELETE /ab-tests/experiments/:experimentId` | Delete it and its results (the test's predictions are kept) | `mlops:write` |

---

## Endpoint reference

| Method / path | Does | Scope |
|---|---|---|
| `GET /ab-tests` | List, a page at a time (`status`, `strategy`, `modelId`, `workspaceId`, `search`, `sort`) | `mlops:read` |
| `POST /ab-tests` | Create | `mlops:write` |
| `GET /ab-tests/:id` | Variants and their counters, strategy config, deployment | `mlops:read` |
| `PUT /ab-tests/:id` | Update `name`, `description`, `tags` | `mlops:write` |
| `DELETE /ab-tests/:id` | Delete (stopped first when running) | `mlops:write` |
| `POST /ab-tests/:id/deploy` / `stop` / `start` | Start, stop, restart routing | `mlops:write` |
| `POST /ab-tests/:id/predict` | Predict through the test | `mlops:write` |
| `PUT /ab-tests/:id/variants/:variantId/weight` | Set a variant's weight (`weighted_random`) | `mlops:write` |
| `PUT /ab-tests/:id/variants/:variantId/toggle` | Enable or disable a variant | `mlops:write` |
| `GET /ab-tests/:id/metrics` | Totals, overall and per variant | `mlops:read` |
| `GET /ab-tests/:id/traffic` | Requests, errors, latency over time | `mlops:read` |
| `GET /ab-tests/:id/predictions` | Routed predictions, a page at a time | `mlops:read` |
| `POST /ab-tests/predictions/:predictionId/feedback` | Record `reward` and/or `label` | `mlops:write` |

---

## Checklist
- [ ] Variants serve registry models (`GET /model-registry/models`), deployed before the test deploys; never AI Gateway models.
- [ ] Weights are 0-1 fractions; `weighted_random` weights sum to 1; keep at least 2 variants enabled.
- [ ] `deploy` returns with the test `running` or fails with the reason; predict only through a running test.
- [ ] Keep `prediction_id` from `predict` to record `reward` / `label`.
- [ ] A `stickyRouting` test: send `entityId` with every predict. A `linucb` test: send each context feature in `input_data` as a number.
- [ ] `feature_based` needs at least one rule; `linucb` needs numeric `contextFeatures` shared by every variant model, with Record inputs on.
- [ ] For a canary, read `canaryConfig.lastCheck` / `rollbackReason` to explain its progress; do not move `currentPercentage` by hand.
- [ ] Decide winners with an experiment (`primaryMetric` required), not from raw counters; report `inconclusive` honestly.
