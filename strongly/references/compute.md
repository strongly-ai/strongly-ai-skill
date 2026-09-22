# Compute

Strongly **compute** is managed infrastructure a user runs interactively or wires
into their work: **workspaces** (a JupyterLab or VS Code IDE in the cluster),
saved **environments** (reusable hardware tiers and custom images), attached
**compute clusters** (Ray, Dask, Spark), **node pools** (pre-warmed capacity per
workload), **volumes** (a git code half plus a per-file versioned data half), and **code sessions** (a
coding-assistant CLI driven over a workspace terminal).

Read this when the task is: creating or starting a workspace, sizing it from a
saved environment or a custom image, attaching a distributed cluster, pre-warming
nodes for a workload, provisioning a volume and mounting it into a workspace, or running
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

**Async rule:** creating or starting a workspace or cluster returns
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
| `POST /workspaces/:id/sync` | `workspaces:write` | Flush every attached volume to durable storage: commit + push each code half (git) and commit the writable data changes as a new version. A workspace is ephemeral, so sync before you stop or delete it (section 5). |

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

A volume is one resource with two halves that mount together. The **code half** is a
git repository; the **data half** is a per-file versioned file store (writing a file
creates a new version of that file, reads return the latest or a pinned version).
There is no single whole-volume version, each file carries its own head version.

`code.filesystemType` picks how the code half is backed:
- **`github`**: an external GitHub repo. Pass `repoUrl`, `branch`, and an optional
  `sshKeyId` (an SSH key the user already registered in their profile). Commits and
  pushes sync to that GitHub repo.
- **`strongly`**: a platform-hosted git repo, nothing else to supply.

A volume's **scope** is `local` (belongs to one project, pass `projectId`) or
`shared` (org-wide, usable across projects). Names are unique within an org and
scope.

**Mount.** Attach a volume to a workspace and, on the workspace's next start, it
mounts at `/volumes/<scope>/<name>/code` and `/volumes/<scope>/<name>/data`
(e.g. `/volumes/local/my-vol/code`, `/volumes/shared/datasets/data`).

**Sync.** The code half is plain git: in the workspace terminal `git commit`,
`git push`, and `git pull` work with no credential prompt (the platform
authenticates you). For a `github` volume this syncs to the external GitHub repo.
The data half versions per file: writing or overwriting a file commits a new
version of just that file. A workspace is ephemeral compute, so edits under a
mounted volume are lost on stop or delete unless synced to the durable volume. To
flush everything at once, `POST /workspaces/:id/sync` (section 1) commits and
pushes each attached code half and commits the writable data changes as a new
version; sync before you end work or stop the workspace.

**Share.** Share a volume (read or write) through the unified sharing model and both
halves follow the share. It works across organizations: a sharee in another org can
clone the code half and read or write the data half from their own workspace, with
no extra credential setup.

**Data half over REST.** The data half is fully readable and writable without a
workspace, per file: list files, read one file's version history, download a
specific version's bytes, write or upload a file as a new version, and delete
(tombstone) a file, all through the endpoints below.

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /volumes` | `volumes:read` | List. Filters: `scope`, `projectId`, `limit`, `offset`. |
| `POST /volumes` | `volumes:write` | Create. Body: `name`, `scope`, `projectId?` (required when `scope` is `local`), `description?`, `code` (`{ filesystemType, repoUrl?, branch?, sshKeyId? }`). |
| `GET /volumes/:id` | `volumes:read` | Get one. |
| `GET /volumes/:id/data/files` | `volumes:read` | List data-half files. Each entry: `{ path, name, size, version, updatedAt, updatedBy }` (`version` is that file's head). |
| `GET /volumes/:id/data/files/versions` | `volumes:read` | One file's version history, newest first. Query `path`. |
| `GET /volumes/:id/data/files/content` | `volumes:read` | Download a file's bytes, base64-encoded. Query `path`, optional `version` (default latest). |
| `POST /volumes/:id/data/files` | `volumes:write` | Write a file as a new version. Body `path`, plus `content` (text) or `contentBase64` (binary), optional `message`. |
| `DELETE /volumes/:id/data/files` | `volumes:write` | Delete (tombstone) a file. Query `path`, optional `message`. |
| `POST /volumes/:id/attach` | `volumes:write` | Attach to a workspace: `workspaceId`, optional `dataVersion` (pins the data half to that version, default latest). Mounts on the workspace's next start. |
| `POST /volumes/:id/detach` | `volumes:write` | Detach from a workspace: `workspaceId`. |
| `DELETE /volumes/:id` | `volumes:write` | Delete. |

```bash
# Create a shared volume backed by a platform-hosted git repo.
VOL=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"datasets","scope":"shared","description":"team data",
       "code":{"filesystemType":"strongly"}}' \
  "$BASE/volumes" | jq -r '.data._id')

# Attach it to a workspace; it mounts at /volumes/shared/datasets/{code,data} on next start.
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"workspaceId":"'"$WS"'"}' "$BASE/volumes/$VOL/attach"

# List the data-half files, each with its own head version.
curl -s "${auth[@]}" "$BASE/volumes/$VOL/data/files" | jq '.data'
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

**The `react-starter` scaffold is deploy-ready.** It seeds a verified Strongly
starter app that already solves serving behind the proxy: a proxy-safe relative
base path, the signed-in-user identity read, a `STRONGLY_SERVICES` client, and a
`/health` endpoint (see `references/apps.md`). Claude Code EXTENDS it, so you do
not hand-write the proxy recipe. `deploy` returns the new app id:
`{ sessionId, appId, deploymentId, buildId, status }`.

### Deploy an app that needs a database (Postgres, etc.)

`POST /code-sessions/:id/deploy` builds the app from your workspace code ALONE
(name + description). It does NOT attach any addon, data source, or model, so the
app ships with no database unless you wire one. Do it as an explicit step, in
order:

1. Provision the store and wait for running (`references/addons.md`):
   `POST $BASE/addons {label, type:"postgres", cpu, memory, disk}`, then poll
   `GET $BASE/addons/:id/status` until running. (`postgres`, not `postgresql`.)
2. Build the app to READ its connection from `STRONGLY_SERVICES`, never hardcode a
   host or key; `react-starter` already reads it (see `references/apps.md` section 4).
3. Deploy the session, capture `appId` from the response, and poll the app build
   and pod to healthy (`references/apps.md` section 2).
4. Attach the store to the running app: `POST $BASE/addons/:id/connect/:appId`
   (`references/addons.md` section 7). Connecting to a running app rolls it
   automatically (zero-downtime), so the app then sees the store in
   `STRONGLY_SERVICES.services.addons.<type>` (match on `configId`; see
   `references/apps.md` section 4) with no manual redeploy.

For a marketplace-style app whose users pick the database in the deploy wizard,
declare it in `deploy.json` `addons[]` instead (`references/apps.md` section 6);
for a one-off code-session deploy, the `connect/:appId` step above is the path.

---

## Checklist
- [ ] Workspace `environmentType` is exactly `jupyter`, `vscode`, or `custom` (custom requires `customDockerfile`).
- [ ] Size a workspace with a saved `environmentId` (list `/environments`) or `customResources`; do not spell out both.
- [ ] After create / start, poll `GET /workspaces/:id/status` until running before use; never claim success on the create call.
- [ ] Custom-image environments: poll `GET /environments/:id` for `build_status: "success"` before binding.
- [ ] Attach a Ray / Dask / Spark cluster via the `cluster` object on `POST /workspaces`, not a separate endpoint.
- [ ] Pre-warm a pool with a valid `workloadType` and `count` in 1-5.
- [ ] Volumes: one resource with a git code half and a per-file versioned data half; create with `name`, `scope`, and `code.filesystemType` (`github` or `strongly`), plus `projectId` for a `local` volume; attach to a workspace and it mounts at `/volumes/<scope>/<name>/{code,data}` on next start.
- [ ] Code sessions: send natural-language tasks (not raw shell) to the assistant terminal; login uses the user's own Claude account; deploy an app via `/code-sessions/:id/deploy` and see `references/apps.md`.
- [ ] A code-session deploy wires NO services: after it, attach a database with `POST $BASE/addons/:id/connect/:appId` (or declare it in `deploy.json` for a wizard deploy); the app reads the connection from `STRONGLY_SERVICES`.
