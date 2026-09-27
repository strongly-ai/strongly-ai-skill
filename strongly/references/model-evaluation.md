# Model evaluation: predictions, actuals and the model card

A **model registry** model is evaluated from what it actually does in
production. Every prediction it serves is **recorded**; the true outcomes
(**actuals**) are recorded as they become known and joined to those
predictions; **drift** compares the live inputs with the version's baseline
(`references/drift.md`); **A/B tests** compare models on live traffic
(`references/ab-testing.md`). The results are shown on the **model card**: the
model's page in the model registry.

This is traditional ML (registry models). AI Gateway models (LLMs,
third-party vendors) are not recorded or evaluated this way.

Read this when the task is: reading a model's prediction records, deciding
whether its inputs may be stored (Record inputs), recording actuals one by one
or importing a file of them, logging predictions made outside Strongly, or
reading what the model card shows.

**Auth** follows `SKILL.md`; `$BASE` and `auth` as there. **Scopes:** routes
under `/model-registry` need `model-registry:read` / `model-registry:write`;
`/drift/predictions` needs `mlops:read` / `mlops:write`.

---

## 1. How a model is judged

A model's **task** decides what its predictions and actuals mean. It is its
output schema's `type` (a model published with a manifest), else
`training.problemType` (AutoML and framework models; set it at register time):

- **classification**: the prediction is a label; an actual is the true label.
  Classifiers that return `probabilities` also get a `confidence` (the top
  probability), which lets drift estimate accuracy before actuals arrive.
- **regression**: the prediction is a number; an actual is the true number.
- **anything else** (token classification, multilabel, time series): an actual
  is a reviewer's verdict on the prediction, `true` / `false` (correct or not)
  or a quality score from 0 to 1.

A model whose output is custom (not `{prediction, probabilities}`) names its
prediction and score fields in `schema.output.prediction` and
`schema.output.score`. Until it does, its predictions are recorded and served
but have no prediction value to score against actuals.

---

## 2. Prediction records

Every prediction a registry model serves is recorded, whether it came through
the REST predict route, an A/B test, a workflow, an app or the model page's Test
tab. The record holds its model version, prediction, confidence or score,
latency, success or error, `predictionId`, your `entityId`, where it came from
(`source`: `production`, `test` for the Test tab or `source: "test"` calls,
`shadow`), and the A/B test and variant that served it. Records are kept 90
days.

`predict` returns the `predictionId`. Keep it, or send your own `entityId`, to
attach the actual later:

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"input_data":{"tenure":12,"plan":"pro"},"entityId":"cust-4821"}' \
  "$BASE/model-registry/models/$MODEL_ID/predict" | jq '.data | {prediction, predictionId, entityId}'
```

Send `"source": "test"` on a trial call to keep it out of production results
(drift and performance count production only).

**Read them**, a page at a time, each with its actual when one is recorded:

```bash
curl -s "${auth[@]}" "$BASE/drift/predictions?modelId=$MODEL_ID&source=production&limit=50" | jq '.data'
```

Query: `source`, `startDate` / `endDate` (ISO 8601), `search` (prediction id,
entity id, error, or the prediction exactly), `sort` (`-timestamp` default,
`latencyMs`, `modelVersion`, `success`, `confidence`), `limit` (max 200),
`offset`.

**Predictions made outside Strongly** (a copy of the model served elsewhere) can
be logged so drift and performance include them. Classifiers must send
`probabilities`:

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "modelId":"'"$MODEL_ID"'","modelVersion":2,"entityId":"cust-42","prediction":"churn",
  "probabilities":[0.18,0.82],"features":{"tenure":8,"plan":"pro"}}' "$BASE/drift/predictions"
```

---

## 3. Record inputs, and the label window

Two monitoring settings per model, applied from its next prediction:

- **`recordInputs`** (default on) keeps each prediction's inputs and whole
  output in its record. Turn it **off** for a model whose inputs are sensitive
  (personal data, document text): predictions are still recorded (version,
  prediction, score, latency), but input drift cannot be measured for them.
- **`labelWindowDays`** (default 14, 1 to 90): how long an actual keyed by
  `entityId` may take to arrive and still label that entity's predictions.

```bash
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"recordInputs":false}' "$BASE/model-registry/models/$MODEL_ID/monitoring"
```

Before switching Record inputs on for a model, ask the user whether its inputs
may be stored.

---

## 4. Actuals

An actual is keyed by the `predictionId` a predict call returned, or by your
`entityId`. An `entityId` actual labels that entity's predictions made within
`labelWindowDays` before `actualAt` (else its upload time). Either may arrive
first. A second actual for the same key replaces the first.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{"actuals":[
  {"predictionId":"<predictionId>","actual":"churn"},
  {"entityId":"cust-42","actual":"stayed","actualAt":"2026-09-20T00:00:00Z"}
]}' "$BASE/model-registry/models/$MODEL_ID/actuals" | jq '.data'
# { recorded, replaced, rejected: [{ row, reason }], batchId }
```

Rows that cannot be recorded come back in `rejected` with the reason, for
example a `predictionId` the platform never issued, or a regressor's actual that
is not a number. Report them; do not drop them silently.

**A file of any size** (CSV: `predictionId` or `entityId`, `actual`, optionally
`actualAt`) is imported by a job, from an upload or a shared volume:

```bash
LINK=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"filename":"actuals.csv"}' "$BASE/model-registry/models/$MODEL_ID/actuals/upload-url")
curl -s -X PUT -H "Content-Type: $(echo "$LINK" | jq -r .data.contentType)" \
  --data-binary @actuals.csv "$(echo "$LINK" | jq -r .data.uploadUrl)"
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"source":{"type":"upload","uploadId":"'"$(echo "$LINK" | jq -r .data.uploadId)"'","filename":"actuals.csv"}}' \
  "$BASE/model-registry/models/$MODEL_ID/actuals/imports"
# or: -d '{"source":{"type":"volume","volumeId":"<volumeId>","path":"actuals.csv"}}'
```

Poll the imports (`status` `pending`, `running`, `completed` or `failed`, with
rows read, recorded, replaced and refused), then read the refused rows with
their line and reason:

```bash
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/actuals/imports?limit=5" | jq '.data'
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/actuals/imports/$IMPORT_ID/rejections" | jq '.data'
```

Actuals are what drift's prediction drift measures accuracy on, and what an A/B
test's predictions show as their outcome.

| Method / path | Does | Scope |
|---|---|---|
| `POST /model-registry/models/:id/actuals` | Record actuals (`actuals: [{ predictionId or entityId, actual, actualAt? }]`) | `model-registry:write` |
| `POST /model-registry/models/:id/actuals/upload-url` | Presigned link for a CSV of actuals (`filename`) | `model-registry:write` |
| `POST /model-registry/models/:id/actuals/imports` | Import a CSV (`source`: upload or volume) | `model-registry:write` |
| `GET /model-registry/models/:id/actuals/imports` | Imports, a page at a time | `model-registry:read` |
| `GET /model-registry/models/:id/actuals/imports/:importId/rejections` | Refused rows with line and reason | `model-registry:read` |
| `PUT /model-registry/models/:id/monitoring` | `recordInputs`, `labelWindowDays` | `model-registry:write` |
| `GET /drift/predictions?modelId=` | Prediction records with their actuals, a page at a time | `mlops:read` |
| `POST /drift/predictions` | Log a prediction made outside Strongly | `mlops:write` |

---

## 5. The model card

The model card is the model's page in the model registry: its Overview,
Metrics, Versions, Monitoring (predictions, actuals, baselines and drift) and
Features. Through the API, `GET /model-registry/models/:id` returns the same
card:

- name, framework, algorithm, `training.problemType`, `schema` and `features`,
  offline `metrics`, `dataset`, `versions` and `activeVersion`, `deployment`;
- `monitoring` (`recordInputs`, `labelWindowDays`);
- `latestDrift` (the latest drift result: `overallStatus`, `driftScore`,
  `sampleSize`, `calculatedAt`) and `latestAnalysis` (the latest drift run and
  why it failed, when it did).

Change the card's descriptive fields with `PUT /model-registry/models/:id`
(`name`, `description`, `algorithm`, `tags`, `schema`, `features`, `dataset`,
`metrics`, `training`); monitoring settings are section 3.

---

## Checklist
- [ ] Registry models only; AI Gateway models are not recorded or evaluated here.
- [ ] Keep each `predictionId` (or send an `entityId`) so actuals can be attached; use `source: "test"` for trial calls.
- [ ] Ask before storing inputs for a model with sensitive inputs; `recordInputs: false` keeps predictions but stops input drift.
- [ ] Record actuals by `predictionId` or `entityId`; report `rejected` rows with their reasons.
- [ ] Import large files of actuals as a job and poll it; read the rejections page.
- [ ] Set `training.problemType` (or the output schema's type) so predictions are judged as classification or regression.
