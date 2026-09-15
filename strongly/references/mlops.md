# MLOps

The Strongly **MLOps** surface is the model lifecycle over one REST API: train
models with **AutoML**, track runs as **experiments**, watch production models
with **drift detection**, adapt open models with **fine-tuning**, serve features
from the **feature store**, and run **inference** through the gateway.

Read this when the task is: training a tabular/timeseries model without writing
training code, comparing training runs, logging predictions and ground truth to
catch model decay, fine-tuning a self-hosted HuggingFace model, reading online or
historical features, or calling a model for chat/embeddings/audio/images.

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key:
$STRONGLY_API_KEY"` to `$HOST/api/v1`; inside Strongly the bearer is auto-injected
at `$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever applies, and every
example assumes the auth header is set:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
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
| `GET /automl/stats` | Totals (active/completed/failed, cost, accuracy) | none |
| `GET /automl/datasets` | List dataset volumes you can train on | none |
| `GET /automl/datasets/:id/files` | Files inside a volume (pick one to train on) | path `id` |
| `GET /automl/datasets/:id/columns` | Column headers of a file (pick target/features) | path `id`, `file` |
| `POST /automl/datasets/upload-url` | Presigned URL to upload a CSV | `filename`, `contentType?` |
| `POST /automl/datasets/import-from-datasource` | Server-side copy a CSV from an s3/minio/gcs/azure-blob data source | `datasourceId`, `objectKey`, `bucket?`, `filename?` |
| `GET /automl/jobs` | List jobs | `search`, `status`, `limit`, `offset`, `sortBy`, `sortOrder` |
| `POST /automl/jobs` | Create a training job | see below |
| `GET /automl/jobs/:id` | Full job (live-synced from trainer) | path `id` |
| `GET /automl/jobs/:id/status` | Lightweight lifecycle view (live-synced) | path `id` |
| `GET /automl/jobs/:id/metrics` | Leaderboard, best model, val score | path `id` |
| `GET /automl/jobs/:id/logs` | Trainer logs | path `id`, `lines?`, `since?` |
| `POST /automl/jobs/:id/stop` | Stop a running job | path `id` |
| `DELETE /automl/jobs/:id` | Delete a job | path `id` |
| `POST /automl/jobs/:id/deploy` | Register the best model in the model registry | path `id`, `registryName?` |

`POST /automl/jobs` required fields: `name`, `dataset`, `targetColumn`,
`hardware`. `hardware` is an object and has NO default: it must include
`cpu_count`, `memory_gb`, `disk_gb` (numbers), `gpu_count` optional. Optional:
`datasetFile` (when a volume has more than one file), `featureColumns`,
`problemType` (`tabular`|`multimodal`|`timeseries`), `predictorType`
(`auto`|`BinaryClassifier`|`MultiClassifier`|`Regressor`), `preset`
(`medium_quality` default, `good_quality`, `high_quality`, `best_quality`,
`optimize_for_deployment`), `timeLimit` (seconds, default 600), `metric`. The id
tools accept **either** the returned `job_id` or the Mongo `_id`.

```bash
# Create, then POLL to a terminal state before touching results. Active states:
# pending, preparing, running, training, evaluating. Terminal: completed | failed.
JOB=$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -X POST "$BASE/automl/jobs" -d '{
  "name":"churn-v1","dataset":"<volumeId-or-s3Path>","targetColumn":"churned",
  "problemType":"tabular","preset":"high_quality","timeLimit":900,
  "hardware":{"cpu_count":4,"memory_gb":16,"disk_gb":50}
}' | jq -r '.data.job_id')

poll "$BASE/automl/jobs/$JOB/status"
# On failure, read logs; do NOT report success:
curl -s "${auth[@]}" "$BASE/automl/jobs/$JOB/logs?lines=200" | jq -r '.data'
# On success, inspect the leaderboard then promote the winner:
curl -s "${auth[@]}" "$BASE/automl/jobs/$JOB/metrics" | jq '.data.leaderboard'
curl -s "${auth[@]}" -X POST "$BASE/automl/jobs/$JOB/deploy" -d '{"registryName":"churn-model"}'
```

Checklist: pick the exact file (`/files`) and target (`/columns`) before create;
always send `hardware`; poll `/status` to `completed`; on `failed` read `/logs`;
deploy only a completed job. Registry details: `references/model-registry.md`.

---

## 2. Experiments  (scope `ml-workbench:read` / `ml-workbench:write`)

An experiment is a **tracking record** that groups training runs and logs their
params, metrics, and artifacts. It creates no filesystem, volume, or compute (to
launch a dev environment use a workspace; this only tracks runs). The AutoML
trainer writes to these automatically; you also drive them directly.

| Method + path | Does | Key params |
|---|---|---|
| `GET /experiments` | List | `search`, `status`, `tag`, `pinned`, `limit`, `offset`, `sortBy`, `sortOrder` |
| `GET /experiments/stats` | Totals (running/completed/failed/pinned) | none |
| `GET /experiments/compare` | Compare 2+ runs side by side | `ids` (comma-separated, min 2) |
| `POST /experiments` | Create a tracking record | `name`, `description?`, `parameters?`, `tags?` |
| `POST /experiments/register` | Create or find by name (idempotent) | `name`, `description?`, `tags?` |
| `GET /experiments/:id` | Get one | path `id` |
| `PUT /experiments/:id` | Update | path `id` |
| `DELETE /experiments/:id` | Delete | path `id` |
| `POST /experiments/:id/pin` | Pin | path `id` |
| `PUT /experiments/:id/tags` | Replace tags | path `id`, `tags` (array) |
| `POST /experiments/:id/metrics` | Append metrics to the run | path `id`, `metrics` (`[{key,value,step?}]`) |
| `POST /experiments/:id/params` | Merge params (upsert by key) | path `id`, `params` (object) |
| `POST /experiments/:id/artifacts` | Register or upload an artifact | path `id`, `name`, `s3_key?` or `content_base64?`, `path?`, `type?`, `content_type?`, `size?` |

```bash
EXP=$(curl -s "${auth[@]}" -X POST "$BASE/experiments/register" \
  -d '{"name":"churn-tuning","tags":["q3"]}' | jq -r '.data.experiment_id')
curl -s "${auth[@]}" -X POST "$BASE/experiments/$EXP/params" \
  -d '{"params":{"lr":0.001,"epochs":5}}'
curl -s "${auth[@]}" -X POST "$BASE/experiments/$EXP/metrics" \
  -d '{"metrics":[{"key":"val_accuracy","value":0.91,"step":5}]}'
curl -s "${auth[@]}" "$BASE/experiments/compare?ids=$EXP,<otherId>" | jq '.data'
```

Checklist: `register` (not `create`) when you may re-run and want one record; log
`params` before, `metrics` during; upload the model as an artifact when done;
`compare` needs at least two ids.

---

## 3. Drift detection  (scope `mlops:read` / `mlops:write`)

Log production predictions and later the real outcomes, keep a training baseline,
then run analysis to detect input, output, and performance drift. `modelId` is a
model id from the model registry.

| Method + path | Does | Key params |
|---|---|---|
| `POST /drift/predictions` | Log a production prediction | `modelId`, `features`, `prediction`, `entityId?`, `probabilities?`, `modelVersion?`, `latencyMs?` |
| `GET /drift/predictions` | List logged predictions | `modelId`, `limit?`, `offset?`, `startDate?`, `endDate?`, `hasGroundTruth?` |
| `GET /drift/predictions/unmatched` | Predictions still lacking an outcome | `modelId`, `limit?` |
| `POST /drift/ground-truth` | Add one actual outcome (matched by `entityId`) | `modelId`, `entityId`, `actualOutcome`, `outcomeTimestamp?` |
| `POST /drift/ground-truth/batch` | Bulk upload outcomes | `modelId`, `records` (`[{entityId,actualOutcome,outcomeTimestamp?}]`) |
| `POST /drift/baselines` | Create a reference baseline from training data | `modelId`, `version`, `featureData`, `targetData?`, `labeledPredictions?` |
| `GET /drift/baselines` | List baselines | `modelId` |
| `GET /drift/baselines/active` | Get the active baseline | `modelId` |
| `PUT /drift/baselines/:id/activate` | Make a baseline active | path `id`, `modelId` |
| `POST /drift/analyze` | Run analysis (spawns a K8s job) | `modelId`, `windowDays?`, `windowStart?`, `windowEnd?` |
| `GET /drift/analyze/:id/status` | Analysis job status | path `id` (jobId), `modelId` |
| `GET /drift/results/latest` | Most recent result | `modelId` |
| `GET /drift/results` | Result history | `modelId`, `limit?`, `status?` (`ok`/`warning`/`alert`) |
| `GET /drift/performance` | Performance history over time | `modelId`, `windowDays?`, `granularity?` |
| `GET /drift/alerts` | Read alert config | `modelId` |
| `PUT /drift/alerts` | Update alert config + schedule | `modelId`, `enabled?`, `algorithms?`, `accuracyDropWarning?`, `accuracyDropAlert?`, `minBaselineSampleSize?`, `notifications?`, `schedule?` |

For **classification**, predictions MUST send a `probabilities` array (its max is
the confidence score CBPE uses), and a baseline's `labeledPredictions` needs at
least 30 aligned samples or it is rejected. Regression skips confidence capture.
`/drift/analyze` is async, poll its status.

```bash
curl -s "${auth[@]}" -X POST "$BASE/drift/predictions" -d '{
  "modelId":"<modelId>","entityId":"cust-42","prediction":"churn",
  "probabilities":[0.18,0.82],"features":{"tenure":8,"plan":"pro"}}'
curl -s "${auth[@]}" -X POST "$BASE/drift/ground-truth" \
  -d '{"modelId":"<modelId>","entityId":"cust-42","actualOutcome":"churn"}'

JOB=$(curl -s "${auth[@]}" -X POST "$BASE/drift/analyze" \
  -d '{"modelId":"<modelId>","windowDays":30}' | jq -r '.data.jobId // .data.id')
poll "$BASE/drift/analyze/$JOB/status?modelId=<modelId>"
curl -s "${auth[@]}" "$BASE/drift/results/latest?modelId=<modelId>" | jq '.data'
```

Checklist: baseline before analysis; classification predictions carry
`probabilities`; feed outcomes by `entityId` to unlock performance drift; poll the
analyze job; alerts and schedule live on one `PUT /drift/alerts`.

---

## 4. Fine-tuning  (scope `fine-tuning:read` / `fine-tuning:write`)

Adapt a **self-hosted HuggingFace** base model (LoRA by default). Third-party
vendor models (gpt-4o, claude, gemini) are NOT fine-tunable here. Size the config
with the read endpoints first, then submit and poll.

| Method + path | Does | Key params |
|---|---|---|
| `GET /fine-tuning/stats` | Summary stats | none |
| `GET /fine-tuning/base-models` | Fine-tunable base models | none |
| `GET /fine-tuning/hardware` | Hardware/GPU options | none |
| `GET /fine-tuning/model-requirements` | VRAM/hardware needs for a base model | `baseModel`, `method?` |
| `POST /fine-tuning/estimate-cost` | Estimate job cost | `baseModel`, `datasetSize` |
| `POST /fine-tuning/recommend` | Recommend a config | `baseModel`, `useCase?`, `datasetSize?` |
| `POST /fine-tuning/validate-config` | Pre-flight validation | `baseModel`, `method`, `hardware?`, `methodConfig?` |
| `GET /fine-tuning/jobs` | List jobs | `search`, `status`, `baseModel`, `limit`, `offset`, `sortBy`, `sortOrder` |
| `POST /fine-tuning/jobs` | Create a job | `name`, `baseModel`, `trainingDataset`, `description?` |
| `GET /fine-tuning/jobs/:id` | Full job (live-synced) | path `id` |
| `GET /fine-tuning/jobs/:id/status` | Lifecycle view (live-synced) | path `id` |
| `GET /fine-tuning/jobs/:id/metrics` | Training metrics | path `id` |
| `GET /fine-tuning/jobs/:id/logs` | Job logs | path `id`, `lines?`, `since?` |
| `POST /fine-tuning/jobs/:id/stop` | Stop a running job | path `id` |
| `POST /fine-tuning/jobs/:id/restart` | Restart a job | path `id` |
| `DELETE /fine-tuning/jobs/:id` | Delete a job | path `id` |
| `POST /fine-tuning/jobs/:id/deploy` | Deploy the trained model as a self-hosted endpoint | path `id` |

`baseModel` must be an id from `/base-models` (e.g. `meta-llama/Llama-2-7b-hf`);
`trainingDataset` is a prepared file (JSONL from a Data Forge export, a project
volume file path, or a URL/dataset id). Recommended flow:
`recommend` -> `validate-config` -> `create` -> poll -> `deploy`.

```bash
curl -s "${auth[@]}" "$BASE/fine-tuning/base-models" | jq '.data'
curl -s "${auth[@]}" -X POST "$BASE/fine-tuning/validate-config" \
  -d '{"baseModel":"meta-llama/Llama-2-7b-hf","method":"lora","hardware":{"gpu_type":"A100","gpu_count":1}}'

JOB=$(curl -s "${auth[@]}" -X POST "$BASE/fine-tuning/jobs" -d '{
  "name":"support-tone","baseModel":"meta-llama/Llama-2-7b-hf",
  "trainingDataset":"volumes/train.jsonl"}' | jq -r '.data.job_id // .data._id')

# Terminal states: completed | failed (active: queued, running).
poll "$BASE/fine-tuning/jobs/$JOB/status"
curl -s "${auth[@]}" "$BASE/fine-tuning/jobs/$JOB/logs?lines=200" | jq -r '.data'   # on failure
curl -s "${auth[@]}" -X POST "$BASE/fine-tuning/jobs/$JOB/deploy"                    # on success
```

Checklist: HuggingFace base model only; run `model-requirements` +
`validate-config` before create (avoid a wasted GPU job); poll `/status`; read
`/logs` on failure; deploying stands up a gateway endpoint, see
`references/ai-gateway.md`.

---

## 5. Feature store  (external auth: `X-API-Key`; an organization is required)

Register feature definitions and read features for training or serving. These
routes are REST-only (no agent tool wrappers). Data-plane calls delegate to the
platform feature-store service as the calling user, so pass the service's own
JSON body through unchanged.

| Method + path | Does |
|---|---|
| `GET /feature-store/stores` | List feature stores you can access |
| `GET /feature-store/stores/:id` | Get one store |
| `POST /feature-store/apply` | Register/update entities, views, services (dependency order) |
| `POST /feature-store/online-features` | Read low-latency online features for serving |
| `POST /feature-store/historical-features` | Point-in-time-correct features for training |
| `POST /feature-store/materialize` | Materialize features from offline to online store |
| `POST /feature-store/write` | Write feature values |
| `POST /feature-store/push` | Push features to the online store |

`apply` takes `store_id` (required) plus optional `entities`, `views`, `services`
arrays. The data-plane bodies (feature refs, entity rows, time ranges) are the
feature-store service's own contract and are forwarded verbatim; discover a
store's entities and views with `GET /feature-store/stores/:id`.

```bash
STORE=$(curl -s "${auth[@]}" "$BASE/feature-store/stores" | jq -r '.data[0]._id')
curl -s "${auth[@]}" -X POST "$BASE/feature-store/apply" \
  -d '{"store_id":"'"$STORE"'","entities":[...],"views":[...],"services":[...]}'
curl -s "${auth[@]}" -X POST "$BASE/feature-store/online-features" \
  -d '{"store_id":"'"$STORE"'", ... }'   # body per the feature-store service contract
```

Checklist: `apply` before you read; use `online-features` for serving and
`historical-features` for training; `materialize` fills the online store; a call
without an organization is rejected.

---

## 6. Inference  (scope `ai-gateway:inference`)

Call any model wired through the gateway with an OpenAI-shaped body. `model` is a
gateway model id (list them via `references/ai-gateway.md`). All accept
`"stream": true` where a streamed SSE response makes sense.

| Method + path | Does | Key params |
|---|---|---|
| `POST /ai/chat/completions` | Chat completion | `model`, `messages`, `stream?`, `temperature?`, `max_tokens?` |
| `POST /ai/completions` | Text completion | `model`, `prompt`, `stream?`, `temperature?`, `max_tokens?` |
| `POST /ai/embeddings` | Embeddings | `model`, `input` |
| `POST /ai/rerank` | Rerank documents by relevance | `model`, `query`, `documents` |
| `POST /ai/moderations` | Content moderation | `input`, `model?` |
| `POST /ai/tokenize` | Token count + model max context | `model`, `prompt` |
| `POST /ai/audio/speech` | Text-to-speech (binary audio out) | `model`, `input`, `voice?` |
| `GET /ai/audio/speech/voices` | List TTS voices | none |
| `POST /ai/audio/transcriptions` | Speech-to-text (multipart file upload) | `model`, `file`, `language?` |
| `POST /ai/audio/translations` | Speech-to-English (multipart file upload) | `model`, `file` |
| `POST /ai/generations/images` | Image generation | `model`, `prompt`, `n?`, `size?` |
| `POST /ai/generations/videos` | Video generation (async job) | `model`, `prompt` |
| `POST /ai/generations/music` | Music generation (async job) | `model`, `prompt` |
| `POST /ai/generations` | Unified image/video/music generation | `model`, `prompt`, `type?` |
| `GET /ai/generations/:id` | Generation job status | path `id` |
| `DELETE /ai/generations/:id` | Cancel a generation job | path `id` |

```bash
curl -s "${auth[@]}" -X POST "$BASE/ai/chat/completions" \
  -d '{"model":"<modelId>","messages":[{"role":"user","content":"Summarize churn drivers"}]}'

# Video/music are async: create returns a job id, then poll.
ID=$(curl -s "${auth[@]}" -X POST "$BASE/ai/generations/videos" \
  -d '{"model":"<modelId>","prompt":"a rotating product render"}' | jq -r '.data.id')
poll "$BASE/ai/generations/$ID"
```

Checklist: `model` must be a real gateway model id; use `/ai/tokenize` (returns
`count` and `max_model_len`) to keep prompt + `max_tokens` inside the context
window; video and music generation are async, poll `GET /ai/generations/:id`.
Model discovery, provider keys, and guardrails: `references/ai-gateway.md`.

---

## Checklist
- [ ] Every training call is async: poll `/status` to a terminal state; never read results off the create call.
- [ ] On a `failed` job, fetch `/logs` (AutoML, fine-tuning) or the result's error before reporting; no fabricated success.
- [ ] AutoML: always send `hardware` (`cpu_count`, `memory_gb`, `disk_gb`); pick the exact file and target column first.
- [ ] Drift: classification predictions carry `probabilities`; baseline `labeledPredictions` needs 30+ samples; feed ground truth by `entityId`.
- [ ] Fine-tuning: HuggingFace base models only; `validate-config` before `create`.
- [ ] Feature store: `apply` before reading; an organization is required.
- [ ] Registry/gateway overlap: promote and deploy point to `references/model-registry.md` and `references/ai-gateway.md`, not duplicated here.
