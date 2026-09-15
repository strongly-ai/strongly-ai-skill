# Addons

A Strongly **addon** is a managed data service (database, cache, message queue,
vector store) that the platform provisions and runs on Kubernetes for the user.
You pick a type, set CPU/memory/disk, and Strongly deploys it, manages
credentials, backups, and scaling, and hands you a connection string. Apps and
workflows consume an addon by id; they never manage the pod.

Read this when the task is: choosing and provisioning a managed store,
starting/stopping/scaling one, fetching its connection string or credentials,
scheduling it to save cost, backing it up, or wiring it into an app.

**Auth** follows `SKILL.md`. Outside Strongly send `X-API-Key` to `$HOST/api/v1`;
inside Strongly the base is `$STRONGLY_API_URL/api/v1` and the bearer is
auto-injected. Below, `$BASE` is whichever applies. Set once (outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # Settings -> API Keys (addons:read, addons:write, addons:deploy)
# Inside Strongly instead: BASE="$STRONGLY_API_URL/api/v1"; auth=()   (no header, see SKILL.md)
```

All responses use the standard envelope: read `.data` on success, surface
`.error.message` on failure.

---

## 1. Discover: types you can create vs addons that exist  ← start here

Two different questions, two different endpoints. Do not confuse them.

```bash
# What KINDS of store can I spin up? (the create catalog, dynamic, read it, don't assume)
curl -s "${auth[@]}" "$BASE/addon-types" | jq '.data.types'

# What addons has the user ALREADY provisioned? (reuse these instead of creating another)
curl -s "${auth[@]}" "$BASE/addons" | jq '.data'
```

`GET /addon-types` returns each managed type with what kind of store it is and
what it is best for. Use it to **recommend** a type by reasoning about the data
need, not from a memorized list. Type keys are vendor keys, e.g. `postgres`
(**not** `postgresql`, which is the workflow node type), `mysql`, `mongodb`,
`redis`, `rabbitmq`, `neo4j`, `milvus`, `greenplum`, `surrealdb`.

`GET /addons` lists existing addons and supports `search`, `type`, `status`,
`limit`, `offset`. Before provisioning a new store, list first and reuse when a
suitable one already exists.

---

## 2. Create an addon (async: create, then poll before you use it)

Provisioning returns immediately and finishes later. **Never hand out a
connection string or wire the addon into anything until its status is running.**

```bash
# Create. Required: label, type, cpu, memory, disk. Optional: description.
ADDON_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"label":"Orders DB","type":"postgres","cpu":"500m","memory":"1Gi","disk":"10Gi",
       "description":"Primary store for the orders app"}' \
  "$BASE/addons" | jq -r '.data._id')

# Poll live Kubernetes status until it reports running/ready. Do NOT skip this.
until curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/status" | jq -e '.data.status=="running"' >/dev/null; do
  sleep 5
done
```

`type` must be a key from `GET /addon-types`; an unsupported value is rejected.
Use `postgres`, not `postgresql`. `cpu` is like `"500m"` or `"1"`, `memory` like
`"512Mi"` or `"1Gi"`, `disk` like `"1Gi"` or `"10Gi"`.

If provisioning lands in an error state, read the logs (section 6) and call
`recover` (section 5). Do not report success while status is anything but
running.

---

## 3. Inspect one addon and get its status

```bash
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID"          | jq '.data'   # stored config
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/status"   | jq '.data'   # live pod state / readiness
```

`GET /addons/:id` returns the stored record. `GET /addons/:id/status` queries
Kubernetes for the live pod state and readiness, and is what you poll after
create, start, restart, or recover.

---

## 4. Credentials and connection string

Only after status is running. This returns decrypted secrets, so treat the
output as sensitive and never log it.

```bash
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/credentials" | jq '.data'
# -> host, port, username, password, connection string
```

Prefer the connection string when one is present. This is also what an app
receives at runtime through `STRONGLY_SERVICES` (section 7), so an app rarely
needs to call this endpoint itself.

---

## 5. Lifecycle: start, stop, restart, recover

```bash
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/stop"      | jq '.data'   # scale down
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/start"     | jq '.data'   # deploy resources
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/restart"   | jq '.data'   # cycle pods
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/recover"   | jq '.data'   # re-deploy a failed addon
```

After `start`, `restart`, or `recover`, poll `GET /addons/:id/status` until
running before using the addon again. `stop` frees compute while keeping the
data volume, so a stopped addon can be started later. All four actions (`start`,
`stop`, `restart`, `recover`) require the `addons:deploy` scope.

---

## 6. Logs and metrics

```bash
# Container logs. Optional: lines (tail), since (ISO 8601), container (if multi-container).
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/logs?lines=200" | jq -r '.data'

# Current CPU / memory / disk usage.
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/metrics" | jq '.data'
```

Read logs first when an addon fails to provision or crash-loops.

---

## 7. Connect an addon to an app

An app consumes an addon by its id. Two ways, both leaving the app to read the
connection from `STRONGLY_SERVICES` (never hardcode a host or key):

- **At deploy time (preferred):** pass the addon id in the app's `addons` array
  on the create/upload call. See `references/apps.md` section 4 for how the app
  reads it back (match on `configId`, respect `internal: true`).
- **After the fact:** attach an existing addon to an already-deployed app.

```bash
# Attach / detach an existing addon to a running app (both are 24-char ObjectIds).
curl -s -X POST   "${auth[@]}" "$BASE/addons/$ADDON_ID/connect/$APP_ID" | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/addons/$ADDON_ID/connect/$APP_ID" | jq '.data'
```

`connect` injects the addon credentials into the app environment;
`disconnect` removes them. The addon must be running first. For how the app
consumes the connection at runtime, see `references/apps.md`.

---

## 8. Update and scale

```bash
# Change label, description, or resources (cpu, memory, disk). Send only the fields you want to change.
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"cpu":"1","memory":"2Gi","disk":"25Gi"}' \
  "$BASE/addons/$ADDON_ID" | jq '.data'
```

A resource change re-rolls the addon, so poll `GET /addons/:id/status` back to
running afterward.

---

## 9. Backups

```bash
# Trigger an immediate backup (e.g. a database snapshot).
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/backup" | jq '.data'

# Configure automated backups. All three fields are required.
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"enabled":true,"schedule":"0 2 * * *","retention":7}' \
  "$BASE/addons/$ADDON_ID/backup-config" | jq '.data'
```

`schedule` is a cron expression; `retention` is the number of backups to keep.

---

## 10. Scheduled windows (cost savings)

Run an addon only during set hours, stopping it outside them to cut compute
cost. Useful for dev and internal stores that do not need 24/7 uptime.

```bash
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/schedule" | jq '.data'

# enabled, timezone, startTime, stopTime, daysOfWeek are required.
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"enabled":true,"timezone":"America/New_York","startTime":"08:00","stopTime":"18:00",
       "daysOfWeek":[1,2,3,4,5],"skipHolidays":false,"holidayCalendar":"none"}' \
  "$BASE/addons/$ADDON_ID/schedule" | jq '.data'
```

`startTime` and `stopTime` are `HH:MM` (24-hour). `daysOfWeek` uses 1 = Monday
through 7 = Sunday. `holidayCalendar` is `us`, `uk`, or `none`. Outside the
window the addon is stopped, so anything depending on it should tolerate the
downtime.

---

## 11. Sharing / permissions

```bash
# Both fields required: isPublic (org-wide) and the allowedUsers list.
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"isPublic":false,"allowedUsers":["<userId>","<userId2>"]}' \
  "$BASE/addons/$ADDON_ID/permissions" | jq '.data'
```

`isPublic: true` makes the addon reachable by all org members; otherwise access
is limited to `allowedUsers`.

---

## 12. Delete

```bash
curl -s -X DELETE "${auth[@]}" "$BASE/addons/$ADDON_ID"
```

Permanent: deletes the addon and removes its Kubernetes resources. Disconnect it
from any app first (section 7) so nothing is left pointing at a store that no
longer exists.

---

## Endpoint reference

| Method | Path | What it does | Scope |
|---|---|---|---|
| GET | `/addon-types` | List the managed types you can create, with what each is best for | `addons:read` |
| GET | `/addons` | List existing addons (`search`, `type`, `status`, `limit`, `offset`) | `addons:read` |
| POST | `/addons` | Create an addon (`label`, `type`, `cpu`, `memory`, `disk`, `description?`) | `addons:write` |
| GET | `/addons/:id` | Get one addon's stored config | `addons:read` |
| PUT | `/addons/:id` | Update label / description / resources | `addons:write` |
| DELETE | `/addons/:id` | Delete the addon and its K8s resources | `addons:write` |
| POST | `/addons/:id/start` | Start a stopped addon | `addons:deploy` |
| POST | `/addons/:id/stop` | Stop a running addon (keeps data) | `addons:deploy` |
| POST | `/addons/:id/restart` | Cycle the addon's pods | `addons:deploy` |
| POST | `/addons/:id/recover` | Re-deploy a failed/errored addon | `addons:deploy` |
| GET | `/addons/:id/status` | Live K8s pod state / readiness (poll this) | `addons:read` |
| GET | `/addons/:id/credentials` | Decrypted host/port/user/password/connection string | `addons:read` |
| GET | `/addons/:id/metrics` | Current CPU / memory / disk usage | `addons:read` |
| GET | `/addons/:id/logs` | Container logs (`lines`, `since`, `container`) | `addons:read` |
| POST | `/addons/:id/backup` | Trigger an immediate backup | `addons:write` |
| PUT | `/addons/:id/backup-config` | Configure automated backups (`enabled`, `schedule`, `retention`) | `addons:write` |
| POST | `/addons/:id/connect/:appId` | Attach the addon to an app | `addons:write` |
| DELETE | `/addons/:id/connect/:appId` | Detach the addon from an app | `addons:write` |
| PUT | `/addons/:id/permissions` | Sharing (`isPublic`, `allowedUsers`) | `addons:write` |
| GET | `/addons/:id/schedule` | Get the scheduled start/stop window | `addons:read` |
| PUT | `/addons/:id/schedule` | Set a scheduled start/stop window | `addons:write` |

---

## Checklist
- [ ] Recommend a type from `GET /addon-types` (reason about the data need); use `postgres`, not `postgresql`.
- [ ] Reuse an existing addon (`GET /addons`) before creating another.
- [ ] Create with `label`, `type`, `cpu`, `memory`, `disk`; then **poll `GET /addons/:id/status` until running** before doing anything else.
- [ ] Fetch credentials / connection string only after running; treat the output as secret, never log it.
- [ ] After start / restart / recover / a resource update, poll back to running.
- [ ] Wire into an app by passing the addon id at deploy time (preferred) or `connect/:appId`; the app reads it from `STRONGLY_SERVICES` (see `references/apps.md`).
- [ ] On a failed addon: read `logs`, then `recover`. No fabricated success.
- [ ] Delete only after disconnecting from any app; deletion is permanent.
