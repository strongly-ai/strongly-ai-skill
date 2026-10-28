# Marketplace

The Strongly **Marketplace** is a catalog of ready-to-run **offerings** (apps and
agents). A user browses the catalog, reads an offering's deploy config and
license, then **deploys** it into their own account. A deployed offering
becomes a normal Strongly **app** (built, deployed to Kubernetes, served behind
the proxy), so once it is running you manage it exactly like any other app. The
platform also ships installable **plugins** (platform extensions such as DataHub)
that you install into your account rather than deploy as an app; see §6.

Read this when the task is: browsing/searching the catalog, inspecting an
offering before install, **deploying an offering and polling it to done**,
listing what the user already deployed, reporting metered **usage** from a
running offering, managing an organization's **offering subscription** (admin), or
installing/managing a **plugin**.

> The catalog calls each listing a "marketplace item"; the usage API calls the
> same thing an "offering" (its `offeringId` is the app's `appName`). They are
> the same object. Item routes are `/marketplace/items/*`; the usage route is
> `/marketplace/usage-events`.

**Auth** follows `SKILL.md`: outside Strongly send `-H "X-API-Key: $STRONGLY_API_KEY"`
to `$HOST/api/v1`; inside Strongly the bearer is auto-injected at
`$STRONGLY_API_URL/api/v1`. Below, `$BASE` is whichever applies, and
`auth=(-H "X-API-Key: $STRONGLY_API_KEY")` outside Strongly. Read scopes are
`marketplace:read`; deploy and plugin install/change/uninstall
need `marketplace:deploy`; usage needs `offering-usage:write`; the
listing-management and subscription routes need `marketplace:admin`.

---

## 1. Browse the catalog

List is paginated and filterable. Filters: `q` (matches name, description,
tags), `vertical` (category), `type` (`app` or `agent`), `featured=true`, plus
`limit`, `cursor`, `sort`.

On a production install the catalog lists only published items, as the
Marketplace page does: a draft is not listed, not counted in `/verticals`, and
`GET /marketplace/items/:id` answers `404` for it.

```bash
# List / search / filter
curl -s "${auth[@]}" "$BASE/marketplace/items?type=app&featured=true&limit=20" | jq '.data'
curl -s "${auth[@]}" "$BASE/marketplace/items?q=resume&vertical=HR"        | jq '.data'

# Categories with counts (to build a vertical filter)
curl -s "${auth[@]}" "$BASE/marketplace/verticals" | jq '.data'

# One offering, full detail
ITEM_ID=f3taqyfqG5oA9xG3p                        # an item id from the list (opaque string)
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID" | jq '.data'
```

Before deploying, inspect the offering:

```bash
# The deploy.json the offering ships (the deploy wizard it declares, see section 8)
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID/deploy-config" | jq '.data'

# License text
curl -s "${auth[@]}" "$BASE/marketplace/items/$ITEM_ID/license"  | jq -r '.data'
```

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/marketplace/items` | `marketplace:read` | List/search offerings (`q` on name, description, tags, vendor; `vertical`, `type`, `featured`, `limit`, `cursor`, `sort`) |
| GET | `/marketplace/items/stats` | `marketplace:read` | The offerings counted with the list's filters: `total`, `byType`, `byVertical`, `featured` |
| GET | `/marketplace/verticals` | `marketplace:read` | Categories with item counts |
| GET | `/marketplace/items/:id` | `marketplace:read` | Full detail for one offering |
| GET | `/marketplace/items/:id/deploy-config` | `marketplace:read` | The offering's `deploy.json` |
| GET | `/marketplace/items/:id/license` | `marketplace:read` | License text |

---

## 2. Check what you can wire in (ground the config)

The deploy wizard the offering declares (from `deploy-config` above) may ask the
user to pick an existing addon or an AI model. List the real ones the user has
so you configure the deploy against what actually exists, never a guessed id.

```bash
# Existing provisioned addons (running/deploying) + compatible object-store data
# sources, by type then label, things you can CONNECT to the offering. `type` keeps
# one add-on slot's type, `q` matches the label.
curl -s "${auth[@]}" "$BASE/marketplace/available-addons?type=postgres" | jq '.data'

# AI models available to attach to the offering. `modelType` keeps a purpose's types
# (one or several, comma-separated), `q` matches the name, provider or vendor model id.
curl -s "${auth[@]}" "$BASE/marketplace/available-models?modelType=chat,multimodal" | jq '.data'
```

`available-addons` lists services to connect, not a catalog of addon types to
create. To provision a new addon first, see `references/addons.md`.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/marketplace/available-addons` | `marketplace:read` | User's connectable addons + object-store data sources, by type (`type`, `q`) |
| GET | `/marketplace/available-models` | `marketplace:read` | AI models available to attach (`modelType`, several comma-separated; `q`) |

---

## 3. Deploy an offering  ← poll it to done, never assume success

Deploy is **async**: the call returns **202 Accepted** immediately and the build
runs in the background. Body requires `appName` (the name for the new app) and a
`config` object. `config` must include `marketplaceItemId` and
`termsAccepted: true`; the rest of `config` carries the wizard selections the
offering declared (resources, addons, models, permissions) grounded from §1 and
§2. `config.resources` is the app's `cpu`, `memory`, `disk`, `instances`, and
`useSpot` (spot capacity) with `spotFallback` (default true: on-demand when no
spot is available). A `streaming_workflow` offering also needs
`config.sessionInitiatorRoles`: the platform roles (`admin`, `developer`, at least one)
allowed to start sessions of the deployed workflow; start from its deploy config's
`permissions.session_initiator_roles`. Any other offering refuses the field. A user who
holds none of the roles is refused a session start with a **403**, even when the
workflow is shared with them. Missing `appName`/`config` is a 400, missing `marketplaceItemId` a 400, and
`termsAccepted` not true a 422.

```bash
# Kick off the deploy (returns 202, body echoes appName + marketplaceItemId)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"appName":"my-resume-app","config":{"marketplaceItemId":"'"$ITEM_ID"'","termsAccepted":true}}' \
  "$BASE/marketplace/deploy" | jq '.data'
```

Then **poll the deployment by the `_id` the deploy returned** (`$DEPLOYMENT_ID`):
each deployment has its own record. Use the lightweight status for a percentage, or the
full deployment for created resources. Do not report success until `status` is
`complete` (or the payload's `deployed` is true).

```bash
# Lightweight: status + percentage
curl -s "${auth[@]}" "$BASE/marketplace/deployments/$DEPLOYMENT_ID/status" | jq '.data'

# Full: progress, result (result.appId when done), createdResources, error, governance
curl -s "${auth[@]}" "$BASE/marketplace/deployments/$DEPLOYMENT_ID" | jq '.data'
```

`status` values: `validating`, `deploying`, `governance-hold`, `cancelling`,
`complete`, `failed`, `cancelled` (`stepMessage` carries the human-readable step).
On `failed`, read the `error` field. Each workload an offering creates is governed
like one the user creates; on `governance-hold` governance blocked one: `governance`
names it and the solutions whose requirements are pending. The deployment keeps what
it created and continues on its own once they are complete (tell the user what is
required; do not redeploy). Cancelling it removes what it created. Progress
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
curl -s -X POST "${auth[@]}" "$BASE/marketplace/deployments/$DEPLOYMENT_ID/cancel"     # cancel in-progress; answers the deployment
curl -s -X DELETE "${auth[@]}" "$BASE/marketplace/deployments/$DEPLOYMENT_ID"          # remove a finished deployment's record (204)
```

| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/marketplace/deploy` | `marketplace:deploy` | Start a deploy (`appName`, `config`); returns 202 |
| GET | `/marketplace/deployments` | `marketplace:deploy` | List the user's deployed offerings, newest first (`marketplaceItemId`: one item's) |
| GET | `/marketplace/deployments/:id` | `marketplace:deploy` | Full deploy info (progress, result, createdResources) |
| GET | `/marketplace/deployments/:id/status` | `marketplace:deploy` | Lightweight status + percentage |
| POST | `/marketplace/deployments/:id/cancel` | `marketplace:deploy` | Cancel an in-progress deploy; answers the deployment, `cancelling` |
| DELETE | `/marketplace/deployments/:id` | `marketplace:deploy` | Remove a finished (complete, failed, cancelled) deployment's record; 204 |

`:id` on the deployment routes is the deployment's **`_id`**: `POST /marketplace/deploy` answers the deployment it started (202), as `GET /marketplace/deployments/:id` shows it. It is not the marketplace item id or an app id.

---

## 4. After deploy: it is a regular app

When `status` is `complete`, the full deployment payload's `result.appId` is the
new app. From there it behaves like any Strongly app: it is served behind the
proxy (its prefix arrives as `X-Forwarded-Prefix`), reads the signed-in user from
a JWT, and gets wired connections via `STRONGLY_SERVICES`. Manage it (status,
logs, env, start/stop, versions) with the `/apps` routes, and follow the
proxy/asset, identity and manifest guidance in **`references/apps.md`** (the
build reads `strongly.manifest.yaml`; `deploy.json` is the deploy wizard you saw
in `deploy-config`).

---

## 5. Report metered usage from a running offering

A deployed offering that is billed per use emits **one usage event** at the
moment of use. The event is idempotent per `idempotencyKey`, so a retry never
double-counts.

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"offeringId":"my-resume-app","meterKey":"resumes","quantity":1,
       "idempotencyKey":"resume-8f21c-2026-09-15"}' \
  "$BASE/marketplace/usage-events" | jq '.data'
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
| POST | `/marketplace/usage-events` | `offering-usage:write` | Record one metered usage event (idempotent) |

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
# Browse the plugin catalog (a plain array; each entry: id, displayName,
# description, configSchema[], features[]).
curl -s "${auth[@]}" "$BASE/plugins" | jq '.data'

# What is already installed (paged; secrets are never returned).
curl -s "${auth[@]}" "$BASE/plugins/instances" | jq '.data[] | {_id, pluginId, enabled, status}'
```

Install with the plugin's `pluginId`. `values` is a flat map keyed by the
plugin's `configSchema` fields; `features` is a map of feature id to boolean
(defaults apply when omitted). Installing an installed plugin again updates its
config and turns it on. Required config fields are enforced. The answer is the
instance; its `_id` addresses it from then on.

```bash
# Install / configure DataHub (values.datahubBaseUrl + values.authMode).
INSTANCE=$(curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"pluginId":"datahub","values":{"datahubBaseUrl":"http://datahub-gms:8080","authMode":"pat","datahubToken":"<pat>"},
       "features":{"lineage":true,"modelSync":true}}' \
  "$BASE/plugins/instances" | jq -r '.data._id')

# Turn it off without uninstalling, on again, then uninstall (204).
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' -d '{"enabled":false}' "$BASE/plugins/instances/$INSTANCE" | jq '.data.enabled'
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' -d '{"enabled":true}'  "$BASE/plugins/instances/$INSTANCE" | jq '.data.enabled'
curl -s -X DELETE "${auth[@]}" "$BASE/plugins/instances/$INSTANCE" -o /dev/null -w '%{http_code}\n'
```

Errors: a missing required config field is a **400** (`validation-error`); an
unknown plugin id or instance is a **404** (`not-found`); no access is a **403**.
Turning stripe-app-payments off or uninstalling it while any app still charges
is a **409** (`invalid-state`): turn off paid access on each app first.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/plugins` | `marketplace:read` | The installable plugins (schema + features), a plain array |
| GET | `/plugins/instances` | `marketplace:read` | The installed instances the caller can see (paged) |
| POST | `/plugins/instances` | `marketplace:deploy` | Install or reconfigure (`pluginId`, `values`, `features`); `201` with the instance |
| GET | `/plugins/instances/:id` | `marketplace:read` | One instance |
| PATCH | `/plugins/instances/:id` | `marketplace:deploy` | `enabled`, `values`, `features`; answers with the instance |
| DELETE | `/plugins/instances/:id` | `marketplace:deploy` | Uninstall (`204`) |

---

## 7. Manage listings (admin only)

Creating/editing catalog listings is `marketplace:admin`. Create requires
`name`, `description`, `vendor`, `type` (`app` or `agent`), `vertical`.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/marketplace/items` | `marketplace:admin` | Create a listing |
| PATCH | `/marketplace/items/:id` | `marketplace:admin` | Update a listing |
| DELETE | `/marketplace/items/:id` | `marketplace:admin` | Delete a listing |

### Offering subscriptions (admin only)

An organization created as an offering customer (billing mode `offering`, with a billing
email) pays for an offering through a subscription on a plan of the offering's billing
config. Nothing here carries money; cost is shown only in FinOps.

| Method | Path | Scope | Purpose |
|---|---|---|---|
| GET | `/marketplace/subscriptions` | `marketplace:admin` | List (`organizationId`, `offeringId`, `status`, `limit`, `cursor`), newest first |
| POST | `/marketplace/subscriptions` | `marketplace:admin` | Create: `organizationId`, `offeringId`, `planName`, `activateImmediately`, `successUrl`, `cancelUrl`; 201 with `checkoutUrl` for the billing contact |
| GET | `/marketplace/subscriptions/:id` | `marketplace:admin` | One subscription |
| PATCH | `/marketplace/subscriptions/:id` | `marketplace:admin` | Change its plan: `{ "planName" }` (the one field that changes) |
| POST | `/marketplace/subscriptions/:id/cancel` | `marketplace:admin` | `{ "atPeriodEnd": true }` ends it with its billing period; `false` cancels now and pauses the organization's apps (data kept) |

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"organizationId":"'"$ORG_ID"'","offeringId":"caliber","planName":"base",
       "activateImmediately":false,"successUrl":"https://example.com/paid",
       "cancelUrl":"https://example.com/back"}' \
  "$BASE/marketplace/subscriptions" | jq '.data.checkoutUrl'
```

A subscription's `status` is `active`, `grace` (a payment failed; usable for `graceDays`),
`suspended` (not usable; also a new one waiting for its first payment) or `canceled`.
Refusals: billing off (409 `billing-disabled`), the organization not an offering customer
or without a billing email (409), a second live subscription to the offering (409), a plan
the billing config does not have (400, naming its plans), Stripe refusing a request (502
with Stripe's reason), period-end cancel of a subscription whose checkout is pending (409).

---

## 8. An offering's deploy wizard (`deploy.json`)

A marketplace offering ships a `deploy.json` beside its code: the deploy **wizard**
the marketplace shows (its steps, who can reach the app, resource choices, the
addons and AI models it provisions). It is NOT the build manifest: the app itself
builds from `strongly.manifest.yaml` like any app (`references/apps.md` section 6).
`addons[].id` becomes the `configId` the running app matches in
`STRONGLY_SERVICES`. Grounded in the working **kanban** offering:

```json
{
  "name": "kanban",
  "displayName": "Kanban",
  "version": "1.0.1",
  "type": "app",
  "description": "Project management board with real-time collaboration",

  "steps": [
    { "id": "permissions", "title": "Access Control", "required": true },
    { "id": "resources",   "title": "App Resources",  "required": true },
    { "id": "addons",      "title": "Database",       "required": true }
  ],

  "permissions": {
    "allowPublic": true, "allowUserSelection": true, "defaultPublic": false
  },

  "resources": {
    "defaults": { "cpu": "0.5", "memory": "1GB", "disk": "5GB", "instances": 1 },
    "options":  { "cpu": ["0.5","1","2"], "memory": ["1GB","2GB","4GB"],
                  "disk": ["5GB","10GB","20GB"], "instances": [1,2,3] }
  },

  "addons": [
    {
      "id": "mongodb", "type": "mongodb", "required": true,
      "label": "Board Database", "allowExisting": true,
      "defaults": { "cpu": "0.5", "memory": "1GB", "disk": "10GB", "replicas": 1 },
      "options":  { "cpu": ["0.5","1","2"], "memory": ["1GB","2GB","4GB"], "disk": ["10GB","25GB","50GB"] },
      "backupConfig": { "configurable": true, "defaultEnabled": true,
                        "defaultSchedule": "daily", "defaultRetention": 7,
                        "scheduleOptions": ["hourly","daily","weekly"] }
    }
  ],

  "aiGateway": { "required": false },

  "environmentVariables": {
    "configurable": false,
    "defaults": { "NODE_ENV": "production" }
  },

  "healthCheck": { "path": "/health", "port": 8080, "initialDelay": 30,
                   "period": 30, "timeout": 10, "failureThreshold": 3 }
}
```

Field reference:

| Key | Purpose |
|---|---|
| `name` / `displayName` / `version` / `type` / `description` | Identity of the offering in the marketplace (`type` `"app"` here is the offering kind, not the build type; the build type is `strongly.manifest.yaml`'s). |
| `steps[]` | The deploy-wizard steps shown to the user (`id` ∈ `permissions`, `resources`, `addons`, `ml-models`, `ai-models`), each `required` or not. |
| `permissions` | `allowPublic`, `allowUserSelection`, `defaultPublic`, who can reach the app. A `streaming_workflow` offering also names `session_initiator_roles` (platform roles `admin`, `developer`): the roles the wizard starts from for who may start its sessions; no other type carries it. |
| `resources` | `defaults` + selectable `options` for `cpu`, `memory`, `disk`, `instances`. |
| `addons[]` | Managed stores to provision: `id` (this becomes the `configId` you match in `STRONGLY_SERVICES`), `type`, `required`, `allowExisting`, `internal` (hide from users), `defaults`/`options`, `backupConfig`. |
| `aiGateway` | `{ required, minModels, maxModels, supportedProviders }`, AI models the app can use. |
| `models[]` | ML models to deploy alongside the app (`artifact`, `framework`, `inference.endpoint`). |
| `environmentVariables` | `{ configurable, defaults }`, non-secret config injected as env vars. |
| `healthCheck` | `{ path, port, initialDelay, period, timeout, failureThreshold }`, the readiness path (serve it, see §1). |
| `seedData` | Optional one-time init script run on deploy. |

---

## Checklist
- [ ] Browse/filter with `GET /marketplace/items` (`q`, `vertical`, `type`, `featured`); read one with `/items/:id`.
- [ ] Inspect `/deploy-config` and `/license` before installing; a streaming workflow offering also needs `config.sessionInitiatorRoles`.
- [ ] Ground the deploy `config` against real `available-addons` / `available-models`, never a guessed id.
- [ ] Deploy needs `appName` + `config` with `marketplaceItemId` and `termsAccepted: true`; it returns 202.
- [ ] Poll `/marketplace/deployments/:id/status` (by the deployment's `_id`) until `status` is `complete`; never claim success before that; read `error` on `failed`.
- [ ] Once complete, treat `result.appId` as a normal app and use `references/apps.md` (`/apps` routes, proxy, identity, manifest).
- [ ] Usage events: one per use, unique `idempotencyKey`, positive `quantity`; a 200 `deduplicated:true` is success, not an error.
- [ ] Plugins: browse `GET /plugins`, install with `POST /plugins/instances` (`pluginId`, `values` matching the plugin's `configSchema`; `marketplace:deploy`); `PATCH /plugins/instances/:id` `{enabled}` turns one on or off and `DELETE` uninstalls it; managing them needs admin (or developer in multitenant).
