# Drift

**Drift** tells you whether a registry model's live inputs (and, with actuals,
its performance) still look like what it was trained on. It compares a model
version's **production predictions** with that version's **baseline**: a
summary of its reference rows (the data it was trained or validated on). Each
version has its own baseline, and drift reads only that version's predictions.

Drift is for **model registry** models (traditional ML: classification,
regression, and other published models). It does not apply to AI Gateway
models (LLMs, third-party vendors).

Every drift call needs the model's task, `training.problemType`: one of
`classification`, `multiclass`, `regression`, `multilabel`, `timeseries`,
`other`. A model without one is refused (`invalid-model`, saying where to set
it) and the drift overview lists it as `no-task`. The task decides how its
predictions are scored against actuals: accuracy (`accuracy`) for
classification and multiclass, mean absolute error (`mae`, lower is better)
for regression, and the reviewers' mean verdict (`review_score`; an actual is
`true`/`false` or a 0 to 1 score on the prediction) for multilabel, timeseries
and other. Set it
with `PUT /model-registry/models/:id` `{"problemType":"classification"}` (only
the task changes; the rest of the training record stays), or in the UI under
**Task** in the model's Monitoring settings.

Read this when the task is: building or activating a baseline, running a drift
analysis, finding out why an analysis produced no result, reading a result and
its per-feature detail, or setting up the drift schedule and thresholds.
Prediction records, actuals and the Record inputs setting that feed drift are
in `references/model-evaluation.md`.

**Auth** follows `SKILL.md`; below, `$BASE` is `$STRONGLY_API_URL/api/v1`
inside Strongly or `$HOST/api/v1` outside, with `auth=(-H "X-API-Key:
$STRONGLY_API_KEY")` outside. **Scopes:** baseline builds live under the model
(`model-registry:read` / `model-registry:write`); the `/drift` routes need
`mlops:read` / `mlops:write`.

---

## 1. Baselines: one per model version

A baseline is built by a **job** from a CSV of any size with a column for every
input feature the model declares, optionally `actual`, `prediction` and
`confidence` (the probability of the predicted class). With `actual` and
`prediction` (for a reviewed model, `actual` verdicts alone) it records the
version's performance by its task (`baselinePerformance { metric,
higherIsBetter, value }`, with `evaluationKind`); with `confidence` as well, its
calibration, which estimates accuracy on live traffic before actuals arrive
(CBPE; not for a regressor).

The file comes from an upload (a presigned link, so any size) or from a shared
volume the caller can read.

```bash
# a) Upload: get a link, PUT the file, then build from the uploadId
LINK=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"filename":"reference.csv"}' "$BASE/model-registry/models/$MODEL_ID/baselines/upload-url")
curl -s -X PUT -H "Content-Type: $(echo "$LINK" | jq -r .data.contentType)" \
  --data-binary @reference.csv "$(echo "$LINK" | jq -r .data.uploadUrl)"
SOURCE='{"type":"upload","uploadId":"'"$(echo "$LINK" | jq -r .data.uploadId)"'","filename":"reference.csv"}'

# b) Or a file on a shared volume
SOURCE='{"type":"volume","volumeId":"<volumeId>","path":"train.csv"}'

# Build (version defaults to the active version; analyzeDaily defaults to false)
JOB=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"source":'"$SOURCE"',"version":2,"analyzeDaily":true}' \
  "$BASE/model-registry/models/$MODEL_ID/baselines" | jq -r '.data._id')
```

What happens when the job completes:

- The baseline becomes its version's **active** baseline; the one it replaces is
  kept, inactive (make it active again with the activate route below).
- The version's **first drift analysis starts** when it has production
  predictions from the last 7 days. Without them the job says why in
  `driftWaiting`, and the first analysis is the next Run Analysis or scheduled run.
- With **`analyzeDaily: true`**, the model's drift schedule is turned on (daily)
  once the baseline is kept. When the first analysis started, it counts as that
  day's run and the next is a day later; otherwise the scheduler runs it at its
  next check.

Poll the job (a page of the model's baseline jobs, newest first):

```bash
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/baselines/jobs?limit=5" \
  | jq '.data[] | {_id, status, modelVersion, sampleSize, baselineId, driftJobId,
                   driftWaiting, driftError, driftScheduleError, errorMessage}'
```

`status` is `pending`, `running`, `completed` or `failed` (`errorMessage` says
why). On a completed job, `driftError` means the first analysis could not start,
and `driftScheduleError` means the daily schedule could not be turned on. The
baseline stands either way.

The build is refused (`400`, with the reason) for a model that declares no
input features or a version the model does not have. Problems in the file (no
column for an input feature, a value that is not a number, an empty file) fail
the job, and `errorMessage` names the line or column.

AutoML publishing builds the new version's baseline automatically from the
trainer's reference rows.

| Method / path | Does | Scope |
|---|---|---|
| `POST /model-registry/models/:id/baselines/upload-url` | Presigned link for the reference CSV (`filename`) -> `{ uploadId, uploadUrl, contentType }` | `model-registry:write` |
| `POST /model-registry/models/:id/baselines` | Build a baseline (`source`, `version?`, `analyzeDaily?`) -> the job | `model-registry:write` |
| `GET /model-registry/models/:id/baselines/jobs` | The model's baseline jobs, a page at a time | `model-registry:read` |
| `PUT /model-registry/models/:id/baselines/:baselineId/activate` | Make an earlier baseline its version's active one again | `model-registry:write` |
| `GET /drift/baselines?modelId=` | The model's baselines, a page at a time (version, rows, evaluationKind and baselinePerformance, file, active) | `mlops:read` |
| `GET /drift/baselines/active?modelId=` | The active version's active baseline | `mlops:read` |

---

## 2. Run an analysis, and know why one produced nothing

An analysis compares the **active version**'s production predictions in a window
(default the last 7 days; Test tab predictions are never counted) with that
version's active baseline. It runs as a job: the call returns at once.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"modelId":"'"$MODEL_ID"'","windowDays":7}' "$BASE/drift/analyze" | jq '.data'
# { jobId, status }
```

A version without a baseline is refused (`400`, "has no baseline. Build one ...").

**Progress lives on the model.** `latestAnalysis` on `GET
/model-registry/models/:id` (and on each row of `GET /drift/models`) is the
latest run, whoever started it:

```bash
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID" | jq '.data.latestAnalysis'
# { jobId, status: pending|deploying|running|completed|failed,
#   triggeredBy: manual|scheduler|baseline, statusMessage, error, startedAt, finishedAt }
```

`GET /drift/analyze/:jobId/status?modelId=` returns one run by its `jobId`.
Poll until `completed` or `failed`. A **failed** run produced no result, and
`error` says why. Relay it to the user instead of reporting "no drift". The
common reasons:

| `error` says | What to do |
|---|---|
| `Version N has no production predictions from ... to compare with its baseline (Test tab predictions are not counted)` | Wait for production traffic, or widen the window (`windowDays`). |
| `No prediction in the window recorded its inputs ...` | Turn on Record inputs (`references/model-evaluation.md`); only later predictions carry inputs. |
| `Version N has K production predictions with recorded inputs from ... UTC; drift compares at least M with its baseline` | Too few predictions to say anything about a distribution. Wait for more, widen the window, or lower `minWindowSampleSize` (section 4). |
| `Baseline ... sampleSize=... is below minimum ...` | Rebuild the baseline from more reference rows, or lower `minBaselineSampleSize`. |

---

## 3. Read the result

```bash
curl -s "${auth[@]}" "$BASE/drift/results/latest?modelId=$MODEL_ID" | jq '.data'
```

The result (kept 15 days; its summary stays on the model as `latestDrift`):

- **`overallStatus`**: `ok`, `warning` or `alert`, from the drift score against
  the model's PSI thresholds. Without a drift score it is the worst status any
  algorithm gave. It is `error` when nothing could be scored (see
  `algorithmsSkipped`).
- **`driftScore`**: the **mean PSI** across features, a plain number (0.25, not
  25%). `null` when PSI scored no feature.
- **`notification`** (only on a result that found drift): how it was announced.
  `state` is `pending`, `sending`, `sent` or `failed`; `inApp`, `email` and
  `slack` each have `sent` (to whom) or `error` (why not, for example
  "the platform has no mail server configured"). Report a channel's `error` to
  the user rather than assuming it was delivered.
- **`featuresAnalyzed`** / **`featuresWithDrift`**: features some algorithm
  scored, and how many of them drifted.
- **`sampleSize`**, **`windowStart`** / **`windowEnd`**, **`calculatedAt`**.
- **`predictionDrift`**: the model's performance by its task on the window's
  predictions that have actuals (`labelledCount`) against the baseline's:
  `metric` (`accuracy`, `mae` or `review_score`), `higherIsBetter`, `current`,
  `baseline`, `change`, `drop` (how much worse, relative) and `status` (`ok`,
  `warning`, `alert` from the drop thresholds; it raises `overallStatus`). When
  it cannot be measured (no actuals, no baseline performance, a task changed
  since the baseline: rebuild it), `error` says why and there are no figures,
  except that without baseline performance `current` is still measured.
- **`algorithmsRun`**, and **`algorithmsSkipped`** (`{ name, reason }`).

**The rows** (a feature each, plus rows about the whole dataset) are read a
page at a time from the result, most drifted first by default:

```bash
RID=$(curl -s "${auth[@]}" "$BASE/drift/results/latest?modelId=$MODEL_ID" | jq -r '.data._id')
curl -s "${auth[@]}" "$BASE/drift/results/$RID/features?modelId=$MODEL_ID&rows=features&limit=25" | jq '.data'
```

Query: `rows` (`features`, or `dataset` for the dataset-level rows; omit for
both), `search` (feature name), `sort` (`severity`, `score`, `featureName`,
`order`), `limit`, `offset`. Each row:

- **`featureName`**: a feature, or `[multivariate] <algorithm>` /
  `[performance] cbpe` for a row about the whole dataset. **`category`** is
  `feature`, or that algorithm's category.
- **`metrics`**: one per algorithm that ran on it, keyed by algorithm name:
  `{ value, threshold, status, category, details }`. A metric that could not run
  has `value: null` and `status: "error"` with the reason in `details.error`
  (never a 0 that reads as "no drift").
- **`status`** (its worst scored metric's), **`severity`** (`alert` 3,
  `warning` 2, `ok` 1, `error` 0), **`score`** (PSI when it ran, else the first
  scored metric), **`hasDrift`**.
- **`error`**: set only when no algorithm could score the row, saying why.

| Method / path | Does | Scope |
|---|---|---|
| `POST /drift/analyze` | Start an analysis (`modelId`, `windowDays?` or `windowStart` + `windowEnd`) -> `{ jobId, status }` | `mlops:write` |
| `GET /drift/analyze/:jobId/status?modelId=` | One run's status and error | `mlops:read` |
| `GET /drift/results/latest?modelId=` | The latest result | `mlops:read` |
| `GET /drift/results/:resultId/features?modelId=` | A result's rows, a page at a time (`rows`, `search`, `sort`, `limit`, `offset`) | `mlops:read` |
| `GET /drift/results?modelId=` | Result history, a page at a time (`status`, `sort`) | `mlops:read` |
| `GET /drift/models` | Every model you can see with `latestDrift` and `latestAnalysis` (`status`: `ok`, `warning`, `alert`, `error`, or `no-data` for never analyzed) | `mlops:read` |

---

## 4. Settings, thresholds and the schedule

One settings document per model, read and written in one place:

```bash
curl -s "${auth[@]}" "$BASE/drift/alerts?modelId=$MODEL_ID" | jq '.data'

# Analyze daily over the last 7 days; score windows with at least 50 predictions
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "modelId":"'"$MODEL_ID"'", "enabled": true, "minWindowSampleSize": 50,
  "schedule": {"enabled": true, "frequency": "daily", "timeWindowDays": 7}
}' "$BASE/drift/alerts"
```

Only the fields you send change. The fields:

- **`schedule`**: `{ enabled, frequency: hourly|daily|weekly, timeWindowDays }`.
  The scheduler runs a model only when both **`enabled`** and
  **`schedule.enabled`** are true. A schedule that has never run runs at the
  scheduler's next check, then every interval. `schedule.lastRunAt` and
  `schedule.nextRunAt` show where it is.
- **`minWindowSampleSize`** (default 30): fewest predictions with recorded
  inputs a window needs. A window with fewer fails, saying how many it had.
- **`minBaselineSampleSize`** (default 30): fewest reference rows a baseline
  needs.
- **`algorithms`**: `{ enabled: [...], overrides: { <algo>: { warningThreshold,
  alertThreshold, params } } }`. The built-ins are `psi`, `ks`, `chi_square`,
  `jensen_shannon`, `wasserstein`, `domain_classifier`, `pca_reconstruction`,
  `adwin` and `cbpe`. An empty `enabled` runs every one that applies. The
  overall status uses the `psi` thresholds (default warning 0.1, alert 0.2).
- **`performanceDropWarning`** / **`performanceDropAlert`** (defaults 0.05 /
  0.10): how much worse than the baseline, relatively, the model's performance
  may get before prediction drift is a warning or alert (lower accuracy or
  review score, higher mean absolute error); the warning must be smaller.
- **`notifications`**: `{ email: boolean, recipients: [addresses], slack?: Slack
  incoming webhook URL }`. When an analysis finds drift (`warning` or `alert`),
  the model's owner is always notified in Strongly; with `email`, the
  recipients are emailed (the owner when there are none); with `slack`, that
  webhook gets a message. An address that is not one, or a webhook pointing at
  localhost, an internal host or a private address, is refused with `400`. A
  failed analysis never notifies.

Building a baseline with `analyzeDaily: true` (section 1) turns the daily
schedule on for you.

| Method / path | Does | Scope |
|---|---|---|
| `GET /drift/alerts?modelId=` | The model's drift settings | `mlops:read` |
| `PUT /drift/alerts` | Change them (`modelId` plus the fields to change) | `mlops:write` |

---

## Checklist
- [ ] Drift is for model registry models only; AI Gateway models have none.
- [ ] Build a baseline per version (`POST .../baselines`) before analyzing; poll the baseline job and read `driftWaiting` / `driftError` / `driftScheduleError`.
- [ ] Analyses are jobs: poll `latestAnalysis` (or `/drift/analyze/:jobId/status`) to `completed` or `failed`; a failed run's `error` is the answer, never "no drift".
- [ ] Only production predictions with recorded inputs count, and a window needs at least `minWindowSampleSize` of them.
- [ ] `driftScore` is the mean PSI (a number, not a percentage), `null` without PSI; read `overallStatus` for the verdict.
- [ ] Read feature detail from `/drift/results/:resultId/features` a page at a time; rows with `error` or metrics with `status: "error"` were not scored.
- [ ] To alert someone on drift, set `notifications` (email recipients, Slack webhook); check a result's `notification` for what was actually sent.
- [ ] The scheduler needs `enabled` and `schedule.enabled`; `analyzeDaily` on a baseline build turns the daily schedule on.
