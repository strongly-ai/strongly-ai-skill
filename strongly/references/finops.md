# FinOps

Strongly **FinOps** tracks what the platform spends and lets you act on it. Costs
come from Kubecost and the platform ledger; you **query** them by dimension and
time. **Budgets**, **Resource groups** and **Schedules** are configuration you
create and manage (schedules auto-stop resources off-hours
to save money).

Read this when the task is: reporting spend or trends, finding cost drivers or
anomalies, checking savings, managing budgets, organizing resources into groups
for cost rollups, or scheduling resources to stop and start on a timetable.

**Who a cost belongs to.** Every cost is **Strongly's** (what the platform costs
with no user load: its load balancers, control plane, its services at steady
state) or a **person's**: an **organization** (the owner's, which is charged),
an **owner** (whose workload it is: a deployed workflow's deployer, an app's or
add-on's owner, an agent's owner, a workspace's or job's starter) and a
**user** (who caused it: an app's signed-in user, the user a run is for, an
agent's owner for its tool calls). With no one else, the user is the owner
(automatic triggers, idle time, anonymous visitors). A user from another
organization (an app's user with an organization of their own) is shown by
name under the owner's organization. A run's user is who started it (an app
passing its user's `X-Strongly-User-Token` makes it that app user; a
sub-workflow its parent's user; a schedule or webhook the deployer); who it
runs as stays its deployer. Whatever the platform grew by for a workload (its
share of a platform service's scale-up, the idle capacity and daemons of the
nodes it ran on, its network and storage, the S3 requests it made) is part of
that workload's cost. S3 requests (`Object storage requests (S3)`) are counted
for a workflow's runs (its storage, its nodes, its S3 data sources) and a
volume's reads and writes, priced at the account's own S3 request prices; a
bucket in another AWS account is on that account's bill and is not booked.
Shared resources are divided each hour by use, every share keeping its owner:
app pods by viewers' request time, add-ons by the request time of the apps
that use them, deployed workflow pods by run time. Credits are per
organization. User budgets watch what the user owns.

**Auth** follows `SKILL.md`. Outside Strongly send `X-API-Key` to `$HOST/api/v1`;
inside Strongly the base is `$STRONGLY_API_URL/api/v1` and the bearer is
auto-injected. Below, `$BASE` is whichever applies. Set once (outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
# Inside Strongly (a workspace, app or job): BASE="$STRONGLY_API_URL/api/v1"; auth=()   # signed in as you, no key
```

**Scopes.** Reads need `finops:read`; creating or changing resource groups and
schedules needs `finops:write`. Every response is
the standard envelope (see `SKILL.md`): `data` on success, lists page with `cursor` / `meta.nextCursor`, and a failure is problem details whose `detail` and `code` to surface.

---

## 1. Costs (read only)

All cost endpoints are `GET` and read only. Pick the one that matches the shape
of the answer you need: a time series, a grouped breakdown, a ranked list, or a
single summary. Time windows are strings like `"7d"`, `"30d"` (default on most),
`"1y"`; dates are ISO 8601.

```bash
# Dashboard overview: stats + 30d trend + monthly + top drivers, one call
curl -s "${auth[@]}" "$BASE/finops/dashboard" | jq '.data'

# Trend time series (NOT grouped): window + granularity hourly|daily|monthly
curl -s "${auth[@]}" "$BASE/finops/costs/trends?window=30d&granularity=daily" | jq '.data'

# Who spent what, as a drill-down: each Organization (Owner), and Strongly
curl -s "${auth[@]}" "$BASE/finops/costs/breakdown?window=30d&groupBy=org" | jq '.data'
# ...then one organization's owners, an owner's users, a user's workloads, a workload's components
curl -s "${auth[@]}" "$BASE/finops/costs/breakdown?window=30d&groupBy=owner&orgId=$ORG" | jq '.data'
curl -s "${auth[@]}" "$BASE/finops/costs/breakdown?window=30d&groupBy=component&workload=$WORKLOAD" | jq '.data'

# The most expensive workloads (each with every component of its cost)
curl -s "${auth[@]}" "$BASE/finops/costs/top-drivers?window=30d&limit=5" | jq '.data'

# Each workload's cost over the newest recorded hours (ends at .recordedThrough, not the clock)
curl -s "${auth[@]}" "$BASE/finops/costs/realtime?window=24h" | jq '.data'

# Each workflow's (or agent's) cost per run
curl -s "${auth[@]}" "$BASE/finops/costs/per-execution?window=30d" | jq '.data'
```

Choosing the right one:
- **Time series over time**, no grouping: `costs/trends` (or `costs/monthly`,
  `costs/daily` for pre-summarized month/day rollups).
- **Who spent what**: `costs/breakdown` is a drill-down. `groupBy=org` (the
  default) lists each Organization (Owner) and one `strongly` row; then
  `groupBy=owner` with `orgId`, `groupBy=user` with `ownerId`,
  `groupBy=workload` with `userId`, `groupBy=component` with `workload` (its own
  pods, its network, the platform services it scaled, node idle and daemons,
  its storage, its S3 requests). Each level adds up to the row above. `orgId=strongly` opens
  Strongly's own costs (`groupBy=workload`, groups `strongly:<id>`).
  `groupBy=type` totals the workloads of each type (`app`, `addon`,
  `workflow`, `workspace`, `self-hosted-model`, ...); `resourceType` keeps one
  type. Use `gpuCost` from the split to quantify GPU spend.
- **Rank the biggest spenders**: `costs/top-drivers` or `dashboard/top-drivers`.
- **Look ahead**: `costs/forecast` (`weeks`, default 13: daily cost projected whole
  weeks ahead by a mean-reverting level with a weekly season; each day, week and
  the total has `predicted` and a 95% `lowerBound`..`upperBound` calibrated by
  back-test; `backtest.nextWeekError` is the median next-week error; nothing with
  under 21 recorded days). Quote the interval, not just the median.
- **Find spikes**: `costs/anomalies` (lookback `days` + `threshold`).
- **Find waste**: `costs/savings` (rightsizing recommendations from efficiency).
- **Per-resource utilization**: `costs/efficiency`.

| Endpoint | Query params | Returns |
|---|---|---|
| `GET /finops/dashboard` | (none) | Overview: `stats`, `costTrend`, `monthlyCosts`, `topDrivers`; a part that failed is `null` and listed in `errors` (`part`, `code`, `status`, `detail`) |
| `GET /finops/dashboard/stats` | `period` | Headline stats for the window |
| `GET /finops/dashboard/top-drivers` | `limit`, `period` | Top drivers for the dashboard |
| `GET /finops/costs/trends` | `window`, `granularity` (`hourly`\|`daily`\|`weekly`\|`monthly`), `groupBy`, `orgId`, `ownerId`, `userId`, `resourceType`, `workload` | Time series of `{ timestamp, cost }`, each point broken down by `groupBy` when given |
| `GET /finops/costs/monthly` | `months`, `year` | Monthly entries + average/highest/lowest summary |
| `GET /finops/costs/daily` | `startDate`, `endDate`, `resourceType` | Daily entries + total/average/trend |
| `GET /finops/costs/breakdown` | `window`, `groupBy` (`org`\|`owner`\|`user`\|`workload`\|`component`\|`type`\|`namespace`), `orgId`, `ownerId`, `userId`, `resourceType`, `workload`, `namespace` | Per-group `totalCost` + cpu/ram/gpu/storage/network split; the groups add up to the row they open |
| `GET /finops/costs/top-drivers` | `window`, `limit` | The most expensive workloads, with organization, owner, GPU cost + efficiency |
| `GET /finops/costs/realtime` | `window` (`1h` default, `6h`, `24h`, `7d`), `namespace` | Each workload's cost over the newest hours the ledger records, through `recordedThrough`; 409 `ledger-not-recorded` when none is |
| `GET /finops/costs/per-execution` | `window` (default `30d`), `workflowId` | Each workflow's `totalCost`, `runs`, `costPerRun` (null with no run) |
| `GET /finops/costs/historical` | `startDate`, `endDate`, `groupBy`, `orgId`, `ownerId`, `userId`, `resourceType`, `workload` | The breakdown over a date range |
| `GET /finops/costs/efficiency` | `window`, `groupBy`, `orgId`, `ownerId`, `userId`, `resourceType`, `workload`, `namespace` | CPU and memory used against requested, overall and per group |
| `GET /finops/costs/forecast` | `weeks` (1-52, default 13) | `historical`, `predictions` (days), `weeks`, `total`, each with `predicted`/`lowerBound`/`upperBound`; `interval` (0.95), `model` |
| `GET /finops/costs/anomalies` | `days`, `threshold` | Detected anomalies for the window |
| `GET /finops/costs/savings` | `category`, `minSavings` | Rightsizing recommendations + total potential savings |
| `GET /finops/data-health` | (none) | Cost-collection coverage, data gaps, organization-hours not composed, hours Kubecost built only part of (not charged until whole), hours the cost refresh could not read or record, with why (not charged until recorded) |
| `GET /finops/reconciliations` | `limit`, `cursor` | Platform admins: the installation's AWS bill day by day (its account and its cluster's cost-allocation tags only) and how it was allocated: `organizationsUsd`, `stronglyUsd`, `unallocatedUsd` (should be 0), per category `billUsd`, `pricedUsd`, `factor`, `workloadsUsd`, `stronglyUsd`, `status` (`reconciled`, `strongly`, `not-on-bill`) |
| `GET /finops/reconciliations/:id` | `:id` = `YYYY-MM-DD` | One day with every Cost Explorer line per category (`lines`) |

Notes that save a wrong call:
- A workload's `network` cost (component `network`) is its pods' data transfer
  (internet, cross-zone, cross-region) and the load balancer traffic an app or
  workspace served; node hours and volumes are priced at the bill (Kubecost's
  list price scaled by the day's factor), and what no workload caused is Strongly's.
- S3 requests are the workload's that made them: a workload's pods name their AWS
  session `<type>.<id>` and the buckets' access logs say who called; a run's are
  counted by the run; Requester Pays requests (RequestPayer "requester") are
  on this installation's bill and its workload's.
- Requests to `strongly-shared` (assets) and `strongly-telemetry`
  (instrumentation) are not FinOps costs: tracked separately, never booked.
- There is no `compareWindow` on `top-drivers`; compare periods with
  `costs/monthly` or `trends` (its `changePercent` is on the previous period).
- A change on the previous period (`changePercent`, `spendTrend`, a row's
  `trend`) needs the whole previous period in the cost record (a 30-day change
  needs 60 days of history). Without it the change is `null` and
  `noChangeReason` says what is missing ("Needs 60 days of history (55
  recorded)"): report that line as it is.
- `ownerId` keeps the costs a user owns, `userId` the costs a user caused.
- An unknown `groupBy` is refused (400, naming the ones there are), and a wrong
  `resourceType` returns an empty breakdown. Pass exact values.

---

## 2. Budgets

The Budgets page's rule holds over REST: a platform admin manages every budget,
an organization's owners and admins only their own organization's (another
organization's budget is 404; anyone else is 403). Amounts are US cents.
Confirm a new budget's scope, amount and thresholds with the user first.

```bash
curl -s "${auth[@]}" "$BASE/finops/budgets?status=active" | jq '.data'
curl -s "${auth[@]}" "$BASE/finops/budgets/<budgetId>" | jq '.data'
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "name": "ML team monthly", "organizationId": "<orgId>", "scope": {"level": "organization"},
  "budget": {"amount": 150000, "currency": "USD", "type": "recurring", "period": "monthly", "resetDay": 1},
  "thresholds": [{"percent": 80, "action": "alert"}, {"percent": 100, "action": "pause"}]
}' "$BASE/finops/budgets" | jq '.data'
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"description": null}' "$BASE/finops/budgets/<budgetId>"     # merge patch
curl -s -X POST "${auth[@]}" "$BASE/finops/budgets/<budgetId>/pause"   # or /resume
curl -s -X DELETE "${auth[@]}" "$BASE/finops/budgets/<budgetId>"       # 204
```

| Endpoint | Params | Notes |
|---|---|---|
| `GET /finops/budgets` | `scopeLevel`, `status`, `q`, `limit`, `cursor` | `scopeLevel` one of `platform`, `organization`, `user`, `resourceGroup`, `resource`, `resourceType`, `tag`; `status` one of `active`, `paused`, `exhausted` |
| `GET /finops/budgets/:id` | path `id` | 404 if not in the caller's tenant |
| `POST /finops/budgets` | `name`, `organizationId`, `scope`, `budget`, `thresholds`; `description`, `notifications`, `enabled` | 201 with the budget; unique threshold percents, at most one `pause` |
| `PATCH /finops/budgets/:id` | any create member | JSON Merge Patch; only `description` may be `null` (removed) |
| `POST /finops/budgets/:id/pause`, `/resume` | path `id` | the budget, `status` `paused` / `active`; clears `stopped` |
| `DELETE /finops/budgets/:id` | path `id` | 204; its queued alerts go with it |

A budget's `notifications.email` says whether it also emails its alerts (they are
bell notifications either way); `notifications.mode` is `immediate` or `digest`.
An alert goes to the budget's recipients (platform admins, or the org's owners and
admins) and to the owner, and other tracked user, of each workload that spent in
it this period; those see only their own workloads (`metadata.workloads`). App
users (role `app`) are never alerted: they see only their app cards.
AI Gateway spend is its self-hosted models' pods: a `self_hosted_model` budget.

Archiving a user stops their budgets: every budget scoped to them and every budget
of an organization archived with them is paused (`enabled` false) with `stopped`
`{reason: "user-archived", userId, stoppedAt}` (null on any other budget): not
evaluated, alerting, pausing or refusing anything. Unarchiving them resumes exactly
those, unless a manager paused or resumed one since.

---

## 3. Resource groups

A **resource group** collects individual resources (apps, addons, workflows, and
so on) under one name so costs and budgets can roll up to it. Full CRUD, plus
add/remove members. Reads need `finops:read`; every mutation needs `finops:write`.

```bash
# Create (name required; description optional)
GID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Team A","description":"Team A resources"}' \
  "$BASE/finops/resource-groups" | jq -r '.data._id')

# Add a member (type, resourceId, name all required)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"type":"app","resourceId":"<appId>","name":"Checkout app"}' \
  "$BASE/finops/resource-groups/$GID/resources"

# Remove a member (resourceType is a REQUIRED query param)
curl -s -X DELETE "${auth[@]}" \
  "$BASE/finops/resource-groups/$GID/resources/<resourceId>?resourceType=app"
```

| Endpoint | Method | Scope | Required fields |
|---|---|---|---|
| `/finops/resource-groups` | GET | `finops:read` | query: `q`, `status`, `limit`, `cursor` |
| `/finops/resource-groups` | POST | `finops:write` | body: `name` (+ optional `description`) |
| `/finops/resource-groups/:id` | GET | `finops:read` | path `id` |
| `/finops/resource-groups/:id` | PUT | `finops:write` | path `id`; body `name`, `description` |
| `/finops/resource-groups/:id` | DELETE | `finops:write` | path `id` |
| `/finops/resource-groups/:id/resources` | POST | `finops:write` | body: `type`, `resourceId`, `name` |
| `/finops/resource-groups/:id/resources/:subId` | DELETE | `finops:write` | path `id`, `subId`; query `resourceType` |

A grouped member is keyed by `(resourceType, resourceId)`, so removal needs both
the member id in the path and `resourceType` in the query. Omit `resourceType`
and the call returns a validation error.

---

## 4. Schedules

A **resource schedule** stops the apps, add-ons, workspaces and self-hosted
models in its scope at a daily stop time and starts them at a start time, so
they are not running (and billing) off-hours. Full CRUD, plus pause/resume,
run-now, history, the resources it controls, and **overrides** that keep one
resource out of its stops until a time. Only platform administrators manage
schedules (any other key gets `403`). Reads need `finops:read`; changes need
`finops:write`.

```bash
# Create: name, scope, schedule all required
SID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "name": "Dev stop overnight",
  "scope": { "type": "resource_group", "resourceGroupId": "'"$GID"'" },
  "schedule": {
    "timezone": "America/New_York",
    "daysOfWeek": [1,2,3,4,5],
    "startTime": "08:00",
    "stopTime": "19:00"
  }
}' "$BASE/finops/schedules" | jq -r '.data._id')

# Pause / resume / run a stop or start now
curl -s -X POST "${auth[@]}" "$BASE/finops/schedules/$SID/pause"
curl -s -X POST "${auth[@]}" "$BASE/finops/schedules/$SID/resume"
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{"action":"stop"}' \
  "$BASE/finops/schedules/$SID/execute"

# Runs, newest first, each with every resource's result
curl -s "${auth[@]}" "$BASE/finops/schedules/$SID/history?limit=20" | jq '.data'

# What the schedule controls now; skippedUntil is set while an override keeps it running
curl -s "${auth[@]}" "$BASE/finops/schedules/$SID/resources" | jq '.data'

# Keep one resource running through the stops until a time (its starts still apply)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "resourceType": "workspace", "resourceId": "'"$WSID"'",
  "skipUntil": "2026-10-14T23:00:00Z", "reason": "evening demo"
}' "$BASE/finops/schedules/$SID/overrides"

# An override's id is the resource: <resourceType>:<resourceId>
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' -d '{"skipUntil":"2026-10-15T01:00:00Z"}' \
  "$BASE/finops/schedules/$SID/overrides/workspace:$WSID"
curl -s -X DELETE "${auth[@]}" "$BASE/finops/schedules/$SID/overrides/workspace:$WSID"
```

`scope` shape: `type` is `platform` (every schedulable resource), `user` (also
pass `userId`: the resources that user owns), or `resource_group` (also pass
`resourceGroupId`).

`schedule` shape: `timezone` (IANA name), `daysOfWeek` (integers, `1`=Monday to
`7`=Sunday), and `startTime` / `stopTime` as `"HH:MM"` 24-hour local strings.
Supply at least one of start/stop.

| Endpoint | Method | Scope | Notes |
|---|---|---|---|
| `/finops/schedules` | GET | `finops:read` | query: `q`, `status`, `scopeType`, `enabled` (`"true"`\|`"false"`), `limit`, `cursor` |
| `/finops/schedules` | POST | `finops:write` | body: `name`, `scope`, `schedule` (+ optional `description`, `enabled`) |
| `/finops/schedules/:id` | GET | `finops:read` | the schedule, with `nextStopAt`, `nextStartAt`, `overrides`, `executionHistory` |
| `/finops/schedules/:id` | PATCH | `finops:write` | body: any of `name`, `description`, `scope`, `schedule`, `enabled` |
| `/finops/schedules/:id` | DELETE | `finops:write` | `204` |
| `/finops/schedules/:id/pause` | POST | `finops:write` | Stop acting until resumed |
| `/finops/schedules/:id/resume` | POST | `finops:write` | Act again at its times |
| `/finops/schedules/:id/execute` | POST | `finops:write` | body `action`: `stop` or `start`; answers the run |
| `/finops/schedules/:id/history` | GET | `finops:read` | runs, newest first; `limit`, `cursor` |
| `/finops/schedules/:id/resources` | GET | `finops:read` | resources it controls, `skippedUntil` per resource |
| `/finops/schedules/:id/overrides` | GET | `finops:read` | overrides, latest `skipUntil` first |
| `/finops/schedules/:id/overrides` | POST | `finops:write` | body `resourceType`, `resourceId`, `skipUntil` (+ `reason`); `409` if it has one |
| `/finops/schedules/:scheduleId/overrides/:id` | PATCH | `finops:write` | body `skipUntil` and/or `reason` |
| `/finops/schedules/:scheduleId/overrides/:id` | DELETE | `finops:write` | `204`; stops apply to the resource again |

---

## Checklist
- [ ] Reads use `finops:read`; resource-group and schedule mutations use `finops:write`.
- [ ] Match the cost question to the endpoint: series (`trends`), grouped (`breakdown`), ranked (`top-drivers`), forecast/anomalies/savings/efficiency for their names.
- [ ] Use exact `groupBy` / `resourceType` values on `breakdown` (wrong values fall back or return empty).
- [ ] Budgets are list/get only; never attempt create/update/delete on them.
- [ ] Removing a group member requires `resourceType` in the query, not just the id.
- [ ] Schedule `scope.type` drives which extra id you pass (`userId` or `resourceGroupId`); `schedule` needs `timezone`, `daysOfWeek` (1=Monday..7=Sunday), and at least one of `startTime`/`stopTime`.
- [ ] After `execute`, read `schedules/:id/history` to confirm the run rather than assuming it fired.
- [ ] To keep one resource running through a schedule's stops, add an override (the resource must be in `schedules/:id/resources`); do not pause the whole schedule.
