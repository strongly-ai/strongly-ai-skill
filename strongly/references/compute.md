# Compute

Strongly **compute** is managed infrastructure a user runs interactively or wires
into their work: **workspaces** (a JupyterLab or VS Code IDE in the cluster),
saved **environments** (reusable hardware tiers and custom images), attached
**compute clusters** (Ray, Dask, Spark), **node pools** (pre-warmed capacity per
workload), **volumes** (persistent project storage), and **code sessions** (a
coding-assistant CLI driven over a workspace terminal).

Read this when the task is: creating or starting a workspace, sizing it from a
saved environment or a custom image, attaching a distributed cluster, pre-warming
nodes for a workload, provisioning or uploading to a data volume, or running
Claude Code / Codex in a workspace through a code session.

A **workspace is where Claude Code or Codex runs and code executes** (once this
Strongly skill is published it auto-installs there), and a workspace can be
deployed straight into a running app: see `references/apps.md` for the app deploy,
proxy, and identity mechanics.

**Auth** follows `SKILL.md`: outside Strongly you send `X-API-Key` to
`$HOST/api/v1`; inside Strongly (workspace or app) the base is
`$STRONGLY_API_URL/api/v1` and the bearer is auto-injected. Below, `$BASE` is
whichever applies, and set the key once (outside Strongly):

```bash
export STRONGLY_API_KEY=sk-...        # Settings -> API Keys
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
```

**Async rule:** creating or starting a workspace, cluster, or volume returns
immediately and finishes later. Always poll the matching `status` endpoint until
it reports running or ready before you use the resource. Never report success on
the create call alone.

---

## 1. Workspaces

A workspace is a single IDE pod: `environmentType` picks the image (`jupyter` for
JupyterLab, `vscode` for VS Code server, or `custom` for your own image via
`customDockerfile`). Hardware sizing is a separate axis: pass a saved
`environmentId` (see section 2) or spell out `customResources`
(`{ cpu, memory, disk, gpu_type? }`); omit both for defaults (cpu 1, memory 2GB,
disk 20GB).

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /workspaces` | `workspaces:read` | List. Filters: `search`, `status`, `projectId`, `limit`, `offset`, `sort`. |
| `POST /workspaces` | `workspaces:write` | Create. Required: `name`, `description`, `environmentType`. |
| `GET /workspaces/:id` | `workspaces:read` | Get one. |
| `PUT /workspaces/:id` | `workspaces:write` | Update `name`, `description`, `environmentType`. |
| `DELETE /workspaces/:id` | `workspaces:write` | Delete. |
| `POST /workspaces/:id/start` | `workspaces:write` | Start a stopped workspace. |
| `POST /workspaces/:id/stop` | `workspaces:write` | Stop a running workspace. |
| `POST /workspaces/:id/restart` | `workspaces:write` | Restart. |
| `GET /workspaces/:id/status` | `workspaces:read` | Live status (poll this until running). |
| `GET /workspaces/:id/metrics` | `workspaces:read` | CPU / memory usage. |
| `GET /workspaces/:id/logs` | `workspaces:read` | Container logs. `type` is `build`, `deploy`, or `pod` (default `pod`). |
| `POST /workspaces/:id/sync` | `workspaces:write` | Sync the workspace to persistent storage. |

Optional wiring on `POST /workspaces` (all optional): `projectId` (clones the
project files to `/project` and mounts its volumes; see `references/projects.md`),
`dataSources`, `addons`, `aiGateways`, `workflows` (arrays of ids),
`environmentVariables` (object), `codeSessionEnabled` (add a terminal an assistant
can drive), `environmentId`, `customResources`, `customDockerfile` (required when
`environmentType` is `custom`), `cluster` (section 3), and `capacity_type: "spot"`
/ `useSpotInstances` for spot capacity.

```bash
# Create a Jupyter workspace, then poll status until it is running.
WS=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"ml-lab","description":"training scratch","environmentType":"jupyter",
       "customResources":{"cpu":"2","memory":"8Gi","disk":"20Gi"}}' \
  "$BASE/workspaces" | jq -r '.data._id')

curl -s "${auth[@]}" "$BASE/workspaces/$WS/status" | jq '.data'   # repeat until running
```

---

## 2. Environments

An environment is a saved, named hardware tier (and optionally a prebuilt custom
image) that a workspace sizes from via `environmentId`. Supplying `base_image`
and/or `dockerfile` triggers an image build: poll `GET /environments/:id` for
`build_status: "success"` and `image_name` before binding it.

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /environments` | `workspaces:read` | List saved environments. Query `enabledOnly`, `includeUsage`. |
| `POST /environments` | `workspaces:write` | Create. Required: `name`. Optional: `description`, `cpu`, `memory_gb`, `gpu_count`, `gpu_type`, `storage_gb`, `is_public`, `base_image`, `dockerfile`. |
| `GET /environments/base-image-status` | `workspaces:read` | Per-environment base-image freshness (`current` / `outdated` / `unknown`). |
| `GET /environments/:id` | `workspaces:read` | Get one, including `build_status` and `image_name`. |
| `PATCH /environments/:id` | `workspaces:write` | Update; a `base_image` / `dockerfile` change triggers a rebuild. |
| `DELETE /environments/:id` | `workspaces:write` | Delete (fails if still referenced by any app, job, workspace, workflow, or model). |
| `POST /environments/:id/rebuild-latest` | `workspaces:write` | Rebuild as a new immutable version against the current base-image digest. |

```bash
# Pick a saved tier for a workspace, or fall back to customResources if none fits.
curl -s "${auth[@]}" "$BASE/environments?enabledOnly=true" | jq '.data'
```

---

## 3. Compute clusters (attached to a workspace)

A distributed-compute cluster (Ray, Dask, or Spark) is not a standalone resource:
you attach one at workspace-create time with the `cluster` object on
`POST /workspaces`. The connect string and dashboard are injected into the
workspace as `STRONGLY_SERVICES.cluster`. The cluster is provisioned when the
workspace deploys, deleted when it stops (no idle cost), and recreated on start.

`cluster` shape:

```json
{
  "engine": "ray",
  "coordinator": { "cpu": "1", "memory": "4Gi" },
  "worker": { "cpu": "2", "memory": "8Gi", "gpu": 0, "gpuType": "nvidia-t4" },
  "workers": 3,
  "autoscale": { "enabled": true, "maxWorkers": 8 }
}
```

`engine` is `ray`, `dask`, or `spark`. `gpu` / `gpuType` on the worker and the
whole `autoscale` block are optional. Omit `cluster` for a workspace with no
cluster.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"ray-lab","description":"distributed training","environmentType":"jupyter",
       "cluster":{"engine":"ray","coordinator":{"cpu":"1","memory":"4Gi"},
                  "worker":{"cpu":"2","memory":"8Gi"},"workers":3}}' \
  "$BASE/workspaces" | jq '.data'
```

---

## 4. Node pools (pre-warmed compute)

Node pools are the platform workload pools that back the resources above. Pre-warm
a pool to keep spare nodes hot for faster scheduling, and pin a pool to a specific
instance family and size. `workloadType` is one of: `general`, `ai`, `mcp`,
`user-addons`, `user-workspaces`, `user-jobs`, `user-apps`.

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /compute/pre-warmed` | `compute:read` | Get pre-warmed configs for all workload pools. |
| `PUT /compute/pre-warmed/:workloadType` | `compute:write` | Set a pool config. Required body: `enabled`, `count` (1-5), `instanceCategory`, `instanceSize`. |
| `DELETE /compute/pre-warmed/:workloadType` | `compute:write` | Remove the size override, restoring the pool's normal allowlist. |

`instanceCategory` is a family letter (`m`, `c`, `g`, ...); `instanceSize` is one
of `small`, `medium`, `large`, `xlarge`, `2xlarge`, `4xlarge`.

```bash
# Keep 2 medium m-family nodes warm for user workspaces.
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"enabled":true,"count":2,"instanceCategory":"m","instanceSize":"medium"}' \
  "$BASE/compute/pre-warmed/user-workspaces" | jq '.data'
```

---

## 5. Volumes

A data volume is persistent storage bound to a project (synced to S3). Create it
against a `projectId` (see `references/projects.md`), upload files with a presigned
URL, then mount it into a workspace via the workspace's `projectId`.

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /volumes` | `volumes:read` | List. Filters: `search`, `type`, `projectId`, `limit`, `offset`, `sort`. |
| `POST /volumes` | `volumes:write` | Create. Required: `projectId`, `label`, `sizeGB`. |
| `POST /volumes/:id/upload-url` | `volumes:write` | Presigned PUT URL for a file. Required: `filename`; optional `contentType` (default `text/csv`). Returns `uploadUrl`, `key`, `bucket`. |
| `GET /volumes/shared` | `volumes:read` | List shared volumes visible to the user. |
| `GET /volumes/:id` | `volumes:read` | Get one. |
| `GET /volumes/:id/status` | `volumes:read` | Storage status: `pvc_phase`, `capacity`, `used_bytes`, `last_sync_at` (poll this). |
| `PUT /volumes/:id` | `volumes:write` | Update `label`, `description`, `sizeGB`. |
| `DELETE /volumes/:id` | `volumes:write` | Delete. |
| `POST /volumes/:id/sync` | `volumes:write` | Sync the volume to S3. |
| `POST /volumes/:id/make-shared` | `volumes:write` | Share the volume across projects. |
| `POST /volumes/:id/make-private` | `volumes:write` | Reverse it back to a project volume. |

```bash
# Create a volume, get an upload URL, PUT the bytes directly to S3.
VOL=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"projectId":"'"$PROJECT_ID"'","label":"training-data","sizeGB":10}' \
  "$BASE/volumes" | jq -r '.data._id')

URL=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"filename":"dataset.csv","contentType":"text/csv"}' \
  "$BASE/volumes/$VOL/upload-url" | jq -r '.data.uploadUrl')

curl -s -X PUT --data-binary @dataset.csv "$URL"
```

---

## 6. Code sessions

A code session drives a coding-assistant CLI (Claude Code by default, or `codex`)
over a workspace terminal. It runs in a fresh standalone workspace, in a new
workspace inside an existing project (`projectId`), or attached to an existing
code-session-enabled workspace (`workspaceId`). The terminal runs the assistant
TUI, not a bash shell: send natural-language tasks with
`POST /code-sessions/:id/input`, read output with `GET /code-sessions/:id/output`.

| Method + path | Scope | Purpose |
|---|---|---|
| `POST /code-sessions` | `code-sessions:write` | Create or resume. Required: `projectName`, `projectDescription`. Optional: `projectId`, `workspaceId`, `scaffold` (e.g. `react-starter`), `assistant` (`claude-code` default or `codex`). |
| `GET /code-sessions` | `code-sessions:read` | List. `live=true` returns only resumable sessions. |
| `GET /code-sessions/:id` | `code-sessions:read` | Get one, including `provisioningStep`; polling drives the provisioning transition. |
| `GET /code-sessions/:id/status` | `code-sessions:read` | Focused lifecycle status. |
| `POST /code-sessions/:id/input` | `code-sessions:write` | Send `text` (a task or prompt-answer) to the assistant terminal. |
| `POST /code-sessions/:id/login` | `code-sessions:write` | Start Claude Code login. Returns `{ authUrl }` (relay verbatim), or `{ alreadyAuthenticated }` / `{ pending }` / `{ ready:false }` / `{ useTerminal }` for Codex. |
| `POST /code-sessions/:id/login-code` | `code-sessions:write` | Submit the `code` the user pasted from the auth page. |
| `GET /code-sessions/:id/output` | `code-sessions:read` | Terminal output. Use `afterSeq` to poll for new chunks. |
| `POST /code-sessions/:id/deploy` | `code-sessions:deploy` | Deploy the session's workspace as an app (zip, build, deploy). See `references/apps.md`. |
| `DELETE /code-sessions/:id` | `code-sessions:write` | End the session and stop the workspace. |

```bash
# Create a session, poll until ready, then hand the assistant a build task.
SID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"projectName":"dashboard","projectDescription":"internal metrics UI",
       "scaffold":"react-starter"}' \
  "$BASE/code-sessions" | jq -r '.data._id')

curl -s "${auth[@]}" "$BASE/code-sessions/$SID/status" | jq '.data.status'   # until ready
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"text":"add a GET /health endpoint returning 200"}' \
  "$BASE/code-sessions/$SID/input"
```

Login is the user's own Claude account: Strongly supplies no credential. Relay the
`authUrl` as a clickable link, take the code the user pastes back, and submit it
with `login-code`. For Codex (`useTerminal:true`), drive `codex login` through the
terminal endpoints (`POST /code-sessions/:id/input`, `GET /code-sessions/:id/output`).

---

## Checklist
- [ ] Workspace `environmentType` is exactly `jupyter`, `vscode`, or `custom` (custom requires `customDockerfile`).
- [ ] Size a workspace with a saved `environmentId` (list `/environments`) or `customResources`; do not spell out both.
- [ ] After create / start, poll `GET /workspaces/:id/status` until running before use; never claim success on the create call.
- [ ] Custom-image environments: poll `GET /environments/:id` for `build_status: "success"` before binding.
- [ ] Attach a Ray / Dask / Spark cluster via the `cluster` object on `POST /workspaces`, not a separate endpoint.
- [ ] Pre-warm a pool with a valid `workloadType` and `count` in 1-5.
- [ ] Volumes: create against a `projectId`, upload via the presigned `uploadUrl` (bytes go browser to S3), poll `/volumes/:id/status` until `pvc_phase` reports bound.
- [ ] Code sessions: send natural-language tasks (not raw shell) to the assistant terminal; login uses the user's own Claude account; deploy an app via `/code-sessions/:id/deploy` and see `references/apps.md`.
