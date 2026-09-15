# Data Sources

A Strongly **data source** is a connection to an **external** store the user
already runs (a Postgres/MySQL/SQL Server/Oracle database, a Snowflake/BigQuery/
Redshift warehouse, a Mongo/Elasticsearch/DynamoDB/Firestore/Redis store, or an
S3/MinIO/GCS/Azure object bucket). The user supplies the host and credentials;
the platform stores them encrypted and hands the connection to apps and workflows
by id. Strongly does not provision or run the store; it only connects to it.

Read this when the task is: registering an external database/warehouse/bucket,
listing what the user already has connected, testing a connection, introspecting
its tables or objects before a workflow reads from it, or wiring a data source
into an app. For preparing synthetic fine-tuning data, see [Data Forge](#8-data-forge-synthetic-training-data-prep).

**Auth** follows `SKILL.md`: outside Strongly send `X-API-Key` to `$HOST/api/v1`;
inside Strongly (or from a workspace) the bearer is auto-injected against
`$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever applies and, outside
Strongly:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
```

Every endpoint below is a real `/api/v1` route. Reads need the
`datasources:read` scope; writes need `datasources:write`.

---

## 1. Data source vs addon

Do not confuse the two. They look similar (both surface a connection to your app)
but they are opposite in ownership:

- **Data source** (this file): an **external, user-managed** connection. You bring
  the host and credentials; the platform stores and injects them. It never
  provisions or backs up the store; that is the external system's job.
- **Addon** (`references/addons.md`): a **managed store the platform provisions**
  and runs for you (Postgres, Mongo, Redis, and so on) inside the cluster, with
  its own lifecycle, resources, and backups.

Pick a data source to reach data that lives somewhere the user already owns. Pick
an addon when you want Strongly to stand up and operate the store.

---

## 2. Discover the type keys and required fields

`type` is a **vendor key**, and the create endpoint is the source of truth for the
accepted values. The keys enumerated by the API are: `postgres`, `mysql`, `mssql`,
`oracle`, `snowflake`, `bigquery`, `redshift`, `mongodb`, `elasticsearch`,
`dynamodb`, `firestore`, `redis`, and the object-storage keys `s3`, `minio`,
`gcs`, `azure-blob`. Any other value is rejected.

Watch the naming: it is **`postgres`, not `postgresql`** (`postgresql` is the
workflow NODE type, a different thing). Do not guess a key from the product name;
use the vendor key.

The `credentials` shape depends on the `type`. For a SQL database it is typically
`{ host, port, username, password, database }`; object stores take bucket/endpoint/
access-key fields; warehouses take their own. Confirm the exact fields for the
chosen type before creating rather than assuming a shape.

---

## 3. Create, list, get, update, delete

**Create.** Required: `name`, `label`, `type`, `credentials`. Optional:
`description`, `category`.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/datasources" -d '{
    "name": "warehouse-prod",
    "label": "Production Warehouse",
    "type": "postgres",
    "credentials": { "host": "db.example.com", "port": 5432,
                     "username": "reader", "password": "…", "database": "analytics" },
    "description": "Read replica for reporting",
    "category": "warehouse"
  }'                                         # -> data.dataSourceId
```

**List / get / update / delete.** List supports `search`, `type`, `category`,
`status`, plus `limit`/`offset`/`sort`. List and get responses **never include
credentials** (they are stripped server-side).

```bash
curl -s "${auth[@]}" "$BASE/datasources?type=postgres&search=warehouse"   # list
curl -s "${auth[@]}" "$BASE/datasources/$DS_ID"                           # get one (no creds)
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/datasources/$DS_ID" -d '{"label":"Warehouse (RO)"}'             # partial update
curl -s -X DELETE "${auth[@]}" "$BASE/datasources/$DS_ID"                # delete
```

Update accepts the same fields as create (`name`, `label`, `type`, `credentials`,
`description`, `category`); send only what changes.

---

## 4. Test the connection and check health

Two distinct calls, do not mix them up:

- **Active probe** `POST /datasources/:id/test` opens a live connection now and
  returns the result. Run this after create or after changing credentials.
- **Health snapshot** `GET /datasources/:id/status` is read-only. It returns
  whatever the most recent test recorded on the row (`status`, `lastTestedAt`,
  `lastError`, `type`, `updatedAt`) without opening a new connection.

```bash
curl -s -X POST "${auth[@]}" "$BASE/datasources/$DS_ID/test"    # live probe -> result
curl -s "${auth[@]}" "$BASE/datasources/$DS_ID/status"          # last-known health
```

Report the real result. If `test` fails, surface the error and stop; do not claim
the source is connected.

---

## 5. Inspect the schema and browse objects

Before a workflow database node or an input mapping reads from a source, learn its
shape:

- `GET /datasources/:id/metadata` lists the tables/schemas (relational and
  warehouse) or collections (mongodb) the source exposes. Start here when you do
  not know the table names.
- `GET /datasources/:id/table-columns?table=<name>&schema=<optional>` returns one
  table's columns (name, type, nullable, and so on). Supported for the SQL and
  warehouse types (`postgres`, `mysql`, `mssql`, `oracle`, `redshift`,
  `snowflake`, `bigquery`) and for `mongodb` collection fields; other types return
  a not-implemented error.
- `GET /datasources/:id/objects?bucket=<opt>&prefix=<opt>` lists objects and
  folder prefixes inside an object-storage source (`s3`, `minio`, `gcs`,
  `azure-blob`). Omit `bucket` to use the source's configured bucket; pass
  `prefix` to descend into a folder. This is the discovery step before pointing a
  workflow or an AutoML import at a specific object key. It is not for database
  types (use `metadata` for those).

```bash
curl -s "${auth[@]}" "$BASE/datasources/$DS_ID/metadata"                       # tables/collections
curl -s "${auth[@]}" "$BASE/datasources/$DS_ID/table-columns?table=orders&schema=public"
curl -s "${auth[@]}" "$BASE/datasources/$DS_ID/objects?prefix=exports/"        # object store
```

---

## 6. Credentials and sharing

- `GET /datasources/:id/credentials` returns the **decrypted** credentials
  (`datasources:read`). List and get never expose them; this is the only endpoint
  that does. Treat the response as sensitive, never log it.
- `PUT /datasources/:id/permissions` sets sharing. Required body: `allowAllUsers`
  (boolean, whether every user may use it) and `allowedUsers` (array of user ids).

```bash
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/datasources/$DS_ID/permissions" \
  -d '{"allowAllUsers": false, "allowedUsers": ["<userId1>","<userId2>"]}'
```

---

## 7. Wire a data source into an app or workflow

You connect a data source by its **id**, not by copying its credentials.

- **Apps.** Pass the id in the `dataSources` array at app create/upload time. It
  then arrives in the running app under `STRONGLY_SERVICES` (a JSON env var), so
  the app reads the connection from there instead of hardcoding a host or
  password. See `references/apps.md` (Wiring: `STRONGLY_SERVICES`) for how to read
  it and match on `configId`.
- **Workflows.** A database SOURCE or destination node references the data source
  by id and reads from it at run time. Use `metadata` and `table-columns` (Section
  5) to learn the schema before building the node's query or mappings. See
  `references/workflows.md`.

Get the id from `GET /datasources` (or the `dataSourceId` returned by create).
Never paste credentials into an app config or a node; wire the id and let the
platform inject the connection.

---

## 8. Data Forge (synthetic training-data prep)

Data Forge is a separate feature under `/data-forge`. It is not about connecting
external stores; it prepares **synthetic training data for fine-tuning**. The arc:
create a project, upload source documents, parse them into chunks, generate Q/A
pairs with a teacher LLM, review the pairs, then export the accepted set as a
dataset. Reads need `data-forge:read`, writes need `data-forge:write`.

**Projects.**

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/data-forge/projects" -d '{"name":"Handbook QA","description":"…"}'   # -> project
curl -s "${auth[@]}" "$BASE/data-forge/projects"                              # list
curl -s "${auth[@]}" "$BASE/data-forge/projects/$P_ID"                        # get (counts, config, exports)
```

**Documents (two-step upload).** Get a presigned URL, PUT the bytes to it, then
register the document with the returned `s3_key`.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/data-forge/projects/$P_ID/upload-url" \
  -d '{"fileName":"handbook.pdf","mimeType":"application/pdf"}'      # -> upload URL + s3_key
# PUT the file bytes to the returned URL, then:
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/data-forge/projects/$P_ID/documents" \
  -d '{"name":"handbook.pdf","mime_type":"application/pdf","file_size":12345,"s3_key":"…"}'
```

**Parse, generate, review, export.** Parse documents into chunks, then start a
generation with a teacher model (`teacher_model_id` from
`GET /data-forge/available-models`, `output_format` e.g. `qa`). Generation is
async; poll the generation by id.

```bash
curl -s -X POST "${auth[@]}" "$BASE/data-forge/projects/$P_ID/parse"          # -> chunks
curl -s "${auth[@]}" "$BASE/data-forge/available-models"                      # teacher models
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  "$BASE/data-forge/projects/$P_ID/generate" \
  -d '{"teacher_model_id":"<id>","output_format":"qa","pairs_per_chunk":3}'   # -> generation
curl -s "${auth[@]}" "$BASE/data-forge/generations/$G_ID"                     # poll until complete
```

Review the pairs (`GET .../pairs`, filter by `status`/`quality_min`/`difficulty`),
edit or accept/reject them (`PUT /data-forge/pairs/:id`, or
`POST .../pairs/bulk-action` with `action` + `pair_ids`), then export the accepted
set (`POST .../export` with a `format` such as `jsonl`) and fetch the versioned
result (`GET .../export/:version`). `GET .../analytics` gives status/quality/
difficulty distributions; `GET .../generations/:id/logs` helps debug a stalled run.

---

## 9. Endpoint reference

Data sources:

| Method | Path | Purpose |
|---|---|---|
| GET | `/datasources` | List (filter by `search`, `type`, `category`, `status`; paginated) |
| POST | `/datasources` | Create (`name`, `label`, `type`, `credentials` required) |
| GET | `/datasources/:id` | Get one (credentials stripped) |
| PUT | `/datasources/:id` | Update (partial) |
| DELETE | `/datasources/:id` | Delete |
| POST | `/datasources/:id/test` | Active connection probe |
| GET | `/datasources/:id/status` | Read-only health snapshot |
| GET | `/datasources/:id/metadata` | List tables/schemas/collections |
| GET | `/datasources/:id/table-columns` | Introspect one table's columns (`table` required) |
| GET | `/datasources/:id/objects` | Browse an object-storage bucket (`bucket`, `prefix`) |
| GET | `/datasources/:id/credentials` | Decrypted credentials (sensitive) |
| PUT | `/datasources/:id/permissions` | Set sharing (`allowAllUsers`, `allowedUsers`) |

Data Forge:

| Method | Path | Purpose |
|---|---|---|
| GET / POST | `/data-forge/projects` | List / create projects |
| GET / PUT / DELETE | `/data-forge/projects/:id` | Get / update / delete a project |
| POST | `/data-forge/projects/:id/upload-url` | Presigned upload URL for a document |
| GET / POST | `/data-forge/projects/:id/documents` | List / register documents |
| DELETE | `/data-forge/projects/:id/documents/:docId` | Delete a document |
| GET | `/data-forge/projects/:id/chunks` | List parsed chunks (paginated) |
| PUT | `/data-forge/projects/:id/chunks/:chunkId` | Edit a chunk |
| POST | `/data-forge/projects/:id/parse` | Parse documents into chunks |
| POST | `/data-forge/projects/:id/generate` | Start a Q/A generation run |
| GET | `/data-forge/projects/:id/generations` | List generation runs |
| GET | `/data-forge/generations/:id` | Poll a generation run |
| GET | `/data-forge/generations/:id/logs` | Generation run logs |
| POST | `/data-forge/generations/:id/cancel` | Cancel a run |
| GET | `/data-forge/projects/:id/pairs` | List Q/A pairs for review (filterable) |
| PUT | `/data-forge/pairs/:id` | Edit / set status on a pair |
| POST | `/data-forge/projects/:id/pairs/bulk-action` | Accept/reject many pairs |
| POST | `/data-forge/projects/:id/export` | Export accepted pairs as a dataset |
| GET | `/data-forge/projects/:id/export/:version` | Get a versioned export |
| GET | `/data-forge/projects/:id/analytics` | Project analytics |
| GET | `/data-forge/available-models` | Teacher models for generation |

---

## Checklist
- [ ] Data source (external, you bring credentials) vs addon (platform-provisioned) chosen correctly; addons live in `references/addons.md`.
- [ ] `type` is the vendor key from Section 2 (`postgres`, not `postgresql`); `credentials` shape matches the type.
- [ ] After create or a credential change, run `POST /datasources/:id/test` and report the real result; do not claim connected on a failed probe.
- [ ] Introspect with `metadata` then `table-columns` (databases) or `objects` (object stores) before a workflow reads from the source.
- [ ] Credentials never pasted into app configs or nodes; wire the data source **id** (via `dataSources` -> `STRONGLY_SERVICES`, see `references/apps.md`).
- [ ] `GET /datasources/:id/credentials` output treated as sensitive, never logged.
- [ ] Data Forge is training-data prep, not a store connection; generation is async, poll the generation by id before exporting.
