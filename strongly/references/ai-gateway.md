# AI Gateway

The Strongly **AI Gateway** puts every model behind one endpoint. You register
models (both **third-party** provider models like OpenAI or Anthropic, and
**self-hosted** models the platform deploys on Kubernetes), store the provider
keys, and then call any of them with the same request shape. The gateway adds
guardrails, semantic caching, and usage/cost analytics on top.

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

---

## 1. Models: list what the user actually has, first

Do not assume a model or hardcode a model name. **List the user's configured
models** and pick a real `_id`. Every inference call in section 4 takes a model
`_id` (or its `vendorModelId`), so this is always the first step.

```bash
# What is configured, and the third-party vs self-hosted split
curl -s "${auth[@]}" "$BASE/ai/models/overview" | jq '.data'
#   { total, active, deploying, stopped, failed, thirdParty, selfHosted }

# List models (paginated). Filter and search to narrow.
curl -s "${auth[@]}" "$BASE/ai/models?type=third-party&status=active" | jq '.data[] | {_id,name,provider,type,status,modelType}'
curl -s "${auth[@]}" "$BASE/ai/models?type=self-hosted"               | jq '.data[] | {_id,name,status,deploymentConfig}'
curl -s "${auth[@]}" "$BASE/ai/models?search=embed&modelType=embedding" | jq '.data'
```

- `type` is `third-party` or `self-hosted`. That is the load-bearing
  distinction: a **third-party** model calls out to a provider (needs a provider
  key, section 2) and activates instantly; a **self-hosted** model runs as a pod
  the platform builds and may need a spin-up before it answers (section 3).
- `status` is one of `active`, `deploying`, `stopped`, `failed`, `inactive`.
- The list omits build/deploy logs and the Dockerfile; `GET /ai/models/:id`
  returns the full detail document.

**Discovery of what you can add** (drive pickers from these, never a hardcoded
vendor or model list):

```bash
curl -s "${auth[@]}" "$BASE/ai/models/providers"            | jq '.data.providers'   # distinct third-party providers + counts
curl -s "${auth[@]}" "$BASE/ai/models/certified?provider=openai" | jq '.data.models' # curated third-party catalog
curl -s "${auth[@]}" "$BASE/ai/models/prebuilt?category=llm" | jq '.data.templates'   # self-hosted prebuilt templates
```

**Register a model.** `name`, `type`, `provider`, and `vendorModelId` are
required. `cache_config` optionally enables semantic caching.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/models" \
  -d '{"name":"GPT-4o","type":"third-party","provider":"openai","vendorModelId":"gpt-4o",
       "cache_config":{"semantic_cache_enabled":true,"semantic_cache_threshold":0.9,"semantic_cache_ttl":3600}}' \
  | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /ai/models/overview` | Counts by status and type | `ai-gateway:read` |
| `GET /ai/models` | List (`search`, `type`, `status`, `provider`, `modelType`, `limit`, `offset`, `sort`) | `ai-gateway:read` |
| `GET /ai/models/providers` | Distinct third-party providers + counts | `ai-gateway:read` |
| `GET /ai/models/certified` | Curated third-party catalog (`provider`, `modelType`, `capability`) | `ai-gateway:read` |
| `GET /ai/models/prebuilt` | Self-hosted prebuilt templates (`category`, `provider`) | `ai-gateway:read` |
| `POST /ai/models` | Create (`name`, `type`, `provider`, `vendorModelId`, `cache_config`) | `ai-gateway:write` |
| `GET /ai/models/:id` | Full model detail | `ai-gateway:read` |
| `GET /ai/models/:id/options` | Model options (voices, languages, ...) | `ai-gateway:read` |
| `PUT /ai/models/:id` | Update name/description/parameters/`cache_config` | `ai-gateway:write` |
| `DELETE /ai/models/:id/cache` | Clear the model's semantic cache | `ai-gateway:write` |
| `DELETE /ai/models/:id` | Delete the model | `ai-gateway:write` |
| `GET /ai/models/:id/metrics` | Usage/latency metrics | `ai-gateway:read` |
| `GET /ai/models/:id/permissions` · `PUT .../permissions` | Read / set `isShared`, `sharedWith` | read / write |

---

## 2. Provider keys (third-party models)

A third-party model needs a provider API key on file. The key value is sent
**only** on the create call and is never returned by any read route (list and
get expose name, provider, status, and test metadata, never the secret). Do not
put the key in a URL or log it.

```bash
# Store a key (name, provider, apiKey required; description optional)
KEY_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/provider-keys" \
  -d '{"name":"OpenAI prod","provider":"openai","apiKey":"'"$OPENAI_KEY"'","description":"team key"}' \
  | jq -r '.data._id')

# Verify it actually works (calls the provider; records lastTestedAt + testResult)
curl -s -X POST "${auth[@]}" "$BASE/ai/provider-keys/$KEY_ID/test" | jq '.data'

# List / inspect (never returns the key value)
curl -s "${auth[@]}" "$BASE/ai/provider-keys?provider=openai&status=active" | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /ai/provider-keys` | List (`search`, `provider`, `status`, paging) | `ai-gateway:read` |
| `POST /ai/provider-keys` | Create (`name`, `provider`, `apiKey`, `description`) | `ai-gateway:write` |
| `GET /ai/provider-keys/:id` | Get one (no secret) | `ai-gateway:read` |
| `PUT /ai/provider-keys/:id` | Update | `ai-gateway:write` |
| `DELETE /ai/provider-keys/:id` | Delete | `ai-gateway:write` |
| `POST /ai/provider-keys/:id/test` | Test the stored key against the provider | `ai-gateway:read` |

---

## 3. Self-hosted models: deploy, spin-up, status

A self-hosted model runs as a Kubernetes pod. It is an async resource: `deploy`
returns immediately and the pod finishes later, and a model can be **stopped or
scaled to zero**, so **poll status before you rely on it** (Golden Rule 3).

```bash
# Deploy (build image + run pod). Instance type comes from the body or the
# model/template's recommendedInstance; there is no silent default.
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/models/$ID/deploy" \
  -d '{"instance_type":"g5.xlarge","gpu":1,"replicas":1}' | jq '.data.status'

# Poll until it is serving. For self-hosted this queries the live deployment.
curl -s "${auth[@]}" "$BASE/ai/models/$ID/status" | jq '.data'   # -> status: deploying -> active
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
call wake it (that call pays the cold start) or `POST /ai/models/:id/start` and
poll `/status` until `active` first. Third-party models have no pod: `deploy`/
`start` just activate them and `status` comes from the database.

| Method / path | Does | Scope |
|---|---|---|
| `POST /ai/models/:id/deploy` | Deploy self-hosted (build+run) or activate third-party. Body: `instance_type`, `port`, `replicas`, `volume_size`, `gpu`, `cpu`, `memory`, `auto_shutdown_minutes`, `autoscaling`, `env_vars` | `ai-gateway:write` |
| `POST /ai/models/:id/start` | Start a stopped model | `ai-gateway:write` |
| `POST /ai/models/:id/stop` | Stop self-hosted pod / deactivate third-party | `ai-gateway:write` |
| `GET /ai/models/:id/status` | Live deployment status (self-hosted) or db status (third-party) | `ai-gateway:read` |
| `GET /ai/models/:id/logs` | Deployment logs (`lines`, `since`, `container`); empty for third-party | `ai-gateway:read` |
| `GET /ai/models/:id/metrics` | Runtime metrics | `ai-gateway:read` |

---

## 4. Calling a model (inference)

One request shape for every model, third-party or self-hosted. Pass the model
`_id` (from section 1) as `model`. Set `stream: true` to receive an SSE stream.

```bash
# Chat completion
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/chat/completions" \
  -d '{"model":"'"$ID"'","messages":[{"role":"user","content":"Summarize this quarter."}],"max_tokens":300}' \
  | jq '.choices[0].message.content'

# Streaming (SSE)
curl -sN -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/chat/completions" \
  -d '{"model":"'"$ID"'","messages":[{"role":"user","content":"Write a haiku."}],"stream":true}'

# Embeddings
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/embeddings" \
  -d '{"model":"'"$EMBED_ID"'","input":"text to embed"}' | jq '.data[0].embedding | length'

# Token count + context window (the reliable way to size a prompt)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/ai/tokenize" \
  -d '{"model":"'"$ID"'","prompt":"how many tokens is this"}' | jq '{count,max_model_len}'
```

| Method / path | Does | Notes |
|---|---|---|
| `POST /ai/chat/completions` | Chat completion | `model`, `messages`, `stream`, `temperature`, `max_tokens` |
| `POST /ai/completions` | Text completion | `model`, `prompt`, `stream`, ... |
| `POST /ai/embeddings` | Embeddings | `model`, `input` |
| `POST /ai/audio/speech` | Text to speech (returns binary audio) | `model`, `input`, `voice` |
| `GET /ai/audio/speech/voices` | List TTS voices | |
| `POST /ai/audio/transcriptions` | Speech to text (multipart file upload) | `model`, `file`, `language` |
| `POST /ai/audio/translations` | Speech to English text (multipart) | `model`, `file` |
| `POST /ai/generations/images` | Image generation | `model`, `prompt`, `n`, `size` |
| `POST /ai/generations/videos` · `/music` | Video / music generation (async job) | `model`, `prompt` |
| `POST /ai/generations` | Unified generation | `model`, `prompt`, `type` |
| `GET /ai/generations/:id` · `DELETE /ai/generations/:id` | Poll / cancel a generation job | |
| `POST /ai/moderations` | Content moderation | `model`, `input` |
| `POST /ai/rerank` | Rerank documents by relevance | `model`, `query`, `documents` |
| `POST /ai/tokenize` | Token count + `max_model_len` | `model`, `prompt` |

All inference routes need scope `ai-gateway:inference`. Video and music
generation return an async job: poll `GET /ai/generations/:id` until it
completes.

---

## 5. Guardrails

Guardrails are content rules applied to a model's inputs and outputs (PII,
jailbreaks, toxicity, banned topics). List the templates, apply their IDs plus
any custom rules to a model, then enable enforcement. Test a configuration
against sample text before turning it on.

```bash
curl -s "${auth[@]}" "$BASE/guardrails/templates" | jq '.data'                 # available template rule IDs
curl -s "${auth[@]}" "$BASE/guardrails/models"    | jq '.data'                 # models + guardrail status

# Apply full desired state (both arrays required; empty array clears a list)
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/guardrails/models/$ID" \
  -d '{"guardrail_rules":["pii-detection","jailbreak-prevention"],"custom_rules":[]}' | jq '.data'

curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/guardrails/models/$ID/toggle" \
  -d '{"enabled":true}' | jq '.data'

# Dry-run a rule set against sample text (no model call)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/guardrails/test" \
  -d '{"model_id":"'"$ID"'","input":"my SSN is 123-45-6789","direction":"input"}' | jq '.data'
```

| Method / path | Does | Scope |
|---|---|---|
| `GET /guardrails/models` | Models with guardrail status | `guardrails:read` |
| `GET /guardrails/models/:id` | A model's guardrail config | `guardrails:read` |
| `PUT /guardrails/models/:id` | Replace config (`guardrail_rules`, `custom_rules`, both required) | `guardrails:write` |
| `POST /guardrails/models/:id/toggle` | Enable/disable enforcement (`enabled`) | `guardrails:write` |
| `GET /guardrails/templates` | Built-in rule templates | `guardrails:read` |
| `POST /guardrails/test` | Dry-run (`model_id`, `input`, optional `rules`, `direction`) | `guardrails:write` |
| `GET /guardrails/logs` | Blocked/modified requests (`modelId`, `limit`) | `guardrails:read` |
| `GET /guardrails/statistics` | Aggregate guardrail stats | `guardrails:read` |

---

## 6. Analytics

Usage, cost, and performance for the gateway. Every route accepts `dateRange`
(for example `7d`, `30d`, `90d`; defaults to `30d`).

```bash
curl -s "${auth[@]}" "$BASE/ai/analytics/usage?dateRange=30d"              | jq '.data'
curl -s "${auth[@]}" "$BASE/ai/analytics/costs?dateRange=30d&groupBy=provider" | jq '.data'
curl -s "${auth[@]}" "$BASE/ai/analytics/performance?modelId=$ID"          | jq '.data'
curl -s "${auth[@]}" "$BASE/ai/analytics/time-series?granularity=daily"    | jq '.data'
curl -s "${auth[@]}" "$BASE/ai/analytics/providers?dateRange=90d"          | jq '.data'
```

| Method / path | Does | Params |
|---|---|---|
| `GET /ai/analytics/usage` | Usage stats | `modelId`, `dateRange` |
| `GET /ai/analytics/costs` | Cost breakdown | `dateRange`, `groupBy` |
| `GET /ai/analytics/performance` | Latency/throughput | `modelId`, `dateRange` |
| `GET /ai/analytics/time-series` | Time series | `dateRange`, `provider`, `granularity` |
| `GET /ai/analytics/providers` | Per-provider stats | `dateRange` |

All analytics routes need scope `ai-gateway:read`.

---

## Checklist
- [ ] List the user's real models (`GET /ai/models`) and pick an `_id`; never hardcode a model name.
- [ ] Know each model's `type`: third-party needs a provider key; self-hosted may need a spin-up.
- [ ] Provider key value is sent only on `POST /ai/provider-keys`; never in a URL or log; verify with `/test`.
- [ ] Before relying on a self-hosted model, poll `GET /ai/models/:id/status` until `active`; on-demand models cold-start on the first call.
- [ ] Same request shape for all inference; pass the model `_id` as `model`; add `stream:true` for SSE.
- [ ] Guardrails: apply template + custom rules with `PUT`, then `toggle` on; dry-run with `POST /guardrails/test` first.
- [ ] Report real status and `error.message` on failure; do not fabricate a completion.
