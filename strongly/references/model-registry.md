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
# Inside Strongly (a workspace, app or job): BASE="$STRONGLY_API_URL/api/v1"; auth=()   # signed in as you, no key
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

- **Upload** the artifact bytes to S3 (`POST /mlops/models/uploads/validate`), get an `s3Key`.
- **Register** a model that references that `s3Key` (`POST /mlops/models`).
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
# POST /mlops/models/uploads/validate  (multipart field: file) -> { s3Key, sizeMb, bucket, manifest?, manifestRaw? }
UP=$(curl -s "${auth[@]}" -F "file=@model.zip;type=application/zip" "$BASE/mlops/models/uploads/validate")
S3KEY=$(echo "$UP" | jq -r '.data.s3Key')
```

`manifest` and `manifestRaw` come back populated only when the bundle is a zip
with a valid `strongly.manifest.yaml`. Keep the whole `data` object, you pass its
`s3Key` (as `artifact: { s3Key }`) and, for zips, `manifest` straight into register.

### 2b. Register the model entry

`name` and `framework` are required. Pass the uploaded `artifact` to make the
entry servable. Omit `artifact` only for an external metadata-only entry.

```bash
# POST /mlops/models -> data._id (the model id)
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
  }' "$BASE/mlops/models" | jq -r '.data._id')
```

Field notes, grounded in the route:

- **`framework`** (required): `pytorch`, `tensorflow`, `sklearn`, `xgboost`, etc.
- **`features.featureNames`** is **required for tabular frameworks** (`sklearn`,
  `xgboost`), in input column order, so predictions are labeled and drift can be
  tracked.
- **`problemType`** (`classification`, `regression`, `multiclass`, `multilabel`,
  `timeseries` or `other`; anything else is refused): stored at
  `training.problemType`, it says how the model's predictions are judged against
  actuals (see `references/model-evaluation.md`), and drift needs
  `classification` or `regression`. A model published with a manifest declares
  it (`ml.problem_type`); a model registered from a run takes the one the SDK's
  `log_model` recorded in `MLmodel.json`.
- **`source`**: `upload` (you trained and uploaded it), `automl`, `experiment`,
  or `external` (metadata only, no artifact). Defaults to `external`.
- **`artifact`**: `{ s3Key, s3Bucket?, sizeMb? }` from the upload response. For a
  zip bundle also pass **`manifest`** from that same response so the deploy step
  can wrap your own serving script.
- **A single model file** (`.joblib`/`.pkl`/`.pickle`, `.pt`/`.pth` TorchScript,
  `.onnx`) is served by a server the platform builds, so registering one also
  needs: a `framework` its file type is served as (`sklearn`, `xgboost`,
  `lightgbm`, `custom` for a pickle; `pytorch` for `.pt`; `onnx`);
  **`frameworkVersion`**, the library version it was saved with
  (`sklearn.__version__`; required for sklearn/xgboost/lightgbm/pytorch);
  **`pythonVersion`**, the Python it was saved with (required for a
  `.joblib`/`.pkl`; it is served on that Python); **`schema.input.fields`**
  (`[{name, type}]` in the order the model takes them; predictions are fed in
  that order); and optional **`requirements`**, extra pip specs the model
  imports (`["category-encoders==2.6.3"]`). A file missing one is refused with
  what is missing. Never guess the versions: read them where the model was
  trained.
- **`algorithm`**, **`metrics`**, **`description`**, **`tags`** are optional model
  card fields.

---

## 3. Versions and promotion

There are no named `staging`/`production` stage labels in this API. Promotion is
expressed through **versions**: which version is **active** (the served
artifact/metrics) and which version is **deployed** (running in the pod).

### List versions

```bash
# GET /mlops/models/:id/versions -> { versions: [...], activeVersion }
curl -s "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/versions" | jq '.data'
```

A version registered from an experiment run has `sourceRun` `{ experimentId, runId }`.

### Add a new version

Upload the retrained artifact first (section 2a), then register it as a new
version. `artifact.s3Key` is required. For a single model file the artifact
also carries `frameworkVersion`, `pythonVersion` and `requirements` (as in
register); pass `schema` only when its inputs differ from the model's.

```bash
# POST /mlops/models/:id/versions -> { version, modelId }
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "artifact": { "s3Key": "'"$S3KEY"'" }, "description": "retrained on Q3 data" }' \
  "$BASE/mlops/models/$MODEL_ID/versions"
```

### Promote a version

Two levels of promotion, both take the version number as the path segment:

```bash
# Activate: point the model's served artifact/metrics at a version, no pod change.
curl -s -X POST "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/versions/2/activate"

# Deploy a version: set it active AND (re)deploy the serving pod with that artifact.
curl -s -X POST "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/versions/2/deploy"
```

Use **activate** to move the pointer without touching a running pod. Use **deploy
version** to actually roll the live pod onto that version. A running model
deploys from a non-running state, so to swap the served version on a live model,
`stop` it first (section 4), then `deploy` the version.

### Delete a version

Delete a duplicate or unwanted version by its number. Confirm with the user first:
it cannot be undone.

```bash
# DELETE /mlops/models/:modelId/versions/:id -> 204
curl -s -X DELETE "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/versions/3"
```

Its image, its uploaded bundle (kept while another version is the same upload),
its baselines and the drift analyses against them are deleted. Its predictions are
kept and still name it; the model lists it in `deletedVersions` and no later
version takes its number. Refused with `409` and a `code`: `version-active` (deploy
or activate another version first), `only-version` (delete the model instead),
`version-deploying`, `baseline-building`. A `502` `image-delete-failed` keeps the
version; retry. SDK: `client.model_registry.delete_version(model_id, 3)`.

---

## 4. Deploy for inference

Deploy stands the model's active version up as a serving pod. All body fields are
optional; the model manifest fills in the rest.

```bash
# POST /mlops/models/:id/deploy
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "autoShutdownMinutes": 15, "resources": { "cpu": "1", "memory": "2Gi" } }' \
  "$BASE/mlops/models/$MODEL_ID/deploy"

# Stop (tears down the pod, moves to stopped) / Start (bring a stopped model back: it is
# `starting` until its pod is ready, then `running`, or `failed` with the reason; poll it)
curl -s -X POST "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/stop"
curl -s -X POST "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/start"
```

An AutoML model is served on the trainer image that trained it (`artifact.trainerImage`, by its
digest), never on whatever trainer is current. A model whose `retrainReason` is set (published
before AutoML jobs recorded their trainer image: "Retrain to deploy") is refused by deploy,
start and a version's deploy with `409` and that reason: retrain its AutoML job with the same
data and settings and publish the new model; retrying the deploy cannot work.

Deploy body fields, from the route:

- **`autoShutdownMinutes`**: `> 0` deploys on-demand (replicas start at 0, the pod
  wakes on the first inference request and scales back to zero after this idle
  window). `0` or omitted means always-on.
- **`schedulingMode`**: `always_on`, `on_demand` or `scheduled`.
- **`scheduleRules`** (with `scheduled`): `[{ id, action: "start" | "stop", dayOfWeek: [0-6] (0 = Sunday),
  time: "HH:MM", timezone: IANA name }]`, at least one start and one stop. The platform starts the
  model at each start time and stops it at each stop time, on the listed days.
- **`scalingMode`**: `fixed` (default, wakes to `replicas`) or `auto` (demand
  autoscaling: the gateway ramps 0 to `maxReplicas` on live load). With `auto`,
  set **`minReplicas`**, **`maxReplicas`**, and **`targetConcurrency`** (desired =
  ceil(demand / targetConcurrency)). `auto` is on-demand only (`autoShutdownMinutes > 0`).
- **`autoscaling`**: the always-on HPA, `{ enabled, minReplicas, maxReplicas, cpuThreshold,
  memoryThreshold }`; always-on only.
- **`useSpot`** / **`spotFallback`**: run on spot capacity; with `spotFallback` (default true)
  fall back to on-demand capacity when spot is unavailable.
- **`instanceType`**: Karpenter instance type override.
- **`resources`**: `{ cpu, memory, gpu, gpu_type, replicas }`: the one size the model runs at
  (it requests exactly what it is limited to).

Change any of these without deploying with `PATCH /mlops/models/:id/serving` (same fields, plus
`environmentId`, and what the model's server is given: `environmentVariables`, and its secret
references `addons` and `dataSources`, whose connections and credentials reach its pods in
`STRONGLY_SERVICES`; each replaces the whole set, `null` removes it; put a site login or token in
a data source, e.g. an `api` one, never in a variable). A version may carry its own on
`POST /mlops/models/:id/versions`; they replace the model's when it becomes active. A model's
own code calls the AI Gateway with no key, as its deployer: the platform sets `STRONGLY_API_URL`
and `STRONGLY_PLATFORM_AUTH` (the SDK's `client.ai` works as is; a model's token reaches
`/api/v1/ai-gateway/` only). Scheduling and demand scaling apply to a deployed model at once, resources and
spot from its next deploy or start (a start renders the model from its saved settings).

```bash
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/mlops/models/$MODEL_ID/serving" \
  -d '{"schedulingMode":"scheduled","scheduleRules":[
        {"id":"wk-start","action":"start","dayOfWeek":[1,2,3,4,5],"time":"09:00","timezone":"America/New_York"},
        {"id":"wk-stop","action":"stop","dayOfWeek":[1,2,3,4,5],"time":"17:00","timezone":"America/New_York"}]}'
```

**Poll before claiming success.** Deploy returns immediately. Poll
`GET /mlops/models/:id/status` until it is `running` (or `idle` for an on-demand model), or
`failed` with the reason. Do not report the model as serving before that.

---

## 5. Predict against a deployed model

The model must be deployed with `deployment.status === 'running'`. The request is
proxied to the model pod through the AI Gateway (model pods are cluster-internal).

```bash
# POST /mlops/models/:id/predict
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "input_data": { "tenure": 12, "monthly_charges": 79.9, "contract_type": "month" },
        "entityId": "cust-4821" }' \
  "$BASE/mlops/models/$MODEL_ID/predict"
```

- **`input_data`** (required): the feature payload (object or array). `inputData`
  is accepted as a camelCase alias.
- **`path`**: which route on the model to call when it serves more than one (e.g.
  `"parse_text"`). Omit for the model default.
- **`entityId`**: your id for what is predicted; actuals can be attached by it.
- **`source`**: `"production"` (default) or `"test"`, which keeps a trial call
  out of production results (drift and performance).

Returns `{ prediction, predictions, probabilities, latency_ms, predictionId,
predictionIds, entityId }`. Every prediction is recorded with its model version;
keep `predictionId` (or your `entityId`) to attach its actual later. Prediction
records, actuals and the Record inputs setting are in
`references/model-evaluation.md`; drift is `references/drift.md`; comparing
models on live traffic is `references/ab-testing.md`.

A prediction runs as long as it takes (no read deadline). Send a predict again
only when it never reached the model: the connection did not open, or the answer
is **503** (the model is starting, every replica is busy, or an AI Gateway replica
was stopping before it sent the call). A **502** whose detail opens
`Response lost:` means the call reached the model and its answer was lost; do not
send it again, as the model may already have done the work. A model worker that
is scaled down or replaced finishes the predictions it holds (up to 30 minutes).

---

## 6. Read, update, delete

```bash
curl -s "${auth[@]}" "$BASE/mlops/models"                       # list (filters below)
curl -s "${auth[@]}" "$BASE/mlops/models/$MODEL_ID"            # full detail
curl -s "${auth[@]}" "$BASE/mlops/models/$MODEL_ID/status"     # lifecycle snapshot
curl -s -X PUT    "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "description": "updated card" }' "$BASE/mlops/models/$MODEL_ID"
curl -s -X PUT    "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{ "problemType": "classification" }' "$BASE/mlops/models/$MODEL_ID"  # set its task only
curl -s -X DELETE "${auth[@]}" "$BASE/mlops/models/$MODEL_ID"  # delete
```

- **Delete** is refused with `409` `model-in-use` while something uses the model:
  an A/B test that compares it, an app, workspace or job that selects it, or a
  workflow or agent whose nodes call it. `detail` names them by kind; remove the
  model from those (delete the A/B test) before deleting it. Never delete what
  uses it without asking the user.

- **Update** changes only the fields sent. `problemType` sets `training.problemType`
  (on the card and the active version) and keeps the rest of the training
  record; `training` replaces the whole record. A model registered without a
  task (e.g. from a run whose `log_model` could not tell it) needs this before
  drift can monitor it.
- **List** accepts `q`, `framework`, `source`, `status` (deployment status),
  `tag`, `workspaceId`, plus `limit`, `cursor`, `sort`. It returns
  lean summaries (the heavy `buildInfo`, `versions`, and `artifact` blobs are
  omitted, fetch a single model or the versions endpoint for those), each with
  its `retrainReason` (null when it can be deployed).
- **Status** (`GET /mlops/models/:id/status`) returns `status` (its deployment's:
  `registered` = never deployed, `building`, `deploying`, `starting`, `running`,
  `idle`, `waking`, `stopped`, `failed`), `canServe` (predictions can be made now),
  `retrainReason` (why it must be retrained before it can be deployed or started, null
  when it can be), `activeVersion`, `versionCount` and `updatedAt`.
- **Logs** (`GET /mlops/models/:id/logs`, `logType` build or runtime) reads their
  lines; the current image build's whole log downloads as a file through a signed
  download link (5 minutes): `POST /mlops/models/:id/build-logs/download`.
- **Delete** returns clear errors, not opaque 500s: `409 model-in-use` (the
  model is connected to apps, disconnect it first) and `502 deployment-delete-failed`
  (its deployment could not be deleted, so the model is kept; the detail is the
  reason).

---

## Endpoint reference

| Method | Path | Purpose |
|---|---|---|
| POST | `/mlops/models/uploads/validate` | Upload artifact bytes to S3, parse manifest, get `s3Key` |
| POST | `/mlops/models` | Register a model (servable or external metadata-only) |
| GET | `/mlops/models` | List registered models (filters + pagination; `q` on name, description, framework, algorithm) |
| GET | `/mlops/models/stats` | The list's counts with its filters: `{ total, byDeploymentStatus, byFramework, bySource, byDriftStatus }` (rows `{ <field>, total }`, most first; driftStatus null = never analyzed) |
| GET | `/mlops/models/:id` | Get one model, full detail |
| GET | `/mlops/models/:id/status` | Registry-side lifecycle snapshot |
| PATCH | `/mlops/models/:id` | Update a registered model |
| DELETE | `/mlops/models/:id` | Delete a registered model |
| GET | `/mlops/models/:id/versions` | List versions, newest first (`sort` `-version` default, `version`, `createdAt`, `-createdAt`) + which is active |
| POST | `/mlops/models/:id/versions` | Add a version from an uploaded artifact |
| POST | `/mlops/models/:modelId/versions/:id/activate` | Set the active version (no deploy) |
| POST | `/mlops/models/:modelId/versions/:id/deploy` | Set active + deploy that version |
| POST | `/mlops/models/:id/deploy` | Deploy the model for inference |
| PATCH | `/mlops/models/:id/serving` | Change how it is served (strategy, schedule, spot) without deploying |
| POST | `/mlops/models/:id/stop` | Stop the serving pod |
| POST | `/mlops/models/:id/start` | Start a stopped model |
| POST | `/mlops/models/:id/predict` | Run inference on a deployed model |

Monitoring settings, actuals and baselines also live under
`/mlops/models/:id` (`/monitoring`, `/actuals...`, `/baselines...`);
they are documented in `references/model-evaluation.md` and
`references/drift.md`.

---

## Checklist
- [ ] Upload the artifact first, capture `s3Key`, pass it as `artifact` to register (servable in one flow). Omit `artifact` only for an external metadata-only entry.
- [ ] Tabular models (`sklearn`, `xgboost`): include `features.featureNames` in input order.
- [ ] Set `problemType` at register time so its predictions are judged as classification or regression (`references/model-evaluation.md`).
- [ ] Retrain by adding a version (never overwrite), then `activate` (pointer) or `deploy` (roll the pod). Stop a live model before deploying a different version.
- [ ] After deploy, poll `/mlops/models/:id/status` until it is `running` (or `idle` on demand) before predicting or claiming success.
- [ ] Predict requires `deployment.status === 'running'`; every prediction is recorded, so keep `predictionId`/`entityId` to attach actuals (`references/model-evaluation.md`); send `source: "test"` for trial calls.
- [ ] Serving pod state, inference gateway routing: `references/ai-gateway.md`. Drift: `references/drift.md`. A/B tests: `references/ab-testing.md`. Experiments, AutoML: `references/mlops.md`.
