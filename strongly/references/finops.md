# FinOps

Strongly **FinOps** tracks what the platform spends and lets you act on it. Costs
come from Kubecost and the platform ledger; you **query** them by dimension and
time. **Budgets** are read only over REST. **Resource groups** and **Schedules**
are configuration you create and manage (schedules auto-stop resources off-hours
to save money).

Read this when the task is: reporting spend or trends, finding cost drivers or
anomalies, checking savings, listing budgets, organizing resources into groups
for cost rollups, or scheduling resources to stop and start on a timetable.

**Auth** follows `SKILL.md`. Outside Strongly send `X-API-Key` to `$HOST/api/v1`;
inside Strongly the base is `$STRONGLY_API_URL/api/v1` and the bearer is
auto-injected. Below, `$BASE` is whichever applies. Set once (outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
```

**Scopes.** Reads need `finops:read`; creating or changing resource groups and
schedules needs `finops:write`. Every response is the standard envelope
(`{ success, data }`, lists add `pagination`); read `data`, surface `error.message`.

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
  `resource_type` (default), `resource_id`, `namespace`, `solution`, `org`,
  `user`. Filter to one `resourceType` (`app`, `addon`, `workflow`, `workspace`,
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
| `GET /finops/costs/trends` | `window`, `granularity` (`hourly`\|`daily`\|`monthly`) | Time series of `{ timestamp, cost }` |
| `GET /finops/costs/monthly` | `months`, `year` | Monthly entries + average/highest/lowest summary |
| `GET /finops/costs/daily` | `startDate`, `endDate`, `resourceType` | Daily entries + total/average/trend |
| `GET /finops/costs/breakdown` | `window`, `groupBy`, `resourceType`, `orgId`, `userId` | Per-group `total_cost` + cpu/ram/gpu/storage/network split |
| `GET /finops/costs/services` | `period`, `startDate`, `endDate` | Breakdown by resource type over a window or explicit range |
| `GET /finops/costs/top-drivers` | `window`, `limit` | Ranked resources with GPU cost + efficiency |
| `GET /finops/costs/realtime` | `window`, `aggregate`, `namespace` | Live Kubecost cost items |
| `GET /finops/costs/historical` | `startDate`, `endDate`, `groupBy`, `orgId`, `userId` | Stored historical cost data |
| `GET /finops/costs/efficiency` | `window`, `namespace`, `aggregate` | Resource efficiency metrics |
| `GET /finops/costs/forecast` | `months` | `historical`, `predictions`, growth/confidence analysis |
| `GET /finops/costs/anomalies` | `days`, `threshold` | Detected anomalies for the window |
| `GET /finops/costs/savings` | `category`, `minSavings` | Rightsizing recommendations + total potential savings |
| `GET /finops/data-health` | (none) | Cost-collection coverage and any data gaps |

Notes that save a wrong call:
- There is no `groupBy` on `trends` and no `compareWindow` on `top-drivers`.
  Group with `breakdown`; compare month over month with `costs/monthly` or
  `trends`.
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
| `GET /finops/budgets` | `scopeLevel`, `status`, `search`, `limit`, `offset` | `scopeLevel` one of `platform`, `organization`, `user`, `resourceGroup`, `resource`, `resourceType`, `tag`; `status` one of `active`, `paused`, `exhausted` |
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
| `/finops/resource-groups` | GET | `finops:read` | query: `search`, `status`, `limit`, `offset` |
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

A **resource schedule** starts and stops resources on a daily timetable so they
are not running (and billing) off-hours. Full CRUD, plus pause/resume, run-now,
and history. Reads need `finops:read`; mutations need `finops:write`.

```bash
# Create: name, scope, schedule all required
SID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{
  "name": "Dev stop overnight",
  "scope": { "level": "resourceGroup", "resourceGroupId": "'"$GID"'" },
  "schedule": {
    "timezone": "America/New_York",
    "daysOfWeek": [1,2,3,4,5],
    "startTime": "08:00",
    "stopTime": "19:00"
  }
}' "$BASE/finops/schedules" | jq -r '.data._id')

# Pause / resume / run immediately
curl -s -X POST "${auth[@]}" "$BASE/finops/schedules/$SID/pause"
curl -s -X POST "${auth[@]}" "$BASE/finops/schedules/$SID/resume"
curl -s -X POST "${auth[@]}" "$BASE/finops/schedules/$SID/execute"

# Execution history
curl -s "${auth[@]}" "$BASE/finops/schedules/$SID/history?limit=20" | jq '.data'
```

`scope` shape: `level` is `platform` (all resources), `user` (also pass
`userId`), or `resourceGroup` (also pass `resourceGroupId`).

`schedule` shape: `timezone` (IANA name), `daysOfWeek` (integers, `0`=Sunday to
`6`=Saturday), and `startTime` / `stopTime` as `"HH:MM"` 24-hour local strings.
Supply at least one of start/stop; the resource starts at `startTime` and stops
at `stopTime`.

| Endpoint | Method | Scope | Notes |
|---|---|---|---|
| `/finops/schedules` | GET | `finops:read` | query: `search`, `status`, `scopeLevel`, `enabled` (`"true"`\|`"false"`), `limit`, `offset` |
| `/finops/schedules` | POST | `finops:write` | body: `name`, `scope`, `schedule` (+ optional `description`) |
| `/finops/schedules/:id` | GET | `finops:read` | path `id` |
| `/finops/schedules/:id` | PUT | `finops:write` | path `id`; body `name`, `scope`, `schedule`, `description` |
| `/finops/schedules/:id` | DELETE | `finops:write` | path `id` |
| `/finops/schedules/:id/pause` | POST | `finops:write` | Stop firing until resumed |
| `/finops/schedules/:id/resume` | POST | `finops:write` | Re-enable a paused schedule |
| `/finops/schedules/:id/execute` | POST | `finops:write` | Run the start/stop action now |
| `/finops/schedules/:id/history` | GET | `finops:read` | query `limit`; past executions |

---

## Checklist
- [ ] Reads use `finops:read`; resource-group and schedule mutations use `finops:write`.
- [ ] Match the cost question to the endpoint: series (`trends`), grouped (`breakdown`), ranked (`top-drivers`), forecast/anomalies/savings/efficiency for their names.
- [ ] Use exact `groupBy` / `resourceType` values on `breakdown` (wrong values fall back or return empty).
- [ ] Budgets are list/get only; never attempt create/update/delete on them.
- [ ] Removing a group member requires `resourceType` in the query, not just the id.
- [ ] Schedule `scope.level` drives which extra id you pass (`userId` or `resourceGroupId`); `schedule` needs `timezone`, `daysOfWeek`, and at least one of `startTime`/`stopTime`.
- [ ] After `execute`, read `schedules/:id/history` to confirm the run rather than assuming it fired.
