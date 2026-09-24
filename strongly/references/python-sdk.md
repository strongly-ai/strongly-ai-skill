# Python SDK (`strongly`)

The **`strongly` Python SDK** is a convenience wrapper over the same `/api/v1`
REST API the rest of this skill describes. Every SDK call maps to a REST
endpoint, so the per-feature REST references (`references/ai-gateway.md`,
`references/workflows.md`, `references/mlops.md`, `references/model-registry.md`,
`references/apps.md`, `references/agents.md`) stay the source of truth for
fields, bodies, and behavior. This file shows the **Python surface** and points
you to the matching reference for detail.

**When to use it.** Prefer the SDK when you are writing **Python** and the code
runs where Python runs: inside a Strongly **workspace** (Jupyter, Claude Code,
Codex), a training or ETL **script**, a notebook, or a job. For anything else
(shell, another language, a quick one-off call) use raw REST from `SKILL.md`. A
JavaScript/TypeScript SDK also exists (`npm install @strongly-ai/sdk`); this
reference covers Python only.

> Only methods verified to exist in the shipped package appear below. When you
> need a capability not shown here, discover it with a `list`/`retrieve` call or
> drop to the REST reference. Do not guess a method name.

---

## 1. Install and client init (the two-context model)

```bash
pip install strongly-ai          # import name is `strongly`; Python 3.11+
```

The SDK is pre-installed in every Strongly workspace. Init follows the same
two-context rule as `SKILL.md`: **where the code runs** decides how it authenticates.

**Inside Strongly** (a workspace or a deployed app). The platform base URL
(`STRONGLY_API_URL`) is already in the environment and there is no key: the
platform signs every call in as the owner. The client takes **no arguments**:

```python
from strongly import Strongly

client = Strongly()   # STRONGLY_API_URL from the env; no key needed inside Strongly
```

**Outside Strongly** (laptop, CI, any external host). Pass the API key and your
host as `base_url` (the SDK appends `/api/v1` itself). Create the key in the UI
under **Settings > API Keys** (a.k.a. Profile > Security > REST API Keys):

```python
client = Strongly(
    api_key="sk-...",                       # or set STRONGLY_API_KEY in the env
    base_url="https://app.strongly.ai",     # your Strongly host, no /api/v1
)
```

Resolution order for credentials: explicit argument, then `STRONGLY_API_KEY` env
var, then (inside a Strongly workspace) none needed, then `~/.strongly/config`. The base URL comes from `base_url` or the
`STRONGLY_API_URL` env var. Never hardcode a public host; ask the user for
theirs.

**Async.** Every operation has an async twin on `AsyncStrongly`, usable as a
context manager:

```python
import asyncio
from strongly import AsyncStrongly

async def main():
    async with AsyncStrongly() as client:
        resp = await client.ai.inference.chat_completion(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": "Hello!"}],
        )
        print(resp.content)

asyncio.run(main())
```

**Client options.**

| Option | Default | Purpose |
|---|---|---|
| `api_key` | `STRONGLY_API_KEY` env | API key. |
| `base_url` | `STRONGLY_API_URL` env | Host; SDK appends `/api/v1`. |
| `timeout` | 30 | Request timeout (seconds). |
| `max_retries` | 3 | Automatic retries on transient errors. |

---

## 2. Results, lists, and errors

- **Typed objects.** Methods return typed models with attribute access
  (`app.status`, `resp.content`); the `{ success, data }` envelope is unwrapped
  for you.
- **Auto-paginating lists.** `list()` returns an iterator that fetches more
  pages as you consume it. Helpers: `.to_list()` (all items), `.first()` (first
  match). Pass `status=`, `limit=`, `search=` filters where supported.

```python
for app in client.apps.list(status="running"):
    print(app.name)

first_active = client.workflows.list(status="active").first()
```

- **Typed exceptions.** Failures raise subclasses of `StronglyError`:

```python
from strongly import Strongly, NotFoundError, RateLimitError, ValidationError

try:
    app = client.apps.retrieve("nonexistent")
except NotFoundError as e:
    print(e.message)
except RateLimitError as e:
    print(f"retry in {e.retry_after}s")
```

Others include `AuthenticationError`, `PermissionDeniedError` (map to a missing
API-key scope), `ConflictError`, `InternalServerError`.

---

## 3. AI Gateway and model inference

Full detail: `references/ai-gateway.md`. The SDK exposes the gateway under
`client.ai`.

```python
# Chat completion (client.ai.inference)
resp = client.ai.inference.chat_completion(
    model="gpt-4o-mini",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Explain transformers in 3 sentences."},
    ],
    temperature=0.7,
    max_tokens=500,
)
print(resp.content)                       # or resp.choices[0].message.content

# Streaming: stream=True yields StreamChunk objects
for chunk in client.ai.inference.chat_completion(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "Write a haiku about Python"}],
    stream=True,
):
    print(chunk.content, end="", flush=True)

# Embeddings
emb = client.ai.inference.embedding(
    model="text-embedding-ada-002",
    input=["Hello world", "Machine learning"],
)
```

Related namespaces: `client.ai.models` (catalog of available models),
`client.ai.provider_keys` (bring-your-own provider keys), `client.ai.analytics`
(usage). The `model` you pass is a model id from `client.ai.models.list()`; do
not assume one exists, list first.

---

## 4. Workflows: batch and streaming

Full detail: `references/workflows.md`. Runs are **async**, so poll the execution
(rule 3 in `SKILL.md`).

**Batch.** Build, run, then track the execution:

```python
wf = client.workflows.create(name="Daily ETL", description="Extract, transform, load")

result = client.workflows.execute(wf.id, trigger_inputs={"date": "2026-09-15"})
exec_id = result["execution_id"]

progress = client.executions.progress(exec_id)
print(f"{progress.completed_nodes}/{progress.total_nodes} nodes done")

for span in client.executions.spans(exec_id):
    print(f"  {span.node_id}: {span.status} ({span.duration_ms}ms)")
```

`client.workflows.execute(...)` starts a dev run; `client.workflows.trigger(id,
inputs=..., sync=True)` invokes a **deployed** workflow and can wait for output.
Traces live under `client.executions` (`retrieve`, `spans`, `logs`, `progress`).

**Streaming** (voice and real-time conversation workflows; see also the
Streaming Workflows guide). Sessions are long-lived, so you deploy once then open
sessions against the deployment:

```python
client.streaming.deploy(workflow_id="wf-voice-agent", cpu="1", memory="2Gi", replicas=2)

session = client.streaming.start_session(
    workflow_id="wf-voice-agent",
    session_config={"customer_name": "Jane Doe", "language": "en-US"},
)

client.streaming.inject_message(session.session_id, role="system",
                                content="Order located, shipped April 2.")

turns = client.streaming.transcript(session.session_id)
client.streaming.end_session(session.session_id)
```

Also on `client.streaming`: `list_workflows`, `list_deployments`, `undeploy`,
`session`, `list_sessions`, `metrics`, `errors`, `handoffs`.

---

## 5. MLOps: experiments, AutoML, fine-tuning

Full detail: `references/mlops.md`.

**Experiment tracking.** The `client.experiments` resource plus top-level
convenience helpers that are most natural inside a training script or workspace:

```python
import strongly

strongly.set_experiment("churn-model")
with strongly.start_run(run_name="rf-baseline"):
    strongly.log_params({"n_estimators": 100, "max_depth": 10})
    strongly.log_metrics({"accuracy": 0.94, "f1": 0.91})
    strongly.log_model(model, "classifier")
```

**AutoML.** Train a model from a project dataset:

```python
job = client.automl.create_job(
    name="support-classifier",
    dataset="vol-abc123",          # project volume id, s3:// path, or URL
    target_column="label",
    problem_type="tabular",        # tabular | multimodal | timeseries
    time_limit=600,
    metric="accuracy",
)
```

**Fine-tuning.** Fine-tune, monitor, deploy:

```python
job = client.fine_tuning.create_job(name="support-classifier", base_model="gpt-4o-mini",
                                     training_dataset="data/training.jsonl",
                                     hyperparameters={"n_epochs": 3})
job = client.fine_tuning.retrieve_job(job.id)   # poll job.status
client.fine_tuning.deploy_model(job.id)
```

Related: `client.drift_detection` and `client.feature_store` (both covered in
`references/mlops.md`).

---

## 6. Model registry

Full detail: `references/model-registry.md`. Register a version, then deploy it
to a managed endpoint (poll status after deploy):

```python
model = client.model_registry.create(
    name="churn-predictor",
    framework="sklearn",
    problem_type="classification",   # set this if you plan to run drift detection
    description="Production churn model",
)
client.model_registry.deploy(model.id, cpu=2, memory_gb=4)
```

---

## 7. Resource management

Full detail: `references/apps.md`, `references/addons.md`,
`references/datasources.md`. Deploys and starts are async, so poll status.

```python
# Apps
app = client.apps.create(name="my-service", image="python:3.11", port=8000)
client.apps.deploy(app.id)
status = client.apps.status(app.id)          # poll until ready
logs = client.apps.logs(app.id, lines=100)

# Addons (managed Postgres/Redis/Mongo/...)
addon = client.addons.create(label="my-postgres", type="postgresql",
                             cpu="500m", memory="1Gi", disk="10Gi")
client.addons.start(addon.id)
creds = client.addons.credentials(addon.id)  # host, port, database

# Data sources (connect external stores)
ds = client.datasources.create(name="prod-warehouse", type="postgresql",
                               credentials={"host": "db.example.com", "port": 5432})
client.datasources.test_connection(ds.id)
schema = client.datasources.metadata(ds.id)

# Projects and workspaces
project = client.projects.create(name="Churn Model")
ws = client.workspaces.create(name="training-env", environment_type="jupyter",
                              project_id=project.id)
client.workspaces.start(ws.id)
```

Also available: `client.volumes`, `client.finops` (`.costs`, `.budgets`),
`client.users`, `client.organizations`.

---

## 8. Agents

Full detail: `references/agents.md`. Promote a workflow into an agent, start it,
then chat (the response streams as SSE event dicts):

```python
client.agents.promote("wf_abc123")           # workflow -> agent mode
client.agents.start("wf_abc123")             # provision the pod
status = client.agents.status("wf_abc123")   # poll until running

for event in client.agents.chat("wf_abc123", "thread_123", "Find last week's meetings"):
    if event.get("event") == "thread.message.delta":
        print(event["data"]["delta"].get("content", ""), end="")
    elif event.get("event") == "thread.run.completed":
        print("\n--- done ---")
```

Upload documents to an agent's knowledge base with
`client.agents.upload_knowledge(agent_id, file, description=..., tags=...)`.

---

## Checklist
- [ ] Inside Strongly: `Strongly()` with no args (env supplies URL + key). Outside: pass `api_key` + `base_url` (host, no `/api/v1`).
- [ ] Prefer the SDK from Python (workspace, script, notebook); use raw REST elsewhere.
- [ ] Treat the matching `references/*.md` as the source of truth for fields; the SDK just wraps those endpoints.
- [ ] Poll after every async op: `apps.status`, `executions.progress`, `agents.status`, model/fine-tuning `status`.
- [ ] Iterate `list()` results directly; use `.to_list()` / `.first()` when you need a value.
- [ ] Catch typed exceptions (`NotFoundError`, `RateLimitError`, `PermissionDeniedError`); a permission error usually means a missing API-key scope.
- [ ] Do not call a method not shown here without confirming it exists; discover via `list`/`retrieve` or drop to REST.
