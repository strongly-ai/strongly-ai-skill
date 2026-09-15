# Marketplace

The Strongly **Marketplace** is a catalog of ready-to-run **offerings** (apps and
agents). A user browses the catalog, reads an offering's deploy config, license,
and reviews, then **deploys** it into their own account. A deployed offering
becomes a normal Strongly **app** (built, deployed to Kubernetes, served behind
the proxy), so once it is running you manage it exactly like any other app. The
platform also ships installable **plugins** (platform extensions such as DataHub)
that you install into your account rather than deploy as an app; see §6.

Read this when the task is: browsing/searching the catalog, inspecting an
offering before install, **deploying an offering and polling it to done**,
listing what the user already deployed, reporting metered **usage** from a
running offering, or installing/managing a **plugin**.

> The catalog calls each listing a "marketplace item"; the usage API calls the
> same thing an "offering" (its `offeringId` is the app's `appName`). They are
> the same object. Item routes are `/marketplace/items/*`; the usage route is
> `/offering-usage/events`.

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key: $STRONGLY_API_KEY"`
to `$HOST/api/v1`; inside Strongly the bearer is auto-injected at
`$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever applies, and
`auth=(-H "X-API-Key: $STRONGLY_API_KEY")` outside Strongly. Read scopes are
`marketplace:read`; deploy, reviews, and plugin install/enable/disable/uninstall
need `marketplace:deploy`; usage needs `offering-usage:write`; the
listing-management routes need `marketplace:admin`.

---

## 1. Browse the catalog

List is paginated and filterable. Filters: `search` (matches name, description,
tags), `vertical` (category), `type` (`app` or `agent`), `featured=true`, plus
`limit`, `offset`, `sort`.

```bash
# List / search / filter
curl -s "${auth[@]}" "$BASE/marketplace/items?type=app&featured=true&limit=20" | jq '.data'
curl -s "${auth[@]}" "$BASE/marketplace/items?search=resume&vertical=HR"        | jq '.data'

# Categories with counts (to build a vertical filter)
curl -s "${auth[@]}" "$BASE/marketplace/verticals" | jq '.data'

# One offering, full detail
ITEM_ID=68b0...                                  # a 24-char item id from the list
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID" | jq '.data'
```

Before deploying, inspect the offering:

```bash
# The deploy.json the offering ships (the deploy wizard it declares, see references/apps.md §6)
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID/deploy-config" | jq '.data'

# License text, and reviews
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID/license"  | jq -r '.data'
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID/reviews"  | jq '.data'
```

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/marketplace/items` | `marketplace:read` | List/search offerings (`search`, `vertical`, `type`, `featured`, `limit`, `offset`, `sort`) |
| GET | `/marketplace/verticals` | `marketplace:read` | Categories with item counts |
| GET | `/marketplace/items/:id` | `marketplace:read` | Full detail for one offering |
| GET | `/marketplace/items/:id/deploy-config` | `marketplace:read` | The offering's `deploy.json` |
| GET | `/marketplace/items/:id/license` | `marketplace:read` | License text |
| GET | `/marketplace/items/:id/reviews` | `marketplace:read` | Reviews for the offering |
| POST | `/marketplace/items/:id/reviews` | `marketplace:deploy` | Add a review (`rating` 1-5, `title`, `comment`) |

```bash
# Leave a review (rating must be 1..5)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"rating":5,"title":"Great","comment":"Deployed in minutes."}' \
  "$BASE/marketplace/items/$ITEM_ID/reviews"
```

---

## 2. Check what you can wire in (ground the config)

The deploy wizard the offering declares (from `deploy-config` above) may ask the
user to pick an existing addon or an AI model. List the real ones the user has
so you configure the deploy against what actually exists, never a guessed id.

```bash
# Existing provisioned addons (running/deploying) + compatible object-store data
# sources, grouped by type, things you can CONNECT to the offering.
curl -s "${auth[@]}" "$BASE/marketplace/available-addons" | jq '.data'

# AI models available to attach to the offering.
curl -s "${auth[@]}" "$BASE/marketplace/available-models" | jq '.data'
```

`available-addons` lists services to connect, not a catalog of addon types to
create. To provision a new addon first, see `references/addons.md`.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/marketplace/available-addons` | `marketplace:read` | User's connectable addons + object-store data sources, by type |
| GET | `/marketplace/available-models` | `marketplace:read` | AI models available to attach |

---

## 3. Deploy an offering  ← poll it to done, never assume success

Deploy is **async**: the call returns **202 Accepted** immediately and the build
runs in the background. Body requires `appName` (the name for the new app) and a
`config` object. `config` must include `marketplaceItemId` and
`termsAccepted: true`; the rest of `config` carries the wizard selections the
offering declared (resources, addons, models, permissions) grounded from §1 and
§2. Missing `appName`/`config` is a 400, missing `marketplaceItemId` a 400, and
`termsAccepted` not true a 422.

```bash
# Kick off the deploy (returns 202, body echoes appName + marketplaceItemId)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"appName":"my-resume-app","config":{"marketplaceItemId":"'"$ITEM_ID"'","termsAccepted":true}}' \
  "$BASE/marketplace/deploy" | jq '.data'
```

Then **poll progress by the marketplace item id** (`$ITEM_ID`), because progress
is tracked on the offering. Use the lightweight status for a percentage, or the
full deployment for created resources. Do not report success until `status` is
`complete` (or the payload's `deployed` is true).

```bash
# Lightweight: status + percentage
curl -s "${auth[@]}" "$BASE/marketplace/deployments/$ITEM_ID/status" | jq '.data'

# Full: progress, result (result.appId when done), createdResources, error
curl -s "${auth[@]}" "$BASE/marketplace/deployments/$ITEM_ID" | jq '.data'
```

`status` values: `complete`, `failed`, `none` (nothing in progress and not yet
deployed), or an in-progress status while the build runs (`stepMessage` carries
the human-readable step). On `failed`, read the `error` field. Progress
`currentStep` maps to `percentage` as:

| currentStep | % | Stage |
|---|---|---|
| 0 | 5 | Configuration |
| 1 | 20 | Addons |
| 1.5 | 30 | Seeding |
| 2 | 40 | ML Models |
| 2.5 | 50 | Workflows |
| 3 | 65 | Downloading app |
| 4 | 80 | Building |
| 5 | 90 | Creating project |
| 6 | 100 | Complete |

List everything the user has deployed, and control an in-progress deploy:

```bash
curl -s "${auth[@]}" "$BASE/marketplace/deployments" | jq '.data'                        # all my deployments
curl -s -X POST "${auth[@]}" "$BASE/marketplace/deployments/$ITEM_ID/cancel"             # cancel in-progress
curl -s -X POST "${auth[@]}" "$BASE/marketplace/deployments/$ITEM_ID/clear-progress"     # clear stale progress
```

| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/marketplace/deploy` | `marketplace:deploy` | Start a deploy (`appName`, `config`); returns 202 |
| GET | `/marketplace/deployments` | `marketplace:deploy` | List the user's deployed offerings |
| GET | `/marketplace/deployments/:id` | `marketplace:deploy` | Full deploy info (progress, result, createdResources) |
| GET | `/marketplace/deployments/:id/status` | `marketplace:deploy` | Lightweight status + percentage |
| POST | `/marketplace/deployments/:id/cancel` | `marketplace:deploy` | Cancel an in-progress deploy |
| POST | `/marketplace/deployments/:id/clear-progress` | `marketplace:deploy` | Clear stale progress data |

`:id` on the deployment routes is the **marketplace item id**, not an app id.

---

## 4. After deploy: it is a regular app

When `status` is `complete`, the full deployment payload's `result.appId` is the
new app. From there it behaves like any Strongly app: it is served behind the
proxy at `STRONGLY_URL`, reads the signed-in user from a JWT, and gets wired
connections via `STRONGLY_SERVICES`. Manage it (status, logs, env, start/stop,
versions) with the `/apps` routes, and follow the proxy/asset, identity, and
`deploy.json` guidance in **`references/apps.md`** (that is where the manifest
you saw in `deploy-config` and the proxy behavior are documented in full).

---

## 5. Report metered usage from a running offering

A deployed offering that is billed per use emits **one usage event** at the
moment of use. The event is idempotent per `idempotencyKey`, so a retry never
double-counts.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"offeringId":"my-resume-app","meterKey":"resumes","quantity":1,
       "idempotencyKey":"resume-8f21c-2026-09-15"}' \
  "$BASE/offering-usage/events" | jq '.data'
```

Required: `offeringId` (the app's `appName`), `meterKey`, `quantity` (a positive
finite number), `idempotencyKey` (non-empty string). Optional `occurredAt`
(ISO-8601; defaults to ingest time).

Responses and rules:
- **201** `{ eventId, deduplicated: false }` on a new event; **200**
  `{ deduplicated: true }` when the same `idempotencyKey` was already recorded.
- The org is taken from the authenticated key's context, **never** the body: an
  app can only meter its own org (missing org context is a **403**).
- `meterKey` must be a metered item on the org's live offering subscription. No
  live subscription is a **422** (`no-subscription`); an unknown meter is a
  **422** (`unknown-meter`, and the error lists the billed meter keys).
- Non-positive/non-finite `quantity` or an empty `idempotencyKey` is a **422**;
  a bad `occurredAt` is a **422**.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/offering-usage/events` | `offering-usage:write` | Record one metered usage event (idempotent) |

---

## 6. Plugins: installable platform extensions

A **plugin** is a platform extension you install into your account (not deployed
as an app). Each plugin declares a config schema and feature toggles; once
installed and enabled it augments the platform. The current example is
**DataHub**, which pushes workflow lineage and ML model / AutoML / drift metadata
to a DataHub catalog. Plugins live under `/plugins/*`.

Managing plugins is restricted: in single-tenant only an admin may install or
manage them; in multitenant an admin or a developer may (scoped to their org). A
call without that access returns **403**.

```bash
# Browse the plugin catalog (each entry: id, displayName, description,
# configSchema[], features[]).
curl -s "${auth[@]}" "$BASE/plugins" | jq '.data.plugins'

# What is already installed (secrets are never returned).
curl -s "${auth[@]}" "$BASE/plugins/instances" | jq '.data.instances'
```

Install by plugin `id`. `values` is a flat map keyed by the plugin's
`configSchema` fields; `features` is a map of feature id to boolean (defaults
apply when omitted). Re-installing an already-installed plugin updates its config
and re-enables it. Required config fields are enforced.

```bash
# Install / configure DataHub (values.datahubBaseUrl + values.authMode).
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"values":{"datahubBaseUrl":"http://datahub-gms:8080","authMode":"pat","datahubToken":"<pat>"},
       "features":{"lineage":true,"modelSync":true}}' \
  "$BASE/plugins/datahub/install" | jq '.data'

# Toggle without uninstalling, then uninstall.
curl -s -X POST "${auth[@]}" "$BASE/plugins/datahub/disable" | jq '.data'
curl -s -X POST "${auth[@]}" "$BASE/plugins/datahub/enable"  | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/plugins/datahub"       | jq '.data'
```

Errors on install: a missing required config field is a **400** (`config-invalid`);
an unknown plugin id is a **404** (`plugin-not-found`); no access is a **403**.
Enable/disable/uninstall on a plugin that is not installed is a **404**
(`NOT_INSTALLED`).

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/plugins` | `marketplace:read` | List installable plugins (schema + features) |
| GET | `/plugins/instances` | `marketplace:read` | List installed plugin instances the caller can see |
| POST | `/plugins/:id/install` | `marketplace:deploy` | Install/configure a plugin (`values`, `features`); returns 201 |
| POST | `/plugins/:id/enable` | `marketplace:deploy` | Enable an installed plugin |
| POST | `/plugins/:id/disable` | `marketplace:deploy` | Disable an installed plugin without uninstalling |
| DELETE | `/plugins/:id` | `marketplace:deploy` | Uninstall a plugin |

---

## 7. Manage listings (admin only)

Creating/editing catalog listings is `marketplace:admin`. Create requires
`name`, `description`, `vendor`, `type` (`app` or `agent`), `vertical`.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/marketplace/items` | `marketplace:admin` | Create a listing |
| PUT | `/marketplace/items/:id` | `marketplace:admin` | Update a listing |
| DELETE | `/marketplace/items/:id` | `marketplace:admin` | Delete a listing |

---

## Checklist
- [ ] Browse/filter with `GET /marketplace/items` (`search`, `vertical`, `type`, `featured`); read one with `/items/:id`.
- [ ] Inspect `/deploy-config`, `/license`, `/reviews` before installing.
- [ ] Ground the deploy `config` against real `available-addons` / `available-models`, never a guessed id.
- [ ] Deploy needs `appName` + `config` with `marketplaceItemId` and `termsAccepted: true`; it returns 202.
- [ ] Poll `/marketplace/deployments/:id/status` (by the marketplace item id) until `status` is `complete`; never claim success before that; read `error` on `failed`.
- [ ] Once complete, treat `result.appId` as a normal app and use `references/apps.md` (`/apps` routes, proxy, identity, manifest).
- [ ] Usage events: one per use, unique `idempotencyKey`, positive `quantity`; a 200 `deduplicated:true` is success, not an error.
- [ ] Plugins: browse `GET /plugins`, install by id with `values` matching the plugin's `configSchema` (`marketplace:deploy`); enable/disable/uninstall the same way; managing them needs admin (or developer in multitenant).
