# Projects

A Strongly **project** is the container that groups a piece of work: its
**filesystem** (where its code's git repository lives: the platform's own, or a
GitHub repo), the
**workspaces** launched against that filesystem, its **project volume**, its
**collaborators**, and one built-in **Kanban board**. Workspaces, ML jobs,
and other compute run *inside* a project and read/write the project filesystem.

Read this when the task is: creating/listing/updating projects, choosing the
project filesystem (the Strongly filesystem vs a GitHub repo), listing a
project's volume and workspaces, managing
collaborators, or driving the project's Kanban board (columns, labels, cards,
archive).

**Auth** follows `SKILL.md`: inside Strongly the base is `$STRONGLY_API_URL/api/v1`
and the bearer is auto-injected; outside Strongly you send `X-API-Key` to
`$HOST/api/v1`. Below, `$BASE` is whichever applies. Every route here needs
`projects:read` (GET) or `projects:write` (create/update/delete and all board
writes). Set once (outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
# Inside Strongly (a workspace, app or job): BASE="$STRONGLY_API_URL/api/v1"; auth=()   # signed in as you, no key
```

Ids are opaque strings (for example `project-vHPyNBcx3RSxs6Nsv`); take them from a list or create response. Responses use the standard envelope (see `SKILL.md`): `data` on success, lists page with `cursor` / `meta.nextCursor`, and a failure is problem details whose `detail` and `code` to surface.

---

## 1. Project lifecycle

Create with a `name` and `description`; everything else is optional. Listing
supports `q` (name/description), plus `status`, `category`, and `tag`
filters, with `limit`/`cursor` paging.

```bash
# Create a Strongly-filesystem project (the default)
PID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Churn model","description":"Q3 churn work","tags":["ml"]}' \
  "$BASE/projects" | jq -r '.data._id')

curl -s "${auth[@]}" "$BASE/projects?q=churn&status=active&limit=20" | jq '.data'
curl -s "${auth[@]}" "$BASE/projects/$PID" | jq '.data'

# Update: send only the fields you are changing
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"description":"Q3 + Q4 churn"}' "$BASE/projects/$PID"

# Stats and activity log
curl -s "${auth[@]}" "$BASE/projects/$PID/stats" | jq '.data'
curl -s "${auth[@]}" "$BASE/projects/$PID/activity?limit=25" | jq '.data'
```

**Delete vs archive.** `DELETE /projects/:id?volume=delete|keep` permanently
deletes the project with its jobs, workspaces, run history, board and activity.
`volume` is required: `delete` removes the project's code/data volume and its
data; `keep` keeps it as a shared volume owned by the project owner, code and
data intact (its code read-only from then on). Ask the user which before deleting. `archive`
is a delete in all but the record: the project's workspaces are stopped and deleted, its jobs
and their schedules deleted (live runs stopped, run history with them) and its board archived;
its volume (code and data), record and activity are kept. No list, count or get shows an
archived project again (`404`) and nothing restores it. It is refused (`422 resource-in-use`)
while an agent lives in the project or uses one of its workspaces. Confirm with the user first,
saying what goes.

| Method | Path | Tool | Notes |
|---|---|---|---|
| GET | `/projects` | `list_projects` | `q`, `status` (`active` or `paused`), `category`, `tag`, `limit`, `cursor` |
| POST | `/projects` | `create_project` | `name`*, `description`*, `filesystemType`, `githubConfig`, `tags` |
| GET | `/projects/:id` | `get_project` | full project document |
| PATCH | `/projects/:id` | `update_project` | `name`, `description`, `tags`, `category`, `icon`, `readme`, `isPublic` (any other field is refused) |
| DELETE | `/projects/:id?volume=delete\|keep` | `delete_project` | `volume`* : delete or keep (as shared) the project volume |
| POST | `/projects/:id/archive` | `archive_project` | deletes its workspaces and jobs, archives its board, keeps its volume; no restore |
| GET | `/projects/:id/stats` | `get_project_stats` | usage, workspace counts, activity |
| GET | `/projects/:id/activity` | `get_project_activity` | `limit`, `cursor` |

`*` = required.

---

## 2. The project filesystem: Strongly vs GitHub

A project is created against one of two filesystem types, set by `filesystemType`
at create time:

- **`strongly`** (default): the platform hosts the project volume's git
  repository (the code half, beside its versioned data half). Nothing else to
  supply.
- **`github`**: a git repo. You **must** also pass `githubConfig`, or the create
  call fails:

  ```json
  { "repoUrl": "git@github.com:user/repo.git", "branch": "main", "sshKeyId": "<id>" }
  ```

  `repoUrl` is SSH form, `branch` is the branch to check out, and `sshKeyId` is an
  SSH key **the user already registered** in their profile UI (list them with
  `GET /me/github-ssh-keys`; there is no REST route to create one). Omit
  `githubConfig` entirely for the default `strongly` filesystem, which needs no
  key and is the right choice unless the user asks for a GitHub-backed project.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "name":"App repo","description":"Frontend work","filesystemType":"github",
  "githubConfig":{"repoUrl":"git@github.com:acme/web.git","branch":"main","sshKeyId":"<id>"}
}' "$BASE/projects"
```

---

## 3. Workspaces and the project volume

A **workspace launches against a project filesystem** (e.g. Claude Code or a
notebook working in the project volume's `code/` and `data/` at
`/volumes/local/<name>`). List a project's workspaces here;
provision and launch them via the compute API, see **`references/compute.md`**.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/workspaces?limit=20" | jq '.data'
```

**Volumes.** Every project has one volume of its own, created with the project.
Each workspace and ML job run mounts the project's volume at
`/volumes/local/<name>`, always, and only the shared volumes chosen for it
(`sharedVolumeIds`) at `/volumes/shared/<name>`, checked each time it starts. To reuse data
across projects, create a **shared** volume (data only) via the compute API; to
reuse code, share the project volume (others read its code, read-only). Either
then mounts everywhere the user works. Code is written only in the project's own
volume; see `references/compute.md`.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/volumes" | jq '.data'   # the project's volume
```

| Method | Path | Tool |
|---|---|---|
| GET | `/projects/:id/workspaces` | `list_project_workspaces` |
| GET | `/projects/:id/volumes` | `list_project_volumes` |

**Jobs.** A job (`POST /jobs`, `create_job`) runs a command with bash in the
project volume's code folder, on demand (`POST /jobs/:id/run`) or on a schedule.
`retries` (0 to 10, default 0) tries a failed run again, `retryDelaySeconds`
(0 to 86400, default 60) after it ended; scheduled and run-now runs alike. Each try
is its own execution (`GET /jobs/:id/executions`) with its own log and exit code:
`attempt` of `maxAttempts`, `firstExecutionId` on every later try, and `retryAt` on
a try waiting for its time (`pending` until then; it holds the job's one live run,
so a Run Now in the wait is refused with 409). A try that succeeds ends the tries,
and so do a cancel (`POST /jobs/:jobId/executions/:id/cancel`, running or
waiting) and a refusal (governance, budget, size). A changed `retries` (`PATCH
/jobs/:id`) applies from the next run. `GET /jobs/:jobId/executions/:id` carries the
run's whole log so far (`logs`, every line); the runs list carries each run's last 64 KB.
The whole log is also shown by `GET /jobs/:jobId/executions/:id/log-url` and
downloaded through a signed link, `POST /jobs/:jobId/executions/:id/logs/download`.
`GET /jobs/:jobId/executions/:id/pod` reads what runs a run now (after it
ends, as it was at its end): its containers' `restartCount`, `state` and `lastTerminated` (`reason` `OOMKilled`, `exitCode`
137 means it ran out of memory: give it more) and `pendingReasons` (why it waits for a machine).
A CPU job larger than every machine its pool may start is refused `400` at create or resize,
naming the largest size that runs (`GET /compute/pools`, `allowedSizes`).

```bash
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"retries":2,"retryDelaySeconds":30}' "$BASE/jobs/$JOB_ID" | jq '.data.retries'
curl -s "${auth[@]}" "$BASE/jobs/$JOB_ID/executions?limit=5" \
  | jq '.data[] | {_id, status, attempt, maxAttempts, retryAt, exitCode}'
```

---

## 4. Collaborators

The owner is always included in the collaborator list. Add someone by email and
role; the same list also feeds who can be assigned on the board (section 5).

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/members" | jq '.data'
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"email":"dana@acme.com","role":"editor"}' "$BASE/projects/$PID/members"
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"role":"viewer"}' "$BASE/projects/$PID/members/<userId>"
curl -s -X DELETE "${auth[@]}" "$BASE/projects/$PID/members/<userId>"
```

| Method | Path | Tool | Body |
|---|---|---|---|
| GET | `/projects/:id/members` | `list_project_members` | |
| POST | `/projects/:id/members` | `add_project_member` | `email`*, `role`*, `userId` |
| PATCH | `/projects/:projectId/members/:id` | `update_project_member` | `role`* |
| DELETE | `/projects/:projectId/members/:id` | `remove_project_member` | |

---

## 5. Project board (Kanban)

Every project has **exactly one** board and it always exists (no create call). A
new board starts with five columns: **Ice Box, Backlog, Work In Progress, Ready
For Review, Complete**. Board access follows project access. Read the whole board
in one call, then use the ids it returns for every mutation.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/board" | jq '.data'   # columns, cards, labels
```

### Cards

Card **create** is nested under the project; card **update/move/archive/restore**
use `/projects/-/board/cards/:id` (`PATCH`, and `POST …/move`, `…/archive`, `…/restore`). There is **no delete** for cards: they
are archived, keep their content, and can be restored.

```bash
# Create a card (returns { cardId }); description is markdown
CID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"columnId":"<colId>","title":"Investigate drift","description":"**check** q3"}' \
  "$BASE/projects/$PID/board/cards" | jq -r '.data.cardId')

# Update: PATCH only the fields you are changing (a real patch)
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"labelIds":["<lblId>"],"assigneeIds":["<userId>"],"dueDate":"2026-10-01T00:00:00Z"}' \
  "$BASE/projects/-/board/cards/$CID"

# Move to the END of a column (omit neighbours for that); archive; restore
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"toColumnId":"<colId>"}' "$BASE/projects/-/board/cards/$CID/move"
curl -s -X POST "${auth[@]}" "$BASE/projects/-/board/cards/$CID/archive"
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"toColumnId":"<colId>"}' "$BASE/projects/-/board/cards/$CID/restore"
```

- **Assignees** in `update_board_card` must be user ids with `assignable=true`
  from `list_board_members` (the owner and collaborators). Call members first so
  you send a real id, not a name.
- **Labels** in a card's `labelIds` must already exist on the board (create them
  first, section below). `labelIds`/`assigneeIds` **replace** the current set.
- **Move** positions by neighbour, not index: pass `prevCardId`/`nextCardId` (both
  already in the target column) to place precisely. If a neighbour moved you get
  `stale-move`; re-read the board and retry.
- **`dueDate`** is an ISO string or `null` to clear it; `dueComplete` is a boolean.

### Columns and labels

Removing a column archives any cards still in it (the response reports
`archivedCount`); a board must keep at least one column. Reorder takes **every**
column id in the desired order (a partial list is rejected). Labels use a fixed
palette: `#6571ff` blue, `#05a34a` green, `#fbbc06` yellow, `#ff3366` red,
`#0dcaf0` teal, `#7987a1` gray. Any other colour is rejected. Deleting a label
removes it from every card, archived ones included.

### Archive

Archived cards are the board's full history, a page at a time newest-first
(`limit`, default 50, max 200; the next page is `cursor=<meta.nextCursor>`, and
`meta.total` counts them all). Filter with `q`.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/board/archived-cards?q=drift&limit=25" | jq '.data'
```

| Method | Path | Tool | Body / query |
|---|---|---|---|
| GET | `/projects/:id/board` | `get_project_board` | |
| GET | `/projects/:id/board/archived-cards` | `list_archived_board_cards` | `q`, `limit`, `cursor` |
| GET | `/projects/:id/board/members` | `list_board_members` | |
| POST | `/projects/:id/board/columns` | `add_board_column` | `name`* |
| POST | `/projects/:id/board/columns/reorder` | `reorder_board_columns` | `columnIds`* (all of them) |
| PATCH | `/projects/:projectId/board/columns/:id` | `update_board_column` | `name`* |
| DELETE | `/projects/:projectId/board/columns/:id` | `remove_board_column` | archives cards inside |
| POST | `/projects/:id/board/labels` | `upsert_board_label` | `name`*, `color`*, `labelId` |
| DELETE | `/projects/:projectId/board/labels/:id` | `remove_board_label` | |
| POST | `/projects/:id/board/cards` | `create_board_card` | `columnId`*, `title`*, `description` |
| PATCH | `/projects/-/board/cards/:id` | `update_board_card` | `title`, `description`, `labelIds`, `assigneeIds`, `dueDate`, `dueComplete` |
| POST | `/projects/-/board/cards/:id/move` | `move_board_card` | `toColumnId`*, `prevCardId`, `nextCardId` |
| POST | `/projects/-/board/cards/:id/archive` | `archive_board_card` | |
| POST | `/projects/-/board/cards/:id/restore` | `restore_board_card` | `toColumnId`* |

`*` = required.

---

## Checklist
- [ ] Create with `name` + `description`; add `filesystemType:"github"` **and**
      `githubConfig` (with an existing `sshKeyId`) only for a repo-backed project.
- [ ] `DELETE` needs `volume=delete|keep` (delete the project volume, or keep it
      as a shared volume); use `archive`/`restore` for a recoverable project.
- [ ] A workspace or ML job mounts the project volume, and only the shared volumes
      in its `sharedVolumeIds` (none unless chosen); launch workspaces via
      `references/compute.md`.
- [ ] `list_board_members` before assigning; send user ids with `assignable=true`,
      not names.
- [ ] `upsert_board_label` before putting a label on a card; colour from the fixed
      palette only.
- [ ] Cards are archived, never deleted; tell the user "archived" and restore from
      `list_archived_board_cards`.
- [ ] `reorder_board_columns` needs the full column set; a partial list is rejected.
