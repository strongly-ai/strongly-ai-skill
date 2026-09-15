# Projects

A Strongly **project** is the container that groups a piece of work: its
**filesystem** (either a platform-managed data volume or a GitHub repo), the
**workspaces** launched against that filesystem, the **data volumes** attached to
it, its **collaborators**, and one built-in **Kanban board**. Workspaces, ML jobs,
and other compute run *inside* a project and read/write the project filesystem.

Read this when the task is: creating/listing/updating projects, choosing the
project filesystem (a Strongly data volume vs a GitHub repo), attaching or
detaching data volumes, listing the workspaces in a project, managing
collaborators, or driving the project's Kanban board (columns, labels, cards,
archive).

**Auth** follows `SKILL.md`: inside Strongly the base is `$STRONGLY_API_URL/api/v1`
and the bearer is auto-injected; outside Strongly you send `X-API-Key` to
`$HOST/api/v1`. Below, `$BASE` is whichever applies. Every route here needs
`projects:read` (GET) or `projects:write` (create/update/delete and all board
writes). Set once (outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
```

Ids are 24-char hex Mongo ObjectIds. Success is `{ "success": true, "data": … }`;
lists add `pagination`. Surface `error.message` on failure.

---

## 1. Project lifecycle

Create with a `name` and `description`; everything else is optional. Listing
supports `search` (name/description), plus `status`, `category`, and `tag`
filters, with `limit`/`offset` paging.

```bash
# Create a Strongly-filesystem project (the default)
PID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Churn model","description":"Q3 churn work","tags":["ml"]}' \
  "$BASE/projects" | jq -r '.data._id')

curl -s "${auth[@]}" "$BASE/projects?search=churn&status=active&limit=20" | jq '.data'
curl -s "${auth[@]}" "$BASE/projects/$PID" | jq '.data'

# Update: send only the fields you are changing
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"status":"active","description":"Q3 + Q4 churn"}' "$BASE/projects/$PID"

# Stats and activity log
curl -s "${auth[@]}" "$BASE/projects/$PID/stats" | jq '.data'
curl -s "${auth[@]}" "$BASE/projects/$PID/activity?limit=25" | jq '.data'
```

**Delete vs archive.** `DELETE /projects/:id` archives the project's data and
**preserves its volumes** (it does not wipe the data volume). To keep a project
recoverable without deleting, use `archive` then `restore`.

| Method | Path | Tool | Notes |
|---|---|---|---|
| GET | `/projects` | `list_projects` | `search`, `status`, `category`, `tag`, `limit`, `offset` |
| POST | `/projects` | `create_project` | `name`*, `description`*, `filesystemType`, `githubConfig`, `tags` |
| GET | `/projects/:id` | `get_project` | full project document |
| PUT | `/projects/:id` | `update_project` | `name`, `description`, `status` |
| DELETE | `/projects/:id` | `delete_project` | archives data, keeps volumes |
| POST | `/projects/:id/archive` | `archive_project` | restorable |
| POST | `/projects/:id/restore` | `restore_project` | back to active |
| GET | `/projects/:id/stats` | `get_project_stats` | usage, workspace counts, activity |
| GET | `/projects/:id/activity` | `get_project_activity` | `limit`, `offset` |

`*` = required.

---

## 2. The project filesystem: Strongly vs GitHub

A project is created against one of two filesystem types, set by `filesystemType`
at create time:

- **`strongly`** (default): a platform-managed **data volume**. Nothing else
  to supply.
- **`github`**: a git repo. You **must** also pass `githubConfig`, or the create
  call fails:

  ```json
  { "repoUrl": "git@github.com:user/repo.git", "branch": "main", "sshKeyId": "<id>" }
  ```

  `repoUrl` is SSH form, `branch` is the branch to check out, and `sshKeyId` is an
  SSH key **the user already registered** in their profile UI. There is no REST
  route to create or list SSH keys, so the user must supply an existing
  `sshKeyId`. Omit `githubConfig` entirely for the default `strongly` filesystem.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "name":"App repo","description":"Frontend work","filesystemType":"github",
  "githubConfig":{"repoUrl":"git@github.com:acme/web.git","branch":"main","sshKeyId":"<id>"}
}' "$BASE/projects"
```

---

## 3. Workspaces and data volumes

A **workspace launches against a project filesystem** (e.g. Claude Code or a
notebook running on the project's data volume). List a project's workspaces here;
provision and launch them via the compute API, see **`references/compute.md`**.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/workspaces?limit=20" | jq '.data'
```

**Data volumes.** A project has a default volume plus any additional volumes you
attach so its workspaces and ML jobs can read/write shared data (e.g. a training
dataset). Create the volume first (compute API), then attach it here; the volume
must belong to the same organization. Detaching only unlinks the volume, it does
not delete it.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/volumes" | jq '.data'
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"volumeId":"<volId>"}' "$BASE/projects/$PID/volumes"
curl -s -X DELETE "${auth[@]}" "$BASE/projects/$PID/volumes/<volId>"
```

| Method | Path | Tool |
|---|---|---|
| GET | `/projects/:id/workspaces` | `list_project_workspaces` |
| GET | `/projects/:id/volumes` | `list_project_volumes` |
| POST | `/projects/:id/volumes` | `attach_project_volume` (`volumeId`*) |
| DELETE | `/projects/:id/volumes/:subId` | `detach_project_volume` |

---

## 4. Collaborators

The owner is always included in the collaborator list. Add someone by email and
role; the same list also feeds who can be assigned on the board (section 5).

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/collaborators" | jq '.data'
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"email":"dana@acme.com","role":"editor"}' "$BASE/projects/$PID/collaborators"
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"role":"viewer"}' "$BASE/projects/$PID/collaborators/<userId>"
curl -s -X DELETE "${auth[@]}" "$BASE/projects/$PID/collaborators/<userId>"
```

| Method | Path | Tool | Body |
|---|---|---|---|
| GET | `/projects/:id/collaborators` | `list_project_collaborators` | |
| POST | `/projects/:id/collaborators` | `add_project_collaborator` | `email`*, `role`*, `userId` |
| PUT | `/projects/:id/collaborators/:subId` | `update_project_collaborator_role` | `role`* |
| DELETE | `/projects/:id/collaborators/:subId` | `remove_project_collaborator` | |

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
use the top-level `/board-cards/:id` path. There is **no delete** for cards: they
are archived, keep their content, and can be restored.

```bash
# Create a card (returns { cardId }); description is markdown
CID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"columnId":"<colId>","title":"Investigate drift","description":"**check** q3"}' \
  "$BASE/projects/$PID/board/cards" | jq -r '.data.cardId')

# Update: PATCH only the fields you are changing (a real patch)
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"labelIds":["<lblId>"],"assigneeIds":["<userId>"],"dueDate":"2026-10-01T00:00:00Z"}' \
  "$BASE/board-cards/$CID"

# Move to the END of a column (omit neighbours for that); archive; restore
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"toColumnId":"<colId>"}' "$BASE/board-cards/$CID/move"
curl -s -X POST "${auth[@]}" "$BASE/board-cards/$CID/archive"
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"toColumnId":"<colId>"}' "$BASE/board-cards/$CID/restore"
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
`#0dcaf0` teal, `#7987a1` purple. Any other colour is rejected. Deleting a label
removes it from every card, archived ones included.

### Archive

Archived cards are the board's full history, paged newest-first (25 per page,
100 max), returning `{ cards, total, skip, limit, hasMore }`. Filter with
`search`; page with `skip`/`limit`.

```bash
curl -s "${auth[@]}" "$BASE/projects/$PID/board/archive?search=drift&skip=0&limit=25" | jq '.data'
```

| Method | Path | Tool | Body / query |
|---|---|---|---|
| GET | `/projects/:id/board` | `get_project_board` | |
| GET | `/projects/:id/board/archive` | `list_board_archive` | `search`, `skip`, `limit` |
| GET | `/projects/:id/board/members` | `list_board_members` | |
| POST | `/projects/:id/board/columns` | `add_board_column` | `name`* |
| POST | `/projects/:id/board/columns/reorder` | `reorder_board_columns` | `columnIds`* (all of them) |
| PATCH | `/projects/:id/board/columns/:subId` | `rename_board_column` | `name`* |
| DELETE | `/projects/:id/board/columns/:subId` | `remove_board_column` | archives cards inside |
| POST | `/projects/:id/board/labels` | `upsert_board_label` | `name`*, `color`*, `labelId` |
| DELETE | `/projects/:id/board/labels/:subId` | `remove_board_label` | |
| POST | `/projects/:id/board/cards` | `create_board_card` | `columnId`*, `title`*, `description` |
| PATCH | `/board-cards/:id` | `update_board_card` | `title`, `description`, `labelIds`, `assigneeIds`, `dueDate`, `dueComplete` |
| POST | `/board-cards/:id/move` | `move_board_card` | `toColumnId`*, `prevCardId`, `nextCardId` |
| POST | `/board-cards/:id/archive` | `archive_board_card` | |
| POST | `/board-cards/:id/restore` | `restore_board_card` | `toColumnId`* |

`*` = required.

---

## Checklist
- [ ] Create with `name` + `description`; add `filesystemType:"github"` **and**
      `githubConfig` (with an existing `sshKeyId`) only for a repo-backed project.
- [ ] `DELETE` archives data and keeps volumes; use `archive`/`restore` for a
      recoverable project.
- [ ] Attach a data volume (same org) before a workspace or ML job needs its data;
      launch workspaces via `references/compute.md`.
- [ ] `list_board_members` before assigning; send user ids with `assignable=true`,
      not names.
- [ ] `upsert_board_label` before putting a label on a card; colour from the fixed
      palette only.
- [ ] Cards are archived, never deleted; tell the user "archived" and restore from
      `list_board_archive`.
- [ ] `reorder_board_columns` needs the full column set; a partial list is rejected.
