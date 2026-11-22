# Addons

A Strongly **addon** is a managed data service (database, cache, message queue,
vector store) that the platform provisions and runs on Kubernetes for the user.
You pick a type, set CPU/memory/disk, and Strongly deploys it, manages
credentials, backups, and scaling, and hands you a connection string. Apps and
workflows consume an addon by id; they never manage the pod.

Read this when the task is: choosing and provisioning a managed store,
starting/stopping/scaling one, fetching its connection string or credentials,
scheduling it to save cost, backing it up or restoring a backup, wiring it
into an app, giving an app a least-privilege database role, or connecting
over verified TLS (section 13).

**Auth** follows `SKILL.md`. Outside Strongly send `X-API-Key` to `$HOST/api/v1`;
inside Strongly the base is `$STRONGLY_API_URL/api/v1` and the bearer is
auto-injected. Below, `$BASE` is whichever applies. Set once (outside Strongly):

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # Settings -> API Keys (addons:read, addons:write, addons:deploy)
# Inside Strongly instead: BASE="$STRONGLY_API_URL/api/v1"; auth=()   (no header, see SKILL.md)
```

All responses use the standard envelope (see `SKILL.md`): `data` on success, lists page with `cursor` / `meta.nextCursor`, and a failure is problem details whose `detail` and `code` to surface.

---

## 1. Discover: types you can create vs addons that exist  ← start here

Two different questions, two different endpoints. Do not confuse them.

```bash
# What KINDS of store can I spin up? (the create catalog, dynamic, read it, don't assume)
curl -s "${auth[@]}" "$BASE/addon-types" | jq '.data'

# What addons has the user ALREADY provisioned? (reuse these instead of creating another)
curl -s "${auth[@]}" "$BASE/addons" | jq '.data'
```

`GET /addon-types` returns each managed type with what kind of store it is,
what it is best for, and its engine `versions` (`defaultVersion` when none is named). Use it to **recommend** a type by reasoning about the data
need, not from a memorized list. Type keys are vendor keys, e.g. `postgres`
(**not** `postgresql`, which is the workflow node type), `mysql`, `mongodb`,
`redis`, `rabbitmq`, `neo4j`, `milvus`, `greenplum`, `surrealdb`, `kafka`,
`mqtt`, `duckdb` (pg_duckdb: PostgreSQL with the DuckDB engine for analytical SQL and
Parquet/CSV in S3; any Postgres client connects). Kafka and MQTT are also data source types (a broker the user runs
elsewhere): streaming workflow nodes and marketplace installs take either,
so offer an add-on only when the user has no broker of their own.

`GET /addons` lists existing addons (each a summary: label, type, status, version,
size; no connection details) and supports `q`, `type`, `status`, `limit`, `cursor`. Before provisioning a new store, list first and reuse when a
suitable one already exists.

---

## 2. Create an addon (async: create, then poll before you use it)

Provisioning returns immediately and finishes later. **Never hand out a
connection string or wire the addon into anything until its status is running.**

```bash
# Create. Required: label, type, cpu, memory, disk. Optional: description, and gpu (a count,
# as a string) with gpu_type (one of GET /compute/gpu-options): a GPU add-on runs on the AI pool.
ADDON_ID=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"label":"Orders DB","type":"postgres","cpu":"500m","memory":"1Gi","disk":"10Gi",
       "description":"Primary store for the orders app"}' \
  "$BASE/addons" | jq -r '.data._id')

# Poll live Kubernetes status until it reports running. It is "requested" until the deploy
# is accepted, then "deploying". Do NOT skip this.
until curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/status" | jq -e '.data.status=="running"' >/dev/null; do
  sleep 5
done
```

`type` must be a key from `GET /addon-types`; an unsupported value is rejected.
`version` is optional: one of the type's `versions` from `GET /addon-types`
(the add-on runs and records the type's `defaultVersion` when it is omitted;
any other value is rejected).
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

# CPU and memory by day over 30 days (Kubecost's hourly records): used, busiest hour, size.
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/time-series?window=30d" | jq '.data.points'
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
# Attach / detach an existing addon to a running app (ids from the add-on and app lists).
curl -s -X POST   "${auth[@]}" -H 'Content-Type: application/json' -d "{\"appId\":\"$APP_ID\"}" \
  "$BASE/addons/$ADDON_ID/connections" | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/addons/$ADDON_ID/connections/$APP_ID"
```

`connect` adds the addon to the app's `addons` set; `disconnect` removes it. Both
change the app as `PATCH $BASE/apps/:appId` with its `addons` would: the app's
owner must be able to use the addon, the addon must be running, and a running app
rolls out with the change at once with no downtime (`STRONGLY_SERVICES` is built
from the set at every rollout); a stopped app gets it when it starts. For how the app consumes the connection at runtime, see
`references/apps.md` section 4 (it appears under `services.addons.<type>`).

By default the app connects as the add-on's owner. For PostgreSQL, DuckDB, MySQL
and MongoDB add-ons, bind the app to a read-write database role instead and
turn on the owner connection only where it runs migrations (section 13).

---

## 8. Update and scale

```bash
# Change label, description, or resources (cpu, memory, disk). Send only the fields you want to change.
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"cpu":"1","memory":"2Gi","disk":"25Gi"}' \
  "$BASE/addons/$ADDON_ID" | jq '.data'
```

A resource change re-rolls the addon, so poll `GET /addons/:id/status` back to
running afterward.

---

## 9. Backups and restore

Backups are optional and off by default. Each one is taken with the database's
own export tool (pg_dumpall, mysqldump, mongodump, a Redis RDB snapshot, the
RabbitMQ definitions, a Neo4j Cypher export, a SurrealDB export, the Milvus
backup tool, every Kafka topic with its records and consumer group positions,
or the MQTT retained messages) and kept in the platform's backup storage. A
Kafka restore refuses while a consumer group has members: stop the consumers
first. Only a running addon
can be backed up or restored, and one backup or restore of an addon runs at a
time (a second request gets `422 action-in-progress`).

```bash
# Back up now. Answers the backup (its backupId); it runs in the background.
BACKUP_ID=$(curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/backups" | jq -r '.data.backupId')
# Follow it until it settles.
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/backups/$BACKUP_ID" | jq '.data | {status, sizeBytes, error}'

# Automatic backups: read them, or set all three fields.
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/backup-config" | jq '.data'
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"enabled":true,"schedule":"daily","retention":7}' \
  "$BASE/addons/$ADDON_ID/backup-config" | jq '.data'

# Every backup, newest first, a page at a time (meta.nextCursor -> ?cursor=).
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/backups" | jq '.data[] | {backupId, status, sizeBytes, error}'

# Restore a succeeded backup into the same addon (ask the user first): 202 with the restore.
RESTORE_ID=$(curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/backups/$BACKUP_ID/restore" | jq -r '.data.restoreId')
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/restores/$RESTORE_ID" | jq '.data | {status, error}'
# Every restore, newest first.
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/restores" | jq '.data'
```

`schedule` is `hourly`, `daily`, `weekly` or `monthly` (the first automatic
backup runs one interval after it is set); `retention` is how many successful
backups are kept, manual and scheduled, older ones being deleted.

A backup's `status` goes `starting`, `in_progress`, then `succeeded` (with
`sizeBytes`) or `failed` (with `error`); a scheduled run that could not start
is `skipped` with a `reason`. Poll `GET /addons/:addonId/backups/:id` until it settles.

A restore replaces everything the addon holds with what the backup holds:
data written after the backup is lost, and anything created since is removed.
The addon keeps running; its type's `restoreEffect` in `GET /addon-types` says
what connected apps see meanwhile (for example, PostgreSQL closes open
connections). A restore's
`status` goes `starting`, `in_progress`, then `succeeded` or `failed` (with
`error`, the step that failed and its output). Always confirm with the user
before restoring.

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

`startTime` and `stopTime` are `HH:MM` (24-hour) and must differ; a `stopTime`
earlier than `startTime` is the next morning (22:00 to 06:00 runs overnight
from each listed day). `daysOfWeek` uses 1 = Monday through 7 = Sunday.
`holidayCalendar` is `us` (the eleven federal holidays), `uk` (bank holidays of
England and Wales), or `none`. The GET response's `lastStartAt` / `lastStopAt`
are what the platform did, not settings. Outside the window the addon is
stopped, so anything depending on it should tolerate the downtime.

---

## 11. Sharing / permissions

```bash
# Who can reach it: owner, members (role editor | user), visibility
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/permissions" | jq '.data'
# Share with one user ("editor" may change it, "user" may only use it)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"userId":"<userId>","role":"user"}' "$BASE/addons/$ADDON_ID/permissions/members"
# Stop sharing with them
curl -s -X DELETE "${auth[@]}" "$BASE/addons/$ADDON_ID/permissions/members/<userId>"
# Everyone (in a multi-tenant deployment, everyone in its organization) may use it
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"visibility":"public"}' "$BASE/addons/$ADDON_ID/permissions"
```

Changing the addon stays with its owner and editors whatever its visibility.

---

## 12. Delete

```bash
curl -s -X DELETE "${auth[@]}" "$BASE/addons/$ADDON_ID"
```

Permanent: deletes the addon and removes its Kubernetes resources. Disconnect it
from any app first (section 7) so nothing is left pointing at a store that no
longer exists.

---

## 13. Database roles and TLS

### Roles (postgres, duckdb, mysql, mongodb)

A role is a database login on the add-on with a fixed preset. There are two
presets and no others (never a superuser):

| Preset | Allows | Does not allow |
|---|---|---|
| `read-only` | Read every table (PostgreSQL/DuckDB: every schema, sessions read-only; MySQL: `SELECT`; MongoDB: built-in `read`) | Any write, any schema change |
| `read-write` | Read, insert, update and delete rows (MongoDB: find, insert, update, remove) | Creating, altering or dropping tables, indexes or schemas; `TRUNCATE`; creating roles or databases; superuser |

Name: lowercase, `^[a-z][a-z0-9_]{2,62}$`, not starting `pg_` or `clone_`, not
the add-on's owner user or a reserved name (`postgres`, `root`, `admin`, ...).
The add-on must be running. Other add-on types are refused (409).

```bash
# Create: the password is in this answer ONCE and is never returned again.
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"orders_app","preset":"read-write"}' \
  "$BASE/addons/$ADDON_ID/roles" | jq '.data'           # -> the role (_id, name, preset, ...) with its password
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/roles" | jq '.data'            # roles + boundApps, no passwords
curl -s "${auth[@]}" "$BASE/addons/$ADDON_ID/roles/$ROLE_ID" | jq '.data'

# New password (shown once); running apps bound to the role restart to pick it up.
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/roles/$ROLE_ID/rotate-password" | jq '.data'
# Re-apply the preset's grants (picks up schemas created since the role was made).
curl -s -X POST "${auth[@]}" "$BASE/addons/$ADDON_ID/roles/$ROLE_ID/apply-privileges" | jq '.data'
# Delete (refused with 409 naming the apps while any app is bound to it).
curl -s -X DELETE "${auth[@]}" "$BASE/addons/$ADDON_ID/roles/$ROLE_ID"
```

Tables created by the owner later are covered automatically on PostgreSQL;
after the owner creates a new schema, call `apply-privileges`.

### Bind an app to a role; owner connection only for migrations

```bash
# Connect with a role (and, for the app that runs migrations, the owner connection too).
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"appId\":\"$APP_ID\",\"roleId\":\"$ROLE_ID\",\"adminConnection\":true}" \
  "$BASE/addons/$ADDON_ID/connections" | jq '.data'
# Change the binding of an app already connected (roleId null = owner connection again).
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"roleId\":\"$ROLE_ID\",\"adminConnection\":false}" \
  "$BASE/addons/$ADDON_ID/connections/$APP_ID" | jq '.data'
```

For a bound app the `STRONGLY_SERVICES` entry's `connection.connection_string`,
`connection.uri` and `auth.credentials` are the role's, and the entry carries
`role: { id, name, preset }`. With `adminConnection` it also carries
`admin_connection: { connection_string, uri, username, password }` (the owner).
The pattern: serve traffic with `connection.connection_string` (a `read-write`
role cannot change the schema), run migrations with `admin_connection`, and
turn `adminConnection` off for apps that do not migrate. An unbound app gets
the owner connection as before.

### TLS (postgres)

New PostgreSQL add-ons run TLS and require it. `PATCH /addons/:id` with
`{"requireTls": true|false}` turns the requirement on or off (running apps using
the add-on restart); an existing add-on gets TLS at its next restart. Once TLS
is active the entry has `connection.ssl = { mode: "verify-full", root_cert_path:
"/etc/strongly/addon-ca/ca.crt" }` and the connection string already carries
`sslmode=verify-full&sslrootcert=/etc/strongly/addon-ca/ca.crt`. The CA file is
mounted in every pod that gets `STRONGLY_SERVICES`. Always connect from the
entry, never a hard-coded host:

```python
import json, os, psycopg
pg = json.loads(os.environ["STRONGLY_SERVICES"])["services"]["addons"]["postgres"][0]
conn = psycopg.connect(pg["connection"]["connection_string"])     # verify-full already in it
# Migrations only (adminConnection on): psycopg.connect(pg["admin_connection"]["connection_string"])
```

```js
import fs from 'node:fs';
import pg from 'pg';
const s = JSON.parse(process.env.STRONGLY_SERVICES).services.addons.postgres[0];
const c = s.connection;
const ssl = c.ssl ? { ca: fs.readFileSync(c.ssl.root_cert_path, 'utf8'), servername: c.host,
                      rejectUnauthorized: true } : undefined;
// node-postgres: pass ssl as an object; do not also pass sslmode in the string.
const pool = new pg.Pool({ host: c.host, port: c.port, database: c.database,
  user: s.auth.credentials.username, password: s.auth.credentials.password, ssl });
```

---

## Endpoint reference

| Method | Path | What it does | Scope |
|---|---|---|---|
| GET | `/addon-types` | List the managed types you can create, with what each is best for | `addons:read` |
| GET | `/addons` | List existing addons (`q`, `type`, `status`, `limit`, `cursor`) | `addons:read` |
| GET | `/addons/stats` | The list's counts with its filters: `{ total, byStatus[{status, total}], byType[{type, total}] }` (`requested`: deploy not yet accepted), most first, not a page | `addons:read` |
| POST | `/addons` | Create an addon (`label`, `type`, `cpu`, `memory`, `disk`, `description?`) | `addons:write` |
| GET | `/addons/:id` | Get one addon's stored config | `addons:read` |
| PATCH | `/addons/:id` | Update label / description / resources / `requireTls` (postgres) | `addons:write` |
| DELETE | `/addons/:id` | Delete the addon and its K8s resources | `addons:write` |
| POST | `/addons/:id/start` | Start a stopped addon | `addons:deploy` |
| POST | `/addons/:id/stop` | Stop a running addon (keeps data) | `addons:deploy` |
| POST | `/addons/:id/restart` | Cycle the addon's pods | `addons:deploy` |
| POST | `/addons/:id/recover` | Re-deploy a failed/errored addon | `addons:deploy` |
| GET | `/addons/:id/status` | Live K8s pod state / readiness (poll this) | `addons:read` |
| GET | `/addons/:id/credentials` | Decrypted host/port/user/password/connection string | `addons:read` |
| GET | `/addons/:id/metrics` | Current CPU / memory / disk usage | `addons:read` |
| GET | `/addons/:id/time-series` | CPU and memory over time from Kubecost's hourly records (`cpuCores`, `cpuCoresPeak`, `cpuRequestCores`, `memoryBytes`, `memoryBytesPeak`, `memoryRequestBytes`, `runningMinutes`; null where it did not run); `window` `24h` (hourly points) or `7d`/`30d` (daily UTC points, the default `30d`); answers `{window, granularity, start, end, points[{timestamp, …}]}`, every bucket a point, a quiet one zero | `addons:read` |
| GET | `/addons/:id/logs` | Container logs (`lines`, `since`, `container`) | `addons:read` |
| POST | `/addons/:id/backups` | Trigger an immediate backup | `addons:write` |
| GET | `/addons/:id/backup-config` | Automated backup settings (`enabled`, `schedule`, `retention`, `lastBackup`, `nextBackup`) | `addons:read` |
| PUT | `/addons/:id/backup-config` | Configure automated backups (`enabled`, `schedule`, `retention`); answers the settings | `addons:write` |
| GET | `/addons/:id/backups` | Backups, newest first, cursor-paged (status, size, error) | `addons:read` |
| GET | `/addons/:addonId/backups/:id` | One backup (follow one you started) | `addons:read` |
| POST | `/addons/:addonId/backups/:id/restore` | Restore a succeeded backup into the addon (202 with the restore) | `addons:write` |
| GET | `/addons/:id/restores` | Restores, newest first, cursor-paged (status, error) | `addons:read` |
| GET | `/addons/:addonId/restores/:id` | One restore (follow one you started) | `addons:read` |
| POST | `/addons/:id/connections` | Attach the addon to an app (`appId`, `roleId?`, `adminConnection?`) | `addons:write` |
| PATCH | `/addons/:addonId/connections/:id` | Change an app's binding (`roleId` or null, `adminConnection`) | `addons:write` |
| DELETE | `/addons/:addonId/connections/:id` | Detach the addon from an app | `addons:write` |
| GET | `/addons/:addonId/roles` | Database roles with the apps bound to each (no passwords) | `addons:read` |
| POST | `/addons/:addonId/roles` | Create a role (`name`, `preset`); answers the password once | `addons:write` |
| GET | `/addons/:addonId/roles/:id` | One role (no password) | `addons:read` |
| DELETE | `/addons/:addonId/roles/:id` | Delete a role (409 while an app is bound to it) | `addons:write` |
| POST | `/addons/:addonId/roles/:id/rotate-password` | New password, shown once; bound running apps restart | `addons:write` |
| POST | `/addons/:addonId/roles/:id/apply-privileges` | Re-apply the preset's grants | `addons:write` |
| GET/PATCH | `/addons/:id/permissions` | Who can reach it / set `visibility` | `addons:read` / `addons:write` |
| POST | `/addons/:id/permissions/members` | Share with a user (`userId`, `role`) | `addons:write` |
| DELETE | `/addons/:addonId/permissions/members/:userId` | Stop sharing with a user | `addons:write` |
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
- [ ] Bind apps to a `read-write` role; give `adminConnection` only to the app that runs migrations (migrate with `admin_connection`, serve with `connection_string`).
- [ ] Connect to PostgreSQL with verify-full from the entry's `connection.ssl` (CA `/etc/strongly/addon-ca/ca.crt`), never a hard-coded host.
- [ ] On a failed addon: read `logs`, then `recover`. No fabricated success.
- [ ] Delete only after disconnecting from any app; deletion is permanent.
