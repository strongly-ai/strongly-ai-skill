# AI Gateway

The Strongly **AI Gateway** puts every model behind one endpoint. You register
models (both **third-party** provider models like OpenAI or Anthropic, and
**self-hosted** models the platform deploys on Kubernetes), store the provider
keys, and then call any of them with the same request shape. The gateway adds
guardrails, semantic caching, and usage analytics (requests and tokens) on top.

Read this when the task is: listing or registering models, storing/testing a
provider API key, calling a model (chat, completions, embeddings, audio, image/
video/music, moderation, rerank, tokenize), deploying and waking a self-hosted
model, or reading guardrail and analytics data.

**Auth** follows `SKILL.md`. Outside Strongly send `-H "X-API-Key:
$STRONGLY_API_KEY"` to `$HOST/api/v1`; inside Strongly the bearer is
auto-injected against `$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever
applies, and `auth=(-H "X-API-Key: $STRONGLY_API_KEY")` outside Strongly.

**Scopes.** Reads need `ai-gateway:read`, writes need `ai-gateway:write`, model
calls need `ai-gateway:inference`, and guardrail routes need `guardrails:read` /
`guardrails:write`. A missing scope returns `403 scope-required`; add the scope,
do not work around it.

**See also.** To train or fine-tune a model, see `references/mlops.md`. A/B
tests, drift and prediction records are for model registry models, not these
gateway models: `references/ab-testing.md`, `references/drift.md`.

---

## 1. Models: list what the user actually has, first

Do not assume a model or hardcode a model name. **List the user's configured
models** and pick a real `_id`. Every inference call in section 4 takes a model
`_id` (or its `vendorModelId`), so this is always the first step.

```bash
# What is configured, and the third-party vs self-hosted split
curl -s "${auth[@]}" "$BASE/ai-gateway/models/overview" | jq '.data'
#   { total, active, deploying, stopped, failed, thirdParty, selfHosted }

# List models (paginated). Filter and search to narrow.
curl -s "${auth[@]}" "$BASE/ai-gateway/models?type=third-party&status=active" | jq '.data[] | {_id,name,provider,type,status,modelType}'
curl -s "${auth[@]}" "$BASE/ai-gateway/models?type=self-hosted"               | jq '.data[] | {_id,name,status,deploymentConfig}'
curl -s "${auth[@]}" "$BASE/ai-gateway/models?q=embed&modelType=embedding" | jq '.data'
curl -s "${auth[@]}" "$BASE/ai-gateway/models?modelType=chat,multimodal,completion" | jq '.data'   # the models an agent can run on
```

- `type` is `third-party` or `self-hosted`. That is the load-bearing
  distinction: a **third-party** model calls out to a provider (needs a provider
  key, section 2) and activates instantly; a **self-hosted** model runs as a pod
  the platform builds and may need a spin-up before it answers (section 3).
- `status` is one of `active`, `deploying`, `stopped`, `failed`, `inactive`.
- The list omits build/deploy logs and the Dockerfile; `GET /ai-gateway/models/:id`
  returns the full detail document.

**Discovery of what you can add** (drive pickers from these, never a hardcoded
vendor or model list):

```bash
curl -s "${auth[@]}" "$BASE/ai-gateway/models/providers"            | jq '.data'   # distinct third-party providers + counts
curl -s "${auth[@]}" "$BASE/ai-gateway/models/certified?provider=openai" | jq '.data' # curated third-party catalog
curl -s "${auth[@]}" "$BASE/ai-gateway/models/prebuilt?category=llm" | jq '.data'   # self-hosted prebuilt templates, each with its certifiedEnvironment
```

**Register a model.** `name`, `type`, `provider`, and `vendorModelId` are
required. `modelType` (chat, multimodal, embedding, ...) comes from the
certified catalog or a prebuilt template; for a model neither records, send
it, or the create is refused. A chat model records `contextWindow` and
`maxOutputTokens` the same way. A saved provider key is given by `apiKeyId`
only when you may use that key (yours, or any key for a platform admin); a
key you may not use is refused as not found. `cache_config` optionally
enables the response, semantic and prompt caches (prompt caching on any chat
or multimodal model certified for it).

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/models" \
  -d '{"name":"GPT-6.1 Sol","type":"third-party","provider":"openai","vendorModelId":"gpt-6.1-sol",
       "cache_config":{"semantic_cache_enabled":true,"semantic_cache_threshold":0.9,"semantic_cache_ttl":3600}}' \
  | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /ai-gateway/models/overview` | Counts: `total`, `active`/`deploying`/`stopped`/`failed`, `thirdParty`/`selfHosted`, and `byStatus`, `byType`, `byProvider` rows (`{ <field>, total }`, most first) | `ai-gateway:read` |
| `GET /ai-gateway/models` | List (`q`, `type`, `status`, `provider`, `modelType`, `limit`, `cursor`, `sort`) | `ai-gateway:read` |
| `GET /ai-gateway/models/providers` | Distinct third-party providers + counts | `ai-gateway:read` |
| `GET /ai-gateway/models/certified` | Curated third-party catalog (`provider`, `modelType`, `capability`) | `ai-gateway:read` |
| `GET /ai-gateway/models/prebuilt` | Self-hosted prebuilt templates (`category`, `provider`), each with its `certifiedEnvironment` (`modelType`, `engine`, `port`, `instanceType`, `resources`, a chat model's `contextWindow`, `maxOutputTokens`, `limitsSource`): a deploy records these, never enter them | `ai-gateway:read` |
| `POST /ai-gateway/models` | Create (`name`, `type`, `provider`, `vendorModelId`, `modelType`, `contextWindow`, `maxOutputTokens`, `apiKey` or `apiKeyId`, `cache_config`) | `ai-gateway:write` |
| `GET /ai-gateway/models/:id` | Full model detail | `ai-gateway:read` |
| `GET /ai-gateway/models/:id/options` | Model options (voices, languages, ...) | `ai-gateway:read` |
| `PATCH /ai-gateway/models/:id` | Update name/description/parameters/`cache_config` | `ai-gateway:write` |
| `DELETE /ai-gateway/models/:id/cache` | Clear the model's cached responses (response cache and semantic cache) | `ai-gateway:write` |
| `DELETE /ai-gateway/models/:id` | Delete the model | `ai-gateway:write` |
| `GET /ai-gateway/models/:id/metrics` | Usage/latency metrics | `ai-gateway:read` |
| `GET /ai-gateway/models/:id/time-series` | Requests, errors, tokens and mean latency over time, those you may count; `window` `24h` (hourly points) or `7d`/`30d` (daily UTC points, the default `30d`); answers `{window, granularity, start, end, points[{timestamp, …}]}`, every bucket a point, a quiet one zero | `ai-gateway:read` |
| `GET /ai-gateway/models/:id/permissions` · `PUT .../permissions` | Read / set `isShared`, `sharedWith` | read / write |

---

## 2. Provider keys (third-party models)

A third-party model needs a provider API key on file. The key value is sent
**only** on the create call and is never returned by any read route (list and
get expose name, provider, status, and test metadata, never the secret). Do not
put the key in a URL or log it.

```bash
# Store a key (name, provider, apiKey required; description optional)
KEY_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/provider-keys" \
  -d '{"name":"OpenAI prod","provider":"openai","apiKey":"'"$OPENAI_KEY"'","description":"team key"}' \
  | jq -r '.data._id')

# Verify it actually works (calls the provider; records lastTestedAt + testResult)
curl -s -X POST "${auth[@]}" "$BASE/ai-gateway/provider-keys/$KEY_ID/test" | jq '.data'

# List / inspect (never returns the key value)
curl -s "${auth[@]}" "$BASE/ai-gateway/provider-keys?provider=openai&status=active" | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /ai-gateway/provider-keys` | List (`q`, `provider`, `status`, paging) | `ai-gateway:read` |
| `POST /ai-gateway/provider-keys` | Create (`name`, `provider`, `apiKey`, `description`) | `ai-gateway:write` |
| `GET /ai-gateway/provider-keys/:id` | Get one (no secret) | `ai-gateway:read` |
| `PATCH /ai-gateway/provider-keys/:id` | Update | `ai-gateway:write` |
| `DELETE /ai-gateway/provider-keys/:id` | Delete | `ai-gateway:write` |
| `POST /ai-gateway/provider-keys/:id/test` | Test the stored key: the gateway lists the provider's models with it (no model is called) | `ai-gateway:read` |

---

## 3. Self-hosted models: deploy, spin-up, status

A self-hosted model runs as a Kubernetes pod. It is an async resource: `deploy`
returns immediately and the pod finishes later, and a model can be **stopped or
scaled to zero**, so **poll status before you rely on it** (Golden Rule 3).

```bash
# Deploy (build image + run pod). Instance type comes from the body or the
# model/template's recommendedInstance; there is no silent default.
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/models/$ID/deploy" \
  -d '{"instance_type":"g5.xlarge","gpu":1,"replicas":1}' | jq '.data.status'

# Poll until it is serving. For self-hosted this queries the live deployment.
curl -s "${auth[@]}" "$BASE/ai-gateway/models/$ID/status" | jq '.data'   # -> status: deploying -> active
```

**Always-on vs on-demand** (chosen at deploy):

- **Always-on** (default): replicas stay up, no cold start, runs 24/7. For
  steady or latency-sensitive traffic. Add `autoscaling`
  (`{ enabled, minReplicas, maxReplicas, cpuThreshold }`) for variable load.
- **On-demand**: set `auto_shutdown_minutes` > 0. The pod scales to zero after
  that idle window and **wakes on the next inference call with a cold start**.
  Best for bursty or occasional use (for example a model only called inside
  workflow runs). `auto_shutdown_minutes` and `autoscaling` are mutually
  exclusive.

For an on-demand model that has scaled to zero, either let the first inference
call wake it (that call pays the cold start) or `POST /ai-gateway/models/:id/start` and
poll `/status` until `active` first. Third-party models have no pod: `deploy`/
`start` just activate them and `status` comes from the database.

| Method / path | Does | Scope |
|---|---|---|
| `POST /ai-gateway/models/:id/deploy` | Deploy self-hosted (build+run) or activate third-party. Body: `instance_type`, `port`, `replicas`, `volume_size`, `gpu`, `cpu`, `memory`, `auto_shutdown_minutes`, `autoscaling`, `env_vars`, `useSpot` (spot capacity) with `spotFallback` (default true: on-demand when no spot is available; false waits for spot) | `ai-gateway:write` |
| `PATCH /ai-gateway/models/:id/resources` | Change a deployed self-hosted model in place: `cpu`, `memory`, `disk`, `gpu`, and/or `useSpot` + `spotFallback` (moves it on or off spot); it restarts, never redeploys | `ai-gateway:write` |
| `POST /ai-gateway/models/:id/start` | Start a stopped model | `ai-gateway:write` |
| `POST /ai-gateway/models/:id/stop` | Stop self-hosted pod / deactivate third-party | `ai-gateway:write` |
| `POST /ai-gateway/models/:id/restart` | Restart a running self-hosted model (its instances roll); `409` for a third-party model | `ai-gateway:write` |
| `GET /ai-gateway/models/:id/status` | Live deployment status (self-hosted) or db status (third-party) | `ai-gateway:read` |
| `GET /ai-gateway/models/:id/logs` | A self-hosted model's log entries (`type`: build, deployment or runtime; `lines`, `since`, `container`); a third-party model is 409 | `ai-gateway:read` |
| `GET /ai-gateway/models/:id/metrics` | Runtime metrics | `ai-gateway:read` |

---

## 4. Calling a model (inference)

One request shape for every model, third-party or self-hosted. Pass the model
`_id` (from section 1) as `model`. Set `stream: true` to receive an SSE stream.

```bash
# Chat completion
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/chat/completions" \
  -d '{"model":"'"$ID"'","messages":[{"role":"user","content":"Summarize this quarter."}],"max_tokens":300}' \
  | jq '.choices[0].message.content'

# Streaming (SSE)
curl -sN -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/chat/completions" \
  -d '{"model":"'"$ID"'","messages":[{"role":"user","content":"Write a haiku."}],"stream":true}'

# Images and PDFs: a user message's content is an array of OpenAI chat parts.
# An image needs a model with capabilityConfig.supportsVision; a PDF (type "file",
# file_data a data: URL) needs capabilityConfig.supportsPdf, else 400 naming the model.
# A router sends them only to a member that declares them (400 when none does).
# Self-hosted models declare supportsVision from their Hugging Face image processor.
IMG=$(base64 < chart.png | tr -d '\n'); PDF=$(base64 < report.pdf | tr -d '\n')
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/chat/completions" \
  -d '{"model":"'"$ID"'","messages":[{"role":"user","content":[
        {"type":"text","text":"What do the chart and the report say?"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,'"$IMG"'"}},
        {"type":"file","file":{"filename":"report.pdf","file_data":"data:application/pdf;base64,'"$PDF"'"}}]}]}' \
  | jq '.choices[0].message.content'

# Embeddings
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/embeddings" \
  -d '{"model":"'"$EMBED_ID"'","input":"text to embed"}' | jq '.data[0].embedding | length'

# Token count + context window (the reliable way to size a prompt)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/tokenize" \
  -d '{"model":"'"$ID"'","prompt":"how many tokens is this"}' | jq '{count,max_model_len}'
```

| Method / path | Does | Notes |
|---|---|---|
| `POST /ai-gateway/chat/completions` | Chat completion | `model`, `messages` (a user `content` may be parts: `text`, `image_url`, `file` for a PDF), `stream`, `temperature`, `max_tokens` |
| `POST /ai-gateway/completions` | Text completion | `model`, `prompt`, `stream`, ... |
| `POST /ai-gateway/embeddings` | Embeddings | `model`, `input` |
| `POST /ai-gateway/audio/speech` | Text to speech (returns binary audio) | `model`, `input`, `voice` |
| `GET /ai-gateway/audio/speech/voices` | List TTS voices | |
| `POST /ai-gateway/audio/transcriptions` | Speech to text (multipart file upload) | `model`, `file`, `language` |
| `POST /ai-gateway/audio/translations` | Speech to English text (multipart) | `model`, `file` |
| `POST /ai-gateway/audio/speech-to-speech` | Voice changer: an audio clip spoken in another voice (multipart, returns binary audio) | `model`, `file`, `voice`, `output_format` (`mp3_44100_128`, `pcm_16000`, ...) |
| `POST /ai-gateway/ocr` | A document's or image's text as markdown per page (Mistral OCR wire format) | `model`, `document` (`{type: document_url, document_url}` or `{type: image_url, image_url}`, a link or `data:` URL) |
| `POST /ai-gateway/generations/images` | Image generation | `model`, `prompt`, `n`, `size` |
| `POST /ai-gateway/generations/videos` · `/music` | Video / music generation (async job) | `model`, `prompt` |
| `POST /ai-gateway/generations` | Unified generation (async job) | `model`, `prompt`, `type` (required: image, video or music), `parameters?` |
| `GET /ai-gateway/generations/:id` · `DELETE /ai-gateway/generations/:id` | Poll / cancel a generation job | |
| `POST /ai-gateway/moderations` | Content moderation | `model`, `input` |
| `POST /ai-gateway/rerank` | Rerank documents by relevance | `model`, `query`, `documents` |
| `POST /ai-gateway/tokenize` | Token count + `max_model_len` | `model`, `prompt` |

All inference routes need scope `ai-gateway:inference`. Video and music
generation return an async job: poll `GET /ai-gateway/generations/:id` until it
completes.

A `503` means the call was not run (the model is starting, every replica is busy,
or the gateway replica was stopping before it sent it): send it again. A `502`
whose detail opens `Response lost:` means the call reached the model and its
answer was lost; the model may already have run it, so nothing sends it again
(the gateway, a workflow node, an agent): do not resend it blindly; tell the user.

---

**Who may call a model.** The gateway lets a caller use only models it owns,
models shared with it (Can edit / Can use), "Allow all users" models and
platform models (admins reach all). Anything else is refused with 403 naming
the model, including a model saved in a workflow before it was unshared.
Workflows, apps and agents call as their owner; a router must be one the caller
may use and calls its members as the router's owner. A router answers chats
and completions only, so its members are chat, multimodal or completion
models (any other type is refused when the router is saved), and it needs at
least one (a router without members is refused). Pick models from
`GET /ai-gateway/models` (section 1: what the user may use), never a hard-coded id.
With `healthCheck.enabled`, each member has a circuit in the router, shared by
every gateway replica: `failureThreshold` failures in a row open it (no traffic),
`intervalSeconds` later it lets `recoveryThreshold` test requests through, and that
many successes close it (a failure reopens it). Read it from
`GET /ai-gateway/routers/:id/stats` (`members[].circuit.state`: closed, open, half_open).

## 5. Guardrails

Guardrails are rules applied to a model's inputs and outputs: PII, data leak
prevention, keyword filters (toxicity, prompt injection, content, profanity),
token limits, rate limits, and a hallucination detector (output: a judge chat model checks the
answer's claims against the request's own messages; `config.output` is `{enabled,
judge_model_id, threshold, action: block|log}`, the threshold the least share of supported
claims that passes). A model's guardrails are `enabled` plus a list of
`rules`; each rule is `{id, template, name, enabled, priority, config}`, where
`template` is an available id from `GET /ai-gateway/guardrails/templates` and `config` holds
that template's settings per direction (`input`, `output`), or the rate
limiter's limits. A rule the gateway cannot enforce is refused with the reason.
Dry-run the rules on sample text before saving them.

```bash
curl -s "${auth[@]}" "$BASE/ai-gateway/guardrails/templates" | jq '.data'   # template ids, directions, available
curl -s "${auth[@]}" "$BASE/ai-gateway/guardrails"    | jq '.data'   # models + guardrail status

RULES='[{"id":"r1","template":"toxicity-filter","name":"Toxicity","enabled":true,"priority":1,
  "config":{"input":{"enabled":true,"keywords":["idiot"],"regex_patterns":[],
  "case_sensitive":false,"action":"block","replacement_text":""}}}]'

# Dry-run the rules on sample text (no model call, nothing recorded)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/models/$ID/guardrails/test" \
  -d '{"direction":"input","input":"you idiot","rules":'"$RULES"'}' | jq '.data'

# Save the full desired state (enabled and rules both required)
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai-gateway/models/$ID/guardrails" \
  -d '{"enabled":true,"rules":'"$RULES"'}' | jq '.data'

# What the model's guardrails did
curl -s "${auth[@]}" "$BASE/ai-gateway/models/$ID/guardrail-logs?limit=50" | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /ai-gateway/guardrails` | Models with guardrail status | `guardrails:read` |
| `GET /ai-gateway/models/:id/guardrails` | A model's guardrail config | `guardrails:read` |
| `PUT /ai-gateway/models/:id/guardrails` | Replace the guardrails (`enabled` and `rules`, both required) | `guardrails:write` |
| `PATCH /ai-gateway/models/:id/guardrails` | Turn enforcement on or off (`enabled`) | `guardrails:write` |
| `GET /ai-gateway/guardrails/templates` | Built-in rule templates | `guardrails:read` |
| `POST /ai-gateway/models/:id/guardrails/test` | Dry-run (`input`, `direction`, `rules`, all required; `grounding`, the context, with a `hallucination-detector` rule) | `guardrails:write` |
| `GET /ai-gateway/models/:id/guardrails/judge-models` | Chat models that may judge the model's answers (a Hallucination Detector's `judge_model_id`) | `guardrails:read` |
| `GET /ai-gateway/models/:id/guardrail-logs` | What a model's guardrails did, newest first (`limit`, `cursor`) | `guardrails:read` |
| `GET /ai-gateway/guardrails/statistics` | Aggregate guardrail stats | `guardrails:read` |

---

## 6. Analytics

Usage and performance for the gateway, in requests and tokens (no price is put
on tokens). Every route requires `dateRange`: `24h`, `7d`, `30d` or `90d`.

```bash
curl -s "${auth[@]}" "$BASE/ai-gateway/analytics/usage?dateRange=30d"                         | jq '.data'
curl -s "${auth[@]}" "$BASE/ai-gateway/analytics/performance?dateRange=30d&modelId=$ID"       | jq '.data'
curl -s "${auth[@]}" "$BASE/ai-gateway/analytics/time-series?dateRange=7d&granularity=daily"  | jq '.data'
curl -s "${auth[@]}" "$BASE/ai-gateway/analytics/providers?dateRange=90d"                     | jq '.data'
# One model's use by day (window 24h hourly, 7d or 30d daily), the requests you may count:
curl -s "${auth[@]}" "$BASE/ai-gateway/models/$ID/time-series?window=30d"                    | jq '.data.points'
```

| Method / path | Does | Params |
|---|---|---|
| `GET /ai-gateway/analytics/usage` | The range's totals: requests, tokens, latency, error rate, users, models | `dateRange`, `modelId` |
| `GET /ai-gateway/analytics/performance` | Latency per model (avg, min, max, p95, p99) | `dateRange`, `modelId` |
| `GET /ai-gateway/analytics/time-series` | Requests, tokens, latency, errors per provider per period | `dateRange`, `granularity` (required: `hourly` with `24h` only, or `daily`), `provider` |
| `GET /ai-gateway/analytics/providers` | Per-provider models, requests, tokens, latency, users | `dateRange` |

All analytics routes need scope `ai-gateway:read`.

---

## Checklist
- [ ] List the user's real models (`GET /ai-gateway/models`) and pick an `_id`; never hardcode a model name.
- [ ] Know each model's `type`: third-party needs a provider key; self-hosted may need a spin-up.
- [ ] Provider key value is sent only on `POST /ai-gateway/provider-keys`; never in a URL or log; verify with `/test`.
- [ ] Before relying on a self-hosted model, poll `GET /ai-gateway/models/:id/status` until `active`; on-demand models cold-start on the first call.
- [ ] Same request shape for all inference; pass the model `_id` as `model`; add `stream:true` for SSE.
- [ ] Guardrails: dry-run the rules with `POST /ai-gateway/models/:id/guardrails/test`, then save `enabled` + `rules` with `PUT /ai-gateway/models/:id/guardrails`.
- [ ] Report the real status and the problem `detail` on failure; do not fabricate a completion.
