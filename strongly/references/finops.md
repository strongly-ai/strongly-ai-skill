# FinOps

Strongly **FinOps** tracks what the platform spends and lets you act on it. Costs
come from Kubecost and the platform ledger; you **query** them by dimension and
time. **Budgets** are read only over REST. **Resource groups** and **Schedules**
are configuration you create and manage (schedules auto-stop resources off-hours
to save money).

Read this when the task is: reporting spend or trends, finding cost drivers or
anomalies, checking savings, listing budgets, organizing resources into groups
for cost rollups, or scheduling resources to stop and start on a timetable.

**Who usage belongs to.** Every cost has an **owner** (whose resource it is: a
deployed workflow's deployer, an app's or add-on's owner, an agent's owner, a
workspace's or job's starter) and a **user** (who caused it: an app's signed-in
user, the user a run is for, an agent's owner for its tool calls). With no one
else, the user is the owner (automatic triggers, idle and base time, anonymous
visitors). A run's user is who started it (an app passing its user's
`X-Strongly-User-Token` makes it that app user; a sub-workflow its parent's user;
a schedule or webhook the deployer); who it runs as stays its deployer. Shared
resources are divided each hour by use, every share keeping its owner: app pods
by viewers' request time, add-ons by the request time of the apps that use
them, deployed workflow pods by run time. Credits are per organization. Group
by `owner` or `user`: both total the same. User budgets watch what the user owns.

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

# Grouped breakdown: total_cost plus cpu/ram/gpu/storage/network split per group
curl -s "${auth[@]}" "$BASE/finops/costs/breakdown?window=30d&groupBy=resource_type" | jq '.data'

# Top cost-driving resources (per-resource GPU cost + efficiency)
curl -s "${auth[@]}" "$BASE/finops/costs/top-drivers?window=30d&limit=5" | jq '.data'

# Realtime from Kubecost
curl -s "${auth[@]}" "$BASE/finops/costs/realtime?window=1d&aggregate=namespace" | jq '.data'
```

Choosing the right one:
- **Time series over time**, no grouping: `costs/trends` (or `costs/monthly`,
  `costs/daily` for pre-summarized month/day rollups).
- **Group costs by a dimension**: `costs/breakdown` with `groupBy` one of
  `resource_type` (default), `resource_id`, `namespace`, `org`, `owner`
  (whose resources), `user` (who caused the cost), `workload`. Filter to one `resourceType` (`app`, `addon`, `workflow`, `workspace`,
  `ml_model`, `self_hosted_model`, `automl`, `fine_tuning`) to compare inside a
  type. Use `gpu_cost` from the split to quantify GPU spend.
- **Rank the biggest spenders**: `costs/top-drivers` or `dashboard/top-drivers`.
- **Look ahead**: `costs/forecast` (growth-rate projection over N months from the
  last 90 days, with a confidence level).
- **Find spikes**: `costs/anomalies` (lookback `days` + `threshold`).
- **Find waste**: `costs/savings` (rightsizing recommendations from efficiency).
- **Per-resource utilization**: `costs/efficiency`.

| Endpoint | Query params | Returns |
|---|---|---|
| `GET /finops/dashboard` | (none) | Overview: `stats`, `costTrend`, `monthlyCosts`, `topDrivers` |
| `GET /finops/dashboard/stats` | `period` | Headline stats for the window |
| `GET /finops/dashboard/top-drivers` | `limit`, `period` | Top drivers for the dashboard |
| `GET /finops/costs/trends` | `window`, `granularity` (`hourly`\|`daily`\|`weekly`\|`monthly`), `groupBy`, `resourceType` | Time series of `{ timestamp, cost }`, each point broken down by `groupBy` when given |
| `GET /finops/costs/monthly` | `months`, `year` | Monthly entries + average/highest/lowest summary |
| `GET /finops/costs/daily` | `startDate`, `endDate`, `resourceType` | Daily entries + total/average/trend |
| `GET /finops/costs/breakdown` | `window`, `groupBy`, `resourceType`, `orgId`, `ownerId`, `userId`, `namespace` | Per-group `total_cost` + cpu/ram/gpu/storage/network split |
| `GET /finops/costs/services` | `period`, `startDate`, `endDate` | Breakdown by resource type over a window or explicit range |
| `GET /finops/costs/top-drivers` | `window`, `limit` | Ranked resources with GPU cost + efficiency |
| `GET /finops/costs/realtime` | `window`, `aggregate`, `namespace` | Live Kubecost cost items |
| `GET /finops/costs/historical` | `startDate`, `endDate`, `groupBy`, `orgId`, `ownerId`, `userId` | Stored historical cost data |
| `GET /finops/costs/efficiency` | `window`, `namespace`, `aggregate` | Resource efficiency metrics |
| `GET /finops/costs/forecast` | `months` | `historical`, `predictions`, growth/confidence analysis |
| `GET /finops/costs/anomalies` | `days`, `threshold` | Detected anomalies for the window |
| `GET /finops/costs/savings` | `category`, `minSavings` | Rightsizing recommendations + total potential savings |
| `GET /finops/data-health` | (none) | Cost-collection coverage and any data gaps |

Notes that save a wrong call:
- There is no `compareWindow` on `top-drivers`; compare periods with
  `costs/monthly` or `trends` (its `changePercent` is on the previous period).
- `ownerId` keeps the costs a user owns, `userId` the costs a user caused.
- On `breakdown`, an unrecognized `groupBy` silently falls back to
  `resource_type`, and a wrong `resourceType` returns an empty breakdown. Pass
  exact values.
- On `costs/services`, `startDate` + `endDate` together form an explicit range
  and override `period`.

---

## 2. Budgets (read only)

Budgets are created and managed by administrators in the UI and by internal
platform services. Over REST you can **list and read** them, nothing else. The
backend filters the list by the caller's organization.

```bash
curl -s "${auth[@]}" "$BASE/finops/budgets?status=active" | jq '.data'
curl -s "${auth[@]}" "$BASE/finops/budgets/<budgetId>" | jq '.data'
```

| Endpoint | Params | Notes |
|---|---|---|
| `GET /finops/budgets` | `scopeLevel`, `status`, `q`, `limit`, `cursor` | `scopeLevel` one of `platform`, `organization`, `user`, `resourceGroup`, `resource`, `resourceType`, `tag`; `status` one of `active`, `paused`, `exhausted` |
| `GET /finops/budgets/:id` | path `id` | 404 if not in the caller's tenant |

There is no create, update, or delete for budgets on this API. Do not attempt one.

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
