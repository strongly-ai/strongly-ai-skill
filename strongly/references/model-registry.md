# Model Registry

The **model registry** is where a trained ML model becomes a first-class,
servable platform resource. You **upload** the trained bytes, **register** a
model entry that points at them, add immutable **versions** as you retrain, and
**deploy** a version as a live inference pod that you can call with **predict**.

Read this when the task is: registering a model you trained (in a workspace, from
custom code, or an external tool), tracking model versions, promoting a version
to serve, deploying a registered model for inference, or running predictions
against a deployed model.

**Auth** follows `SKILL.md`: outside Strongly send `X-API-Key` to `$HOST/api/v1`;
inside Strongly (workspace or app) the bearer is auto-injected at
`$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever applies. Set once
(outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # key needs model-registry:read/write
```

Read-only calls (list, get, status, list versions) need `model-registry:read`;
everything that changes a model (upload, register, update, version, deploy,
stop/start, predict, delete) needs `model-registry:write`.

---

## 1. The lifecycle: upload then register then version then deploy then predict

The registry is deliberately two objects. A **registered model** is the durable
entry (name, framework, metrics, tags, access). Its **versions** are the
immutable snapshots of the actual artifact. You never overwrite a version, you
add a new one and point the model at it. Deploy stands a version up as a serving
pod; predict calls that pod.

- **Upload** the artifact bytes to S3 (`POST /model-registry/upload`), get an `s3Key`.
- **Register** a model that references that `s3Key` (`POST /model-registry/models`).
  Version 1 is created at registration.
- **Version** it as you retrain: upload new bytes, add a version, then activate or
  deploy that version.
- **Deploy** a version to serve it (`POST .../deploy`), then **predict**
  (`POST .../predict`).

You do not have to serve a model to register it. An **external, metadata-only**
entry (no artifact) is valid for cataloguing a model that lives elsewhere.

> AutoML already does upload + register for its winning model. If you got here
> from an AutoML job, the model is likely registered already, so start at
> versions or deploy. See `references/mlops.md`.

---

## 2. Register a model

### 2a. Upload the artifact (multipart, up to 500MB)

Push the trained bytes first. Accepts a single file (`.pkl`, `.joblib`, `.pt`,
`.onnx`) or a `.zip` bundle containing a `strongly.manifest.yaml` at the root or
one level nested.

```bash
# POST /model-registry/upload  (multipart field: file) -> { s3Key, sizeMb, bucket, manifest?, manifestRaw? }
UP=$(curl -s "${auth[@]}" -F "file=@model.zip;type=application/zip" "$BASE/model-registry/upload")
S3KEY=$(echo "$UP" | jq -r '.data.s3Key')
```

`manifest` and `manifestRaw` come back populated only when the bundle is a zip
with a valid `strongly.manifest.yaml`. Keep the whole `data` object, you pass its
`s3Key` (as `artifact: { s3Key }`) and, for zips, `manifest` straight into register.

### 2b. Register the model entry

`name` and `framework` are required. Pass the uploaded `artifact` to make the
entry servable. Omit `artifact` only for an external metadata-only entry.

```bash
# POST /model-registry/models -> data._id (the model id)
MODEL_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{
    "name": "churn-classifier",
    "framework": "sklearn",
    "algorithm": "GradientBoostingClassifier",
    "source": "upload",
    "problemType": "classification",
    "artifact": { "s3Key": "'"$S3KEY"'" },
    "features": { "featureNames": ["tenure","monthly_charges","contract_type"] },
    "metrics": { "accuracy": 0.91, "f1": 0.88 },
    "tags": ["churn","tabular"]
  }' "$BASE/model-registry/models" | jq -r '.data._id')
```

Field notes, grounded in the route:

- **`framework`** (required): `pytorch`, `tensorflow`, `sklearn`, `xgboost`, etc.
- **`features.featureNames`** is **required for tabular frameworks** (`sklearn`,
  `xgboost`), in input column order, so predictions are labeled and drift can be
  tracked.
- **`problemType`** (`classification` or `regression`): set it so the model is
  eligible for drift detection later. It is stored at `training.problemType`;
  without it, drift analysis rejects the model.
- **`source`**: `upload` (you trained and uploaded it), `automl`, `experiment`,
  or `external` (metadata only, no artifact). Defaults to `external`.
- **`artifact`**: `{ s3Key, s3Bucket?, sizeMb? }` from the upload response. For a
  zip bundle also pass **`manifest`** from that same response so the deploy step
  can wrap your own serving script.
- **`algorithm`**, **`metrics`**, **`description`**, **`tags`** are optional model
  card fields.

---

## 3. Versions and promotion

There are no named `staging`/`production` stage labels in this API. Promotion is
expressed through **versions**: which version is **active** (the served
artifact/metrics) and which version is **deployed** (running in the pod).

### List versions

```bash
# GET /model-registry/models/:id/versions -> { versions: [...], activeVersion }
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/versions" | jq '.data'
```

### Add a new version

Upload the retrained artifact first (section 2a), then register it as a new
version. `artifact.s3Key` is required.

```bash
# POST /model-registry/models/:id/versions -> { version, modelId }
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "artifact": { "s3Key": "'"$S3KEY"'" }, "description": "retrained on Q3 data" }' \
  "$BASE/model-registry/models/$MODEL_ID/versions"
```

### Promote a version

Two levels of promotion, both take the version number as the path segment:

```bash
# Activate: point the model's served artifact/metrics at a version, no pod change.
curl -s -X POST "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/versions/2/activate"

# Deploy a version: set it active AND (re)deploy the serving pod with that artifact.
curl -s -X POST "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/versions/2/deploy"
```

Use **activate** to move the pointer without touching a running pod. Use **deploy
version** to actually roll the live pod onto that version. A running model
deploys from a non-running state, so to swap the served version on a live model,
`stop` it first (section 4), then `deploy` the version.

---

## 4. Deploy for inference

Deploy stands the model's active version up as a serving pod. All body fields are
optional; the model manifest fills in the rest.

```bash
# POST /model-registry/models/:id/deploy
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "autoShutdownMinutes": 15, "resources": { "cpu": "1", "memory": "2Gi" } }' \
  "$BASE/model-registry/models/$MODEL_ID/deploy"

# Stop (tears down the pod, moves to stopped) / Start (bring a stopped model back)
curl -s -X POST "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/stop"
curl -s -X POST "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/start"
```

Deploy body fields, from the route:

- **`autoShutdownMinutes`**: `> 0` deploys on-demand (replicas start at 0, the pod
  wakes on the first inference request and scales back to zero after this idle
  window). `0` or omitted means always-on.
- **`schedulingMode`**: `always_on`, `on_demand`, or `scheduled`.
  **`scheduleCron`**: cron expression for `scheduled` mode.
- **`scalingMode`**: `fixed` (default, wakes to `replicas`) or `auto` (demand
  autoscaling: the gateway ramps 0 to `maxReplicas` on live load). With `auto`,
  set **`minReplicas`**, **`maxReplicas`**, and **`targetConcurrency`** (desired =
  ceil(demand / targetConcurrency)). Combine `auto` with `autoShutdownMinutes > 0`
  for autoscale-from-zero.
- **`instanceType`**: Karpenter instance type override.
- **`resources`**: `{ cpu, memory, cpuLimit, memoryLimit, gpu, gpu_type, replicas }`.
- **`environmentVariables`**: non-secret env vars injected into the serving pod.

**Poll before claiming success.** Deploy returns immediately. The registry-side
lifecycle is on `GET /model-registry/models/:id/status`; once deployed, the live
**pod** state moves to the ai-models row, so track the running pod with
`/ai/models/:id/status` (see `references/ai-gateway.md`). Do not report the model
as serving until the pod is running.

---

## 5. Predict against a deployed model

The model must be deployed with `deployment.status === 'running'`. The request is
proxied to the model pod through the AI Gateway (model pods are cluster-internal).

```bash
# POST /model-registry/models/:id/predict
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "input_data": { "tenure": 12, "monthly_charges": 79.9, "contract_type": "month" },
        "entityId": "cust-4821", "logPrediction": true }' \
  "$BASE/model-registry/models/$MODEL_ID/predict"
```

- **`input_data`** (required): the feature payload (object or array). `inputData`
  is accepted as a camelCase alias.
- **`path`**: which route on the model to call when it serves more than one (e.g.
  `"parse_text"`). Omit for the model default.
- **`entityId`**: an id to match a later ground-truth record for drift.
- **`logPrediction`**: log this prediction for drift detection (default `true`).

Returns `{ prediction, predictions, probabilities, latency_ms, predictionId,
entityId }`. The `predictionId`/`entityId` let you attach ground truth later for
drift analysis. Drift itself lives in `references/mlops.md`.

---

## 6. Read, update, delete

```bash
curl -s "${auth[@]}" "$BASE/model-registry/models"                       # list (filters below)
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID"            # full detail
curl -s "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID/status"     # lifecycle snapshot
curl -s -X PUT    "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "description": "updated card" }' "$BASE/model-registry/models/$MODEL_ID"
curl -s -X DELETE "${auth[@]}" "$BASE/model-registry/models/$MODEL_ID"  # delete
```

- **List** accepts `search`, `framework`, `source`, `status` (deployment status),
  `tag`, `workspaceId`, plus `limit`, `offset`, `sortBy`, `sortOrder`. It returns
  lean summaries (the heavy `buildInfo`, `versions`, and `artifact` blobs are
  omitted, fetch a single model or the versions endpoint for those).
- **Status** returns the registry-side lifecycle only: `status`,
  `validation_status`, `deployed`, `deployment`, `version`, `archived`,
  `updatedAt`. For the live serving pod use `/ai/models/:id/status`.
- **Delete** returns clear conflicts, not opaque 500s: `409 model-in-use` (the
  model is connected to apps, disconnect it first) and `409 deployment-busy` (the
  pod is still provisioning, retry the delete shortly).

---

## Endpoint reference

| Method | Path | Purpose |
|---|---|---|
| POST | `/model-registry/upload` | Upload artifact bytes to S3, parse manifest, get `s3Key` |
| POST | `/model-registry/models` | Register a model (servable or external metadata-only) |
| GET | `/model-registry/models` | List registered models (filters + pagination) |
| GET | `/model-registry/models/:id` | Get one model, full detail |
| GET | `/model-registry/models/:id/status` | Registry-side lifecycle snapshot |
| PUT | `/model-registry/models/:id` | Update a registered model |
| DELETE | `/model-registry/models/:id` | Delete a registered model |
| GET | `/model-registry/models/:id/versions` | List versions + which is active |
| POST | `/model-registry/models/:id/versions` | Add a version from an uploaded artifact |
| POST | `/model-registry/models/:id/versions/:v/activate` | Set the active version (no deploy) |
| POST | `/model-registry/models/:id/versions/:v/deploy` | Set active + deploy that version |
| POST | `/model-registry/models/:id/deploy` | Deploy the model for inference |
| POST | `/model-registry/models/:id/stop` | Stop the serving pod |
| POST | `/model-registry/models/:id/start` | Start a stopped model |
| POST | `/model-registry/models/:id/predict` | Run inference on a deployed model |

---

## Checklist
- [ ] Upload the artifact first, capture `s3Key`, pass it as `artifact` to register (servable in one flow). Omit `artifact` only for an external metadata-only entry.
- [ ] Tabular models (`sklearn`, `xgboost`): include `features.featureNames` in input order.
- [ ] Set `problemType` at register time so the model is drift-eligible later.
- [ ] Retrain by adding a version (never overwrite), then `activate` (pointer) or `deploy` (roll the pod). Stop a live model before deploying a different version.
- [ ] After deploy, poll `/model-registry/models/:id/status` for the registry lifecycle and `/ai/models/:id/status` for the live pod before predicting or claiming success.
- [ ] Predict requires `deployment.status === 'running'`; keep `predictionId`/`entityId` if you plan drift analysis (`references/mlops.md`).
- [ ] Serving pod state, inference gateway routing: `references/ai-gateway.md`. Drift, experiments, AutoML: `references/mlops.md`.
