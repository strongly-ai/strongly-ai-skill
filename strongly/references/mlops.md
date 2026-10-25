# MLOps

The Strongly **MLOps** surface is the model lifecycle over one REST API: train
models with **AutoML**, track runs as **experiments**, watch production models
with **drift detection**, adapt open models with **fine-tuning**, serve features
from the **feature store**, and run **inference** through the gateway.

Read this when the task is: training a tabular/timeseries model without writing
training code, comparing training runs, fine-tuning a self-hosted HuggingFace
model, reading online or historical features, or calling a model for
chat/embeddings/audio/images. For watching a registry model in production
(prediction records, actuals, baselines, drift), see section 3.

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key:
$STRONGLY_API_KEY"` to `$HOST/api/v1`; inside Strongly the bearer is auto-injected
at `$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever applies, and every
example assumes the auth header is set:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
# Inside Strongly (a workspace, app or job): BASE="$STRONGLY_API_URL/api/v1"; auth=()   # signed in as you, no key
```

**Everything that trains is async and slow.** AutoML jobs, fine-tuning jobs, and
drift analysis return an id immediately and finish minutes to hours later. NEVER
read results off the create call. Poll the job's `/status` until it reaches a
**terminal** state, and on failure read its `/logs` (or the result's error field)
before you report anything:

```bash
# Reusable poll: stop when status is a terminal state, then act on it.
poll() { # $1 = status URL (already includes any ?modelId=…)
  while :; do
    s=$(curl -s "${auth[@]}" "$1" | jq -r '.data.status')
    echo "status=$s"
    case "$s" in completed|failed|succeeded|cancelled|error) break;; esac
    sleep 15
  done
}
```

Two lifecycle actions overlap other areas: promoting an AutoML model registers it
in the **model registry** (see `references/model-registry.md`), and deploying a
fine-tuned model stands up a self-hosted gateway endpoint (see
`references/ai-gateway.md`). This file does not duplicate those.

---

## 1. AutoML  (scope `ml-workbench:read` / `ml-workbench:write`)

Point AutoML at a CSV and a target column; it trains and ranks models with
AutoGluon, then you deploy the winner. The dataset can be a project **dataset
volume**, an uploaded file, an `s3://` path, or a CSV imported from an
object-storage data source.

| Method + path | Does | Key params |
|---|---|---|
| `GET /mlops/automl-jobs/stats` | Totals (active/completed/failed, accuracy, models); cost is FinOps' alone | none |
| `GET /mlops/automl-datasets` | List dataset volumes you can train on | none |
| `GET /mlops/automl-datasets/:id/files` | Files inside a volume (pick one to train on) | path `id` |
| `GET /mlops/automl-datasets/:id/columns` | Column headers of a file (pick target/features) | path `id`, `file` |
| `POST /mlops/automl-datasets/uploads` | Presigned URL to upload a CSV | `filename`, `contentType?` |
| `GET /mlops/automl-jobs` | List jobs | `q`, `status`, `limit`, `cursor`, `sort` |
| `POST /mlops/automl-jobs` | Create a training job | see below |
| `GET /mlops/automl-jobs/:id` | Full job (live-synced from trainer) | path `id` |
| `GET /mlops/automl-jobs/:id/status` | Lightweight lifecycle view (live-synced) | path `id` |
| `GET /mlops/automl-jobs/:id/metrics` | Leaderboard, best model, val score | path `id` |
| `GET /mlops/automl-jobs/:id/logs` | Trainer logs | path `id`, `lines?`, `since?` |
| `POST /mlops/automl-jobs/:id/dataset/download` | A signed download link (5 minutes) to the dataset file the job staged (an upload, or a feature service job's entity/label file) | path `id` |
| `POST /mlops/automl-jobs/:id/stop` | Stop a running job | path `id` |
| `DELETE /mlops/automl-jobs/:id` | Delete a job | path `id` |
| `POST /mlops/automl-jobs/:id/deploy` | Publish the best model of a tabular or multimodal job to the model registry (a timeseries job's is refused; so is a job that records no `trainerImage`: retrain it) | path `id`, `registryName?` |

A job records the trainer image it ran on, by its digest (`trainerImage`); its experiment run
(`systemInfo.trainerImage`) and the published model's `artifact.trainerImage` carry it, and the
model is always served on that image, whatever trainer is current.
When a tabular or multimodal job completes, that serving image is built at once (the job's
`servingImage`: `status` building, completed or failed with `error`), so a model published later still
deploys after its trainer image has been retired; a publish while it builds waits for it.

A job's scores (`metrics.val_score`, `metrics.test_score`, leaderboard `score`) are AutoGluon's in
`models_info.eval_metric`: higher is better, so an error metric (RMSE, MAE, MASE, log loss) is
negative. Report it with the sign flipped, in the metric's units, never as a percentage.
The job's experiment runs differ: their `val_score` and `test_score` are already in the metric's
units (an RMSE positive; the job's run names it as `eval_metric`), and `relative_score_pct` is a
model's score as a percentage of the best model's (100 for the best).
`metrics.feature_importance` is each feature's permutation importance (a share of the total) on
the rows `metrics.feature_importance_rows` names, which the model was not trained on.

`POST /mlops/automl-jobs` required fields: `name`, `dataset`, `targetColumn`,
`hardware`. `hardware` is an object and has NO default: it must include
`cpu_count`, `memory_gb`, `disk_gb` (numbers); `gpu_count`, `gpu_type`, `use_spot` (spot capacity) and `spot_fallback` (default true: on-demand when no spot is available)
optional. Optional:
`datasetFile` (when a volume has more than one file), `featureColumns`,
`problemType` (`tabular`|`multimodal`|`timeseries`), `predictorType`
(`auto`|`BinaryClassifier`|`MultiClassifier`|`Regressor`), `preset`
(`medium_quality` default, `good_quality`, `high_quality`, `best_quality`,
`optimize_for_deployment`), `timeLimit` (seconds, default 600), `metric`, and `advanced`
(by section: tabular `model_selection`, `ensemble`, `data_handling`, `training`, `hpo`,
`model_hyperparameters`, `custom`; `timeseries` {`prediction_length`, `freq`, `id_column`,
`timestamp_column`, ...}; `multimodal` {`text_columns`, `image_columns`, `backbone`, ...}; the
API reference lists every key). Send `model_hyperparameters` only to fix values: a family given
values keeps them in every model and `hpo` searches only the rest; without it every family uses
AutoGluon's defaults, which `hpo` tunes. The id
tools accept **either** the returned `job_id` or the Mongo `_id`.

```bash
# Create, then POLL to a terminal state before touching results. Active states:
# pending, preparing, running, training, evaluating. Terminal: completed | failed.
JOB=$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -X POST "$BASE/mlops/automl-jobs" -d '{
  "name":"churn-v1","dataset":"<volumeId-or-s3Path>","targetColumn":"churned",
  "problemType":"tabular","preset":"high_quality","timeLimit":900,
  "hardware":{"cpu_count":4,"memory_gb":16,"disk_gb":50}
}' | jq -r '.data.job_id')

poll "$BASE/mlops/automl-jobs/$JOB/status"
# On failure, read logs; do NOT report success:
curl -s "${auth[@]}" "$BASE/mlops/automl-jobs/$JOB/logs?lines=200" | jq -r '.data'
# On success, inspect the leaderboard then promote the winner:
curl -s "${auth[@]}" "$BASE/mlops/automl-jobs/$JOB/metrics" | jq '.data.leaderboard'
curl -s "${auth[@]}" -X POST "$BASE/mlops/automl-jobs/$JOB/deploy" -d '{"registryName":"churn-model"}'
```

Checklist: pick the exact file (`/files`) and target (`/columns`) before create;
always send `hardware`; poll `/status` to `completed`; on `failed` read `/logs`;
deploy only a completed tabular or multimodal job (a timeseries model stays in
the job's output volume). A published multimodal model (framework
`strongly-automl-multimodal`) takes its image inputs as base64 or a `data:` URL
and its text inputs as text. Registry details: `references/model-registry.md`.

---

## 2. Experiments  (scope `ml-workbench:read` / `ml-workbench:write`)

An experiment is a **tracking record** that groups training runs and logs their
params, metrics, and artifacts. It creates no filesystem, volume, or compute (to
launch a dev environment use a workspace; this only tracks runs). The AutoML
trainer writes to these automatically; you also drive them directly.

| Method + path | Does | Key params |
|---|---|---|
| `GET /mlops/experiments` | List | `q`, `status`, `tag`, `pinned`, `limit`, `cursor`, `sort` |
| `GET /mlops/experiments/stats` | Totals (running/completed/failed/pinned) | none |
| `GET /mlops/experiments/compare` | Compare 2+ runs side by side | `ids` (comma-separated, min 2) |
| `POST /mlops/experiments` | Create a tracking record (a run of another with `parentRunId`) | `name`, `description?`, `params?`, `tags?`, `parentRunId?`, `status?` |
| `POST /mlops/experiments/register` | Create or find by name (idempotent) | `name`, `description?`, `tags?` |
| `GET /mlops/experiments/:id` | Get one | path `id` |
| `PATCH /mlops/experiments/:id` | Update | path `id`; `name`, `description`, `status`, `tags` (replaces them), `pinned` (true pins, false unpins), `framework` (the trained model's; `log_model` sets it), `error` `{type, message, traceback}` (required with `status` `failed`, refused otherwise) |
| `DELETE /mlops/experiments/:id` | Delete | path `id` |
| `POST /mlops/experiments/:id/metrics` | Append metrics to the run | path `id`, `metrics` (`[{key,value,step?}]`) |
| `POST /mlops/experiments/:id/params` | Merge params (upsert by key) | path `id`, `params` (object) |
| `POST /mlops/experiments/:id/artifacts/uploads` | Get a link to upload one artifact file (PUT its bytes within an hour) | path `id`; `path`, `contentType?` |
| `POST /mlops/experiments/:id/artifacts/multipart-uploads` | Start a large (over 5 GB) upload in parts; then `…/multipart-uploads/:id/complete` (`path`, `parts: [{partNumber, etag}]`) or `…/abort` | path `id`; `path`, `size`, `contentType?` |
| `POST /mlops/experiments/:id/artifacts` | Record an uploaded artifact (its size is read from storage) | path `id`; `path`, `name?`, `type?`, `description?` |
| `GET /mlops/experiments/:id/artifacts` · `POST …/artifacts/download` | List the run's artifacts / a signed download link (5 minutes) to one | path `id`; `path` (download) |
| `GET /mlops/experiments/:id/metrics` · `GET /mlops/experiments/:experimentId/metrics/:key` | The keys the run has logged metrics under (a list) / one metric's history | |
| `POST /mlops/experiments/:id/models` | Register the model the run logged (`log_model`) in the model registry | path `id`; `name` (new model) or `modelId` (new version); `description?`, `artifactPath?` (default `model`), `files?` (a bundle: the run's files and folders, the model folder among them, registered together as the version's artifact; every version records `sourceRun`). The task `log_model` recorded (`problemType`) becomes the model's `training.problemType`; without one, set it with `PATCH /mlops/models/:id` `problemType` before drift |

```bash
EXP=$(curl -s "${auth[@]}" -X POST "$BASE/mlops/experiments/register" \
  -d '{"name":"churn-tuning","tags":["q3"]}' | jq -r '.data._id')
curl -s "${auth[@]}" -X POST "$BASE/mlops/experiments/$EXP/params" \
  -d '{"params":{"lr":0.001,"epochs":5}}'
curl -s "${auth[@]}" -X POST "$BASE/mlops/experiments/$EXP/metrics" \
  -d '{"metrics":[{"key":"val_accuracy","value":0.91,"step":5}]}'
curl -s "${auth[@]}" "$BASE/mlops/experiments/compare?ids=$EXP,<otherId>" | jq '.data'
```

Checklist: `register` (not `create`) when you may re-run and want one record; log
`params` before, `metrics` during; upload the model as an artifact when done;
`compare` needs at least two ids.

---

## 3. Drift detection and model evaluation

Registry models are evaluated from production: every prediction is recorded,
actuals are joined to it, and drift compares each version's live inputs with
that version's baseline. This has its own references:

- `references/model-evaluation.md`: prediction records, the Record inputs
  setting, actuals (one by one or a file of any size), how a model is judged,
  and the model card.
- `references/drift.md`: baselines (built by a job from reference rows, with
  `analyzeDaily`), analyses and why one produced no result, results and their
  per-feature rows, thresholds and the schedule.
- `references/ab-testing.md`: comparing registry models on live traffic.

---

## 4. Fine-tuning  (scope `fine-tuning:read` / `fine-tuning:write`)

Adapt a **self-hosted HuggingFace** base model (LoRA by default). Third-party
vendor models (gpt-4o, claude, gemini) are NOT fine-tunable here. Size the config
with the read endpoints first, then submit and poll.

| Method + path | Does | Key params |
|---|---|---|
| `GET /ai-gateway/fine-tuning-jobs/stats` | Summary stats | none |
| `GET /ai-gateway/fine-tuning/base-models` | The one fine-tuning catalog (sizing: `loraRequirements`, `serving`) | none |
| `GET /ai-gateway/fine-tuning/hardware` | Hardware/GPU options | none |
| `GET /ai-gateway/fine-tuning/model-requirements` | VRAM/hardware needs for a base model | `baseModel`, `method?` |
| `POST /ai-gateway/fine-tuning/recommend` | Recommend a config | `baseModel`, `useCase?`, `datasetSize?` |
| `POST /ai-gateway/fine-tuning-jobs/validate` | Pre-flight validation | `baseModel`, `method`, `hardware?`, `methodConfig?` |
| `GET /ai-gateway/fine-tuning-jobs` | List jobs | `q`, `status`, `baseModel`, `limit`, `cursor`, `sort` |
| `POST /ai-gateway/fine-tuning-jobs` | Create a job | `name`, `baseModel`, `trainingDataset`, `description?` |
| `GET /ai-gateway/fine-tuning-jobs/:id` | Full job (live-synced) | path `id` |
| `GET /ai-gateway/fine-tuning-jobs/:id/status` | Lifecycle view (live-synced) | path `id` |
| `GET /ai-gateway/fine-tuning-jobs/:id/metrics` | Training metrics | path `id` |
| `GET /ai-gateway/fine-tuning-jobs/:id/logs` | Job logs | path `id`, `lines?`, `since?` |
| `POST /ai-gateway/fine-tuning-jobs/:id/stop` | Stop a running job | path `id` |
| `POST /ai-gateway/fine-tuning-jobs/:id/restart` | Restart a job | path `id` |
| `DELETE /ai-gateway/fine-tuning-jobs/:id` | Delete a job | path `id` |
| `POST /ai-gateway/fine-tuning-jobs/:id/deploy` | Deploy the trained model as a self-hosted endpoint; served at `maxTokens` context length, default the base model's context window (required when its HF config records none) | path `id` |

`baseModel` must be an id from `/base-models` (e.g. `Qwen/Qwen2.5-7B-Instruct`): any other is refused (400);
`trainingDataset` is a prepared file (JSONL from a Data Forge export, a project
volume file path, or a URL/dataset id). Fine-tuning trains on NVIDIA GPUs only:
`environment.gpuCount` is 1 to 8 (default 1, a T4 unless `gpuType` says
otherwise); `0` is refused (400). Recommended flow:
`recommend` -> `validate-config` -> `create` -> poll -> `deploy`.

```bash
curl -s "${auth[@]}" "$BASE/ai-gateway/fine-tuning/base-models" | jq '.data'
curl -s "${auth[@]}" -X POST "$BASE/ai-gateway/fine-tuning-jobs/validate" \
  -d '{"baseModel":"Qwen/Qwen2.5-7B-Instruct","method":"lora","hardware":{"gpu_type":"A100","gpu_count":1}}'

JOB=$(curl -s "${auth[@]}" -X POST "$BASE/ai-gateway/fine-tuning-jobs" -d '{
  "name":"support-tone","baseModel":"Qwen/Qwen2.5-7B-Instruct",
  "trainingDataset":"volumes/train.jsonl"}' | jq -r '.data.job_id // .data._id')

# Terminal states: completed | failed (active: queued, running).
poll "$BASE/ai-gateway/fine-tuning-jobs/$JOB/status"
curl -s "${auth[@]}" "$BASE/ai-gateway/fine-tuning-jobs/$JOB/logs?lines=200" | jq -r '.data'   # on failure
curl -s "${auth[@]}" -X POST "$BASE/ai-gateway/fine-tuning-jobs/$JOB/deploy"                    # on success
```

Checklist: HuggingFace base model only; run `model-requirements` +
`validate-config` before create (avoid a wasted GPU job); poll `/status`; read
`/logs` on failure; deploying stands up a gateway endpoint, see
`references/ai-gateway.md`.

---

## 5. Feature store  (external auth: `X-API-Key`; data-plane calls require an organization)

Register feature definitions and read features for training or serving. These
routes are REST-only (no agent tool wrappers). Data-plane calls delegate to the
platform feature-store service as the calling user, so pass the service's own
JSON body through unchanged.

Reads need `mlops:read`, changes need `mlops:write` (both in the `ml-ops` and `developer` bundles).

| Method + path | Does | Scope |
|---|---|---|
| `GET /mlops/feature-stores` | List feature stores you can access | `mlops:read` |
| `GET /mlops/feature-stores/:id` | One store with its `entities`, every version of its `views` (status `active` or `deprecated`) and its `services`: read these before applying a change | `mlops:read` |
| `POST /mlops/feature-stores/:id/apply` | Register/update entities, views, services (dependency order) | `mlops:write` |
| `POST /mlops/feature-stores/:id/online-features` | Read low-latency online features for serving (`featureService`, `entityRows`, `featureServiceVersion?`, `maxStalenessSeconds?`) | `mlops:read` |
| `POST /mlops/feature-stores/:id/historical-features` | Point-in-time-correct features for training (`featureService`, `entityRows` or `entityS3Uri` + `entityFormat?`) | `mlops:read` |
| `POST /mlops/feature-stores/:storeId/views/:name/materialize` | Materialize a view from offline to online store (a batch view with a source table pulls the source first; `ingested` counts those rows) | `mlops:write` |
| `POST /mlops/feature-stores/:storeId/views/:name/rows` | Write feature rows into a view's history (`rows`) | `mlops:write` |
| `POST /mlops/feature-stores/:storeId/views/:name/events` | Push real-time events to a streaming aggregation view (`events`) | `mlops:write` |
| `POST /mlops/feature-stores/:storeId/views/:name/forget` | Delete every row of some entities from a view (`entityRows`, each exactly the view's join keys): each version's history rows, tiles and live values; a source table keeps its rows | `mlops:write` |
| `POST /mlops/feature-stores/:storeId/views/:name/versions/:version/deprecate` | Deprecate a view version: read-only, hidden, still resolved by services pinned to it | `mlops:write` |
| `POST /mlops/feature-stores` | Create a store: `name`, `onlineEnabled`, `bindings` (`offline` Postgres, `online?` Redis: `[{serviceKind, serviceId}]`), `snapshotRetentionDays` (required: 1-3650 or null); 201 + the store, `pending` until ready | `mlops:write` |
| `DELETE /mlops/feature-stores/:id` | Delete a store and everything in it (as its page does); 422 while a model, app, workspace or job uses it; add-ons kept | `mlops:write` |
| `PATCH /mlops/feature-stores/:id` | Rename, describe, or set `snapshotRetentionDays` (1-3650, or null = until the store is deleted); answers the store | `mlops:write` |
| `POST /mlops/feature-stores/:storeId/views/:name/online-features` | A view's live values: every feature it serves for each of `entityRows` (`viewVersion` optional) | `mlops:read` |
| `DELETE /mlops/feature-stores/:storeId/views/:name/versions/:id` | Delete one view version (refused while a feature service pins it); its add-on tables and keys are dropped, nothing else | `mlops:write` |
| `GET /mlops/feature-stores/:storeId/snapshots` | Training snapshots, newest first (`id`, `featureService`, `sizeBytes`, `createdAt`, `inUse`); needs edit access | `mlops:read` |
| `DELETE /mlops/feature-stores/:storeId/snapshots/:id` | Delete one snapshot; 409 while an unfinished AutoML job trains from its service | `mlops:write` |

A breaking change creates a new view version whose history starts empty: the
platform pulls the source and publishes it from the beginning for that version.

A stream view with `aggregations` (`[{column, function, windows}]`, `tileSize` and the
required `allowedLateness`, at most its longest window) serves `<column>_<function>_<window>`
features; send events with `POST /mlops/feature-stores/:storeId/views/:name/events`. Online
windows are as of now (an old event ages out even when an entity sends nothing new), matching
training data for the same moment. Events are aggregated by event time: one that arrives out of
order within `allowedLateness` of its entity's newest event updates the online values as if it
had arrived in order (set it to the longest window to apply every event a live value reads); a
later one counts in training data only.

An on-demand view (`mode: "on_demand"`) computes features at request time:
`transformCode` defines `transform(df)` (pandas in: its `onDemandSources`' features +
`requestDataSources` fields; out: a DataFrame with its features, same rows; import
what it uses). Applying it pins the sources' newest active versions and deploys a
sandboxed transform workflow owned by you; the view's `transformStatus` is
`provisioning`, `ready` or `failed` (`transformError`; apply again to retry). Callers
pass the request fields on each entity row (online) or as entity-frame columns (training).

`apply` takes optional `entities`, `views`, `services` arrays (the store is in the
path); each view's `change` in the result is `created`, `identical`, `additive`
or `breaking`. Entity rows, written rows and events are your own data, keyed by your
join-key and feature names, and pass through unchanged; discover a store's
entities, views and services with `GET /mlops/feature-stores/:id`.

```bash
STORE=$(curl -s "${auth[@]}" "$BASE/mlops/feature-stores" | jq -r '.data[0]._id')
curl -s "${auth[@]}" -X POST "$BASE/mlops/feature-stores/$STORE/apply" \
  -d '{"entities":[...],"views":[...],"services":[...]}'
curl -s "${auth[@]}" -X POST "$BASE/mlops/feature-stores/$STORE/online-features" \
  -d '{"featureService":"<service>","entityRows":[{"driver_id":1001}]}'
```

Checklist: `apply` before you read; use `online-features` for serving and
`historical-features` for training; `materialize` fills the online store; the
data-plane calls (online/historical-features, materialize, write, push) reject a
call made without an organization.

---

## 6. Inference  (scope `ai-gateway:inference`)

Call any model wired through the gateway with an OpenAI-shaped body. `model` is a
gateway model id (list them via `references/ai-gateway.md`). All accept
`"stream": true` where a streamed SSE response makes sense.

| Method + path | Does | Key params |
|---|---|---|
| `POST /ai-gateway/chat/completions` | Chat completion | `model`, `messages`, `stream?`, `temperature?`, `max_tokens?` |
| `POST /ai-gateway/completions` | Text completion | `model`, `prompt`, `stream?`, `temperature?`, `max_tokens?` |
| `POST /ai-gateway/embeddings` | Embeddings | `model`, `input` |
| `POST /ai-gateway/rerank` | Rerank documents by relevance | `model`, `query`, `documents` |
| `POST /ai-gateway/moderations` | Content moderation | `input`, `model?` |
| `POST /ai-gateway/tokenize` | Token count + model max context | `model`, `prompt` |
| `POST /ai-gateway/audio/speech` | Text-to-speech (binary audio out) | `model`, `input`, `voice?` |
| `GET /ai-gateway/audio/speech/voices` | List TTS voices | none |
| `POST /ai-gateway/audio/transcriptions` | Speech-to-text (multipart file upload) | `model`, `file`, `language?` |
| `POST /ai-gateway/audio/translations` | Speech-to-English (multipart file upload) | `model`, `file` |
| `POST /ai-gateway/generations/images` | Image generation | `model`, `prompt`, `n?`, `size?` |
| `POST /ai-gateway/generations/videos` | Video generation (async job) | `model`, `prompt` |
| `POST /ai-gateway/generations/music` | Music generation (async job) | `model`, `prompt` |
| `POST /ai-gateway/generations` | Unified image/video/music generation | `model`, `prompt`, `type` (required), `parameters?` |
| `GET /ai-gateway/generations/:id` | Generation job status | path `id` |
| `DELETE /ai-gateway/generations/:id` | Cancel a generation job | path `id` |

```bash
curl -s "${auth[@]}" -X POST "$BASE/ai-gateway/chat/completions" \
  -d '{"model":"<modelId>","messages":[{"role":"user","content":"Summarize churn drivers"}]}'

# Video/music are async: create returns a job id, then poll.
ID=$(curl -s "${auth[@]}" -X POST "$BASE/ai-gateway/generations/videos" \
  -d '{"model":"<modelId>","prompt":"a rotating product render"}' | jq -r '.data.id')
poll "$BASE/ai-gateway/generations/$ID"
```

Checklist: `model` must be a real gateway model id; use `POST /ai-gateway/tokenize` (returns
`count` and `max_model_len`) to keep prompt + `max_tokens` inside the context
window; video and music generation are async, poll `GET /ai-gateway/generations/:id`.
Model discovery, provider keys, and guardrails: `references/ai-gateway.md`.

---

## Checklist
- [ ] Every training call is async: poll `/status` to a terminal state; never read results off the create call.
- [ ] On a `failed` job, fetch `/logs` (AutoML, fine-tuning) or the result's error before reporting; no fabricated success.
- [ ] AutoML: always send `hardware` (`cpu_count`, `memory_gb`, `disk_gb`); pick the exact file and target column first.
- [ ] Drift and model evaluation: `references/drift.md` and `references/model-evaluation.md` (not duplicated here).
- [ ] Fine-tuning: HuggingFace base models only; `validate-config` before `create`.
- [ ] Feature store: `apply` before reading; the data-plane calls require an organization.
- [ ] Registry/gateway overlap: promote and deploy point to `references/model-registry.md` and `references/ai-gateway.md`, not duplicated here.
