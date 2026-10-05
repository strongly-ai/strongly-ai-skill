# Compute

Strongly **compute** is managed infrastructure a user runs interactively or wires
into their work: **workspaces** (a JupyterLab, VS Code, RStudio or custom IDE),
saved **environments** (a size, and optionally a custom image), attached
**compute clusters** (Ray, Dask, Spark), **node pools** (pre-warmed capacity per
workload), **volumes** (a project's volume: a git code half plus a per-file
versioned data half; a volume created as shared: the data half only), and
**code sessions** (a coding-assistant CLI driven over a workspace terminal).

Read this when the task is: creating or starting a workspace, sizing it from a
saved environment or a custom image, attaching a distributed cluster, pre-warming
nodes for a workload, creating or sharing a volume (volumes mount automatically,
there is no attach step), or running
Claude Code / Codex in a workspace through a code session.

A **workspace is where Claude Code, Codex or OpenCode runs and code executes**.
This Strongly skill is installed into each coding assistant chosen for the
workspace at every start, downloaded from GitHub (if it cannot be downloaded the
workspace does not start, and says why), and a workspace can be deployed straight
into a running app: see `references/apps.md` for the app deploy,
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

A workspace is a single IDE pod: `environmentType` picks the IDE (`jupyter` for
JupyterLab, `vscode` for VS Code server, `rstudio` for RStudio Server, or `custom`
for an IDE your environment's image runs itself, on `customPort`, default 8888).
Sizing is required and is a separate axis: pass a saved `environmentId` (section 2;
`custom` needs one, for its image) or spell out `customResources`
(`{ cpu, memory, disk, gpu?, gpu_type? }`). There is no default size, and a
workspace needs at least 0.5 CPU and 1 GB of memory (the platform's own containers
take their share out of it).

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /workspaces` | `workspaces:read` | List. Filters: `search`, `status`, `projectId`, `limit`, `offset`, `sort`. |
| `POST /workspaces` | `workspaces:write` | Create. Required: `name`, `description`, `environmentType`. |
| `GET /workspaces/:id` | `workspaces:read` | Get one. |
| `PUT /workspaces/:id` | `workspaces:write` | Update `name`, `description`, its services (`addons`, `dataSources`, `aiGateways`, `mlModels`, `workflows`, `featureStores`, `agents`), `codingAssistants` and `skillIds` (from the next start or restart), or `environmentVariables` (before its first start). Size, IDE and image are fixed at create. |
| `DELETE /workspaces/:id` | `workspaces:write` | Delete. |
| `POST /workspaces/:id/start` | `workspaces:write` | Start a stopped workspace. |
| `POST /workspaces/:id/stop` | `workspaces:write` | Stop a running workspace. |
| `POST /workspaces/:id/restart` | `workspaces:write` | Restart. |
| `GET /workspaces/:id/status` | `workspaces:read` | Live status (poll this until running). |
| `GET /workspaces/:id/metrics` | `workspaces:read` | CPU / memory usage. |
| `GET /workspaces/:id/logs` | `workspaces:read` | Container logs. `type` is `build`, `deploy`, or `pod` (default `pod`). |
| `POST /workspaces/:id/sync` | `workspaces:write` | Save every mounted volume to durable storage: commit and push each code half to the volume's configured branch, and record the changed data files as new versions. Stop/start/restart keep unsynced work; only delete loses it. Sync to make work durable, visible to others, and buildable (an app builds from synced code) (section 5). |

Optional wiring on `POST /workspaces` (all optional): `projectId` (the project's
volume mounts at `/volumes/local/<name>/{code,data}`; see `references/projects.md`),
`dataSources`, `addons`, `aiGateways`, `workflows` (arrays of ids),
`environmentVariables` (object), `codeSessionEnabled` (add a terminal an assistant
can drive), `codingAssistants` and `skillIds`, `environmentId`, `customResources`,
`customPort` (for `custom`), `cluster` (section 3), and `capacity_type: "spot"`
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

**GPU workers:** a Ray GPU worker has the GPU driver but no GPU framework. Add the
one the code uses per job with `runtime_env`, packaged with its CUDA libraries,
then request the GPU per task:
`ray.init(connect, runtime_env={"pip": ["cupy-cuda12x[ctk]"]})` (or `["torch"]`) and
`@ray.remote(num_gpus=1)`. Plain `cupy-cuda12x` fails ("libcurand ... No such file").
Dask GPU workers run RAPIDS (dask-cuda, cuDF, CuPy installed); their numpy 2.0.2 vs
the workspace's 2.1.3 shows a harmless version note.

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

A project's volume has two halves that mount together. The **code half** is a
git repository; the **data half** is a per-file versioned file store: in a
workspace each file you wrote becomes a new version of that file when you Sync; a
job run or an app saves each written file as a new version on its own; a write
over REST is a new version at once. Reads return the latest or a pinned version.
There is no single whole-volume version, each file carries its own head version.
A **shared** volume holds the data half only: it has no `code`.

**Code is written only in a project's own volume, in its project's workspaces.**
Wherever a project's volume is shared (another user's workspaces, job runs, apps)
its `code/` is mounted read-only, and every write to a shared volume's code (a
push, a branch, a file edit) is refused with 403. To reuse code, share the
project's volume; others read it.

A project volume's `code.filesystemType` picks how the code half is backed:
- **`github`**: an external GitHub repo. Pass `repoUrl`, `branch`, and an optional
  `sshKeyId` (an SSH key the user already registered in their profile). Commits and
  pushes sync to that GitHub repo.
- **`strongly`**: a platform-hosted git repo, nothing else to supply.

A volume's **scope** is `local` (a project's own volume, created with its project,
with code + data) or `shared` (standalone, usable across projects, data only;
create one with no `code`, which is refused for it). A project's volume kept when
its project is deleted becomes `shared` with its code read-only. A volume's name is
unique among its owner's volumes of the same scope (a second one is refused:
"You already have a shared volume named ..."); a project's volume takes its
project's name.

**Mount.** Mounting is automatic, there is no attach step: each time a workspace
(or job run) starts it mounts its project's volume at `/volumes/local/<name>` and
every shared volume the user can use at `/volumes/shared/<name>`, each as
`code/` (only when the volume has code; read-only under `/volumes/shared`) and
`data/` (e.g. `/volumes/local/my-proj/code`, `/volumes/shared/datasets/data`). A volume newly shared with the user mounts from
the next start. `data/` mounts at its latest version. Another project's unshared
volume never mounts.

**Sync.** The project volume's code half is plain git: in the workspace terminal
`git commit`, `git push`, and `git pull` work with no credential prompt (the
platform authenticates you). For a `github` volume this syncs to the external GitHub repo.
The data half versions per file: on sync, each file written or overwritten gets a
new version of just that file. Unsynced work (code edits, local commits, data
writes) survives stop, start and restart; only **deleting** the workspace loses
it. Until synced it is also not on the durable volume, not visible to anyone
else, not versioned, and not what an app deploy builds from. `POST
/workspaces/:id/sync` (section 1) does both halves: commits and pushes the
project volume's code to its configured branch (shared volumes' code is
read-only) and records the changed data files of every mounted volume as new
versions; then each `data/` shows the latest version of every file, so data others
saved appears at each Sync (and at start), never only after a restart. Sync before
deleting a workspace, handing work off, or deploying an app from the volume, and
to pick up others' newer data. Others' newer code comes down with `git pull`.

**Sync conflicts (as on GitHub).** If the volume's code changed on the same lines
since the workspace's last sync, that volume's sync result is `code.conflict: true`
with `code.files`: nothing is overwritten; the merge waits for a decision. Per file,
`POST /workspaces/:id/sync/resolve {volumeId, path, take: "mine"|"theirs"}`, or
merge it by hand in the clone (remove the conflict markers); `GET
/workspaces/:id/sync/conflicts` lists what is left. Then sync again to finish the
merge, or `POST /workspaces/:id/sync/abort {volumeId}` to cancel it. Ask the user
which version to keep; never pick for them.

**Job runs and apps.** Nobody Syncs a job run or an app, and both use volumes the
same way: `code/` is mounted read-only (the code as last synced; writing there
fails), `data/` opens at its latest version, read and write, and every file
written there is saved as a new version shortly after it is closed (the rest when
the run ends or the app stops). A run mounts its project's volume and the shared
volumes; an app mounts the volumes picked for it (`volumes` on the app,
`references/apps.md` section 4). Write results to `data/`, scratch to `/workspace`.

**Share.** Share a volume (read or write) through the unified sharing model: the
share sets whether the sharee may write its **data**; a shared project volume's
code is read-only to them. On a single-tenant installation it also works across
organizations (a sharee in another org reads the code half and reads or writes the
data half from their own workspace, with no extra credential setup); on a
multi-tenant installation a volume is shared only within its organization.

**Data half over REST.** The data half is fully readable and writable without a
workspace, per file: list files, read one file's version history, download a
specific version's bytes, write or upload a file as a new version, and delete
(tombstone) a file, all through the endpoints below.

| Method + path | Scope | Purpose |
|---|---|---|
| `GET /volumes` | `volumes:read` | List. Filters: `scope`, `projectId`, `limit`, `offset`. |
| `POST /volumes` | `volumes:write` | Create. A shared volume (the usual one): `name`, `scope: "shared"`, `description?`, no `code`. A project's volume is created with its project; a `local` create needs `projectId` and `code` (`{ filesystemType, repoUrl?, branch?, sshKeyId? }`). |
| `GET /volumes/:id` | `volumes:read` | Get one. |
| `GET /volumes/:id/data/files` | `volumes:read` | List data-half files. Each entry: `{ path, name, size, version, updatedAt, updatedBy }` (`version` is that file's head). |
| `GET /volumes/:id/data/files/versions` | `volumes:read` | One file's version history, newest first. Query `path`. |
| `GET /volumes/:id/data/files/content` | `volumes:read` | Download a file's bytes, base64-encoded. Query `path`, optional `version` (default latest). |
| `POST /volumes/:id/data/files` | `volumes:write` | Write a file as a new version. Body `path`, plus `content` (text) or `contentBase64` (binary), optional `message`. |
| `DELETE /volumes/:id/data/files` | `volumes:write` | Delete (tombstone) a file. Query `path`, optional `message`. |
| `GET /projects/:id/volumes` | `projects:read` | The volumes that belong to a project (its project volume). |
| `DELETE /volumes/:id` | `volumes:write` | Delete. |

```bash
# Create a shared volume: data only, no code.
VOL=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"datasets","scope":"shared","description":"team data"}' \
  "$BASE/volumes" | jq -r '.data._id')

# Nothing to attach: it mounts at /volumes/shared/datasets/data the next time
# any workspace of yours (or of anyone it is shared with) starts.

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
4. Attach the store to the app, then REDEPLOY so it takes effect. Add the addon id
   to the app definition with either `POST $BASE/addons/:id/connect/:appId` or
   `PUT $BASE/apps/:appId` `{"addons":["<id>"]}` (`references/addons.md` section 7).
   Both update the app DEFINITION only. `STRONGLY_SERVICES` is generated from the
   declared addons at build/deploy, so redeploy the app afterwards
   (`POST $BASE/apps/:appId/deploy`, then poll to healthy) for the running pod to
   see the store under `STRONGLY_SERVICES.services.addons.<type>` (match on
   `configId`; see `references/apps.md` section 4).

The cleanest path is to declare the addon id when you build, so the first deploy
already has it and there is no second round trip: for a bundle you build yourself,
`POST $BASE/apps/upload` with `metadata={"addons":["<id>"]}` (`references/apps.md`
section 4); for a marketplace-style app whose users pick the database in the deploy
wizard, declare it in `deploy.json` `addons[]` (`references/marketplace.md` section 8). The
code-session `deploy` builds from code alone and takes no addon list, which is why a
DB attached to a session-deployed app needs the connect-then-redeploy step above.

---

## Checklist
- [ ] Workspace `environmentType` is exactly `jupyter`, `vscode`, `rstudio`, or `custom` (custom requires an `environmentId` whose image runs its IDE, on `customPort`).
- [ ] Size a workspace with a saved `environmentId` (list `/environments`) or `customResources`; do not spell out both.
- [ ] After create / start, poll `GET /workspaces/:id/status` until running before use; never claim success on the create call.
- [ ] Custom-image environments: poll `GET /environments/:id` for `build_status: "success"` before binding.
- [ ] Attach a Ray / Dask / Spark cluster via the `cluster` object on `POST /workspaces`, not a separate endpoint.
- [ ] Pre-warm a pool with a valid `workloadType` and `count` in 1-5.
- [ ] Volumes: a project's volume has a git code half and a per-file versioned data half and is created with its project; a shared volume holds data only (create with `name` and `scope: "shared"`, no `code`). Code is written only in the project's own volume; shared code is read-only. Every workspace mounts them at `/volumes/<scope>/<name>/{code,data}` on its next start, with nothing to attach.
- [ ] Code sessions: send natural-language tasks (not raw shell) to the assistant terminal; login uses the user's own Claude account; deploy an app via `/code-sessions/:id/deploy` and see `references/apps.md`.
- [ ] A code-session deploy wires NO services: to add a database afterwards, add the addon id to the app (`connect/:appId` or `PUT /apps/:id {addons}`) AND redeploy so `STRONGLY_SERVICES` regenerates; or declare it up front (`/apps/upload` `metadata={"addons":[...]}`, or `deploy.json` for a wizard deploy). The app reads the connection from `STRONGLY_SERVICES`.
