# Apps

A Strongly **app** is a containerized web app (any framework) that the platform
builds, deploys to Kubernetes, and serves **behind the Strongly proxy**. Users
reach it through the platform; the app gets the signed-in user's identity, its
connected services, and managed compute for free.

Read this when the task is: deploying/updating an app, **making an app render
correctly behind the proxy** (the single biggest source of bugs, CSS/JS not
loading, blank screen), reading the signed-in user, wiring an app to services, or
saving/serving artifacts.

> **Canonical working example: the `kanban` marketplace app.** Every proxy,
> asset, auth, and cache pattern below is taken from it. When in doubt, mirror
> kanban, it is the reference implementation that renders correctly through the
> proxy.

**Auth** follows the two-context rule in `SKILL.md`: outside Strongly you send
`X-API-Key` to `$HOST/api/v1`; inside Strongly (or from a workspace) the platform
is `$STRONGLY_API_URL/api/v1` and the bearer is auto-injected. Below, `$BASE` is
whichever applies. (This is the app talking TO the platform. Separately, the
proxy tells the app WHO the end user is, see [Identity](#identity), and that is
always a JWT, never an API key.)

---

## 0. Gather requirements first (ASK the user, don't assume)

Before you scaffold, build, or deploy an app, ASK the user the questions that
decide its deploy config, rather than guessing. Wiring a service in from the start
is one deploy; discovering it was needed later is a rebuild. At minimum:

- **Does it need a database?** And what kind: relational (`postgres`, `mysql`),
  document (`mongodb`), cache (`redis`), vector, ...? A yes means provision a
  managed addon and wire it (see `references/addons.md` + §4). Never silently ship
  a stateless app the user expected to persist data.
- **Who can reach it?** Only them, everyone in their org, or the public? (maps to
  the app's permissions / manifest `permissions`).
- **Does it call AI models?** Chat, embeddings, speech, image, ...? If so, which
  models to wire through the AI Gateway (see §4 + `references/ai-gateway.md`).
- **Does it read data the user already has** (an existing database, warehouse, or
  bucket)? That is a data **source**, not a new addon (see `references/datasources.md`).
- **Rough size and always-on?** Resources, and whether it must run 24/7.

Confirm these up front so the app is scaffolded and deployed with the right
services wired the first time. If the user's request is ambiguous ("build me a
todo app"), ask the database/access questions before you start, not after.

---

## 1. Serve correctly behind the proxy  ← get this right first

Deployed apps are reached **only** through the platform proxy at a relative base
path, e.g. `/api/proxy/app-xyz123/`. The app is never on a bare origin. Two facts
drive everything:

- The proxy **strips its prefix** before the request reaches your app: the
  browser asks for `/api/proxy/app-xyz/assets/x.js`, your app receives
  `/assets/x.js`.
- The platform sets **`STRONGLY_URL`** = that prefix (e.g. `/api/proxy/app-xyz`),
  plus `STRONGLY_HOST` and `STRONGLY_APP_ID`.

The failure everyone hits: a SPA built for `/` emits root-absolute asset URLs
(`/assets/x.js`), which under the proxy prefix resolve wrong → **blank page, or
CSS/JS 404, or the opaque "Importing a module script failed."** The kanban recipe
below eliminates all of it. Do every step, they are load-bearing.

### 1a. Build with a RELATIVE base (Vite)

```ts
// vite.config.ts
export default defineConfig({ base: './', /* … */ });
```

`base: './'` makes Vite emit **relative** asset URLs (`./assets/x.js`) instead of
`/assets/x.js`, so they resolve under any prefix.

### 1b. Client: derive the base from the URL you're actually at, no fallbacks

Do **not** read `import.meta.env.BASE_URL` for runtime paths (it is `'./'` and
silently produces a blank app). Derive the prefix from the browser location, one
source of truth for the router basename, API base, and any link prefix:

```ts
// runtimeBase.ts  (from kanban, copy it)
const PROXY_PREFIX = /^(\/api\/proxy\/[^/]+)/;
export const getRuntimeBase = (p = location.pathname) => (p.match(PROXY_PREFIX)?.[1] ?? '');
export const getBasename = (p = location.pathname) => getRuntimeBase(p) || '/';   // router
export const getApiBase  = (p = location.pathname) => `${getRuntimeBase(p)}/api`; // fetch base
```

```tsx
<BrowserRouter basename={getBasename()}>…</BrowserRouter>
// fetch(`${getApiBase()}/boards`)  ->  /api/proxy/app-xyz/api/boards behind the proxy, /api locally
```

### 1c. Server: serve assets, require the prefix, don't hand HTML to the module loader

The single-container pattern (kanban `Dockerfile`): `vite build` → copy `dist` to
`server/public`, node serves static **and** API on one port.

```js
// Static BEFORE auth (assets must not require a login). Proxy already stripped
// the prefix, so serve at /assets, not /${STRONGLY_URL}/assets.
app.use('/assets', express.static(path.join(pub, 'assets'), { maxAge: '1d', etag: true }));
app.use(express.static(pub, { index: false }));           // favicon, etc.
app.use('/api', apiLimiter, authMiddleware, apiRouter);   // API auth AFTER static

// STRONGLY_URL is ALWAYS set by the platform. If it's missing, FAIL LOUD, do not
// default to '' (that ships a silently broken UI with wrong asset paths).
if (!process.env.STRONGLY_URL) { console.error('FATAL: STRONGLY_URL not set'); process.exit(1); }
const base = process.env.STRONGLY_URL;

// A static-looking path that reaches the SPA fallback does NOT exist on disk.
// Returning index.html (HTML) for a `.js` request is what makes the browser throw
// "Importing a module script failed", it asked for JS and got a document. This
// happens right after a redeploy when a cached shell requests OLD chunk hashes.
// 404 them so it fails cleanly instead of masquerading as a crash.
const STATIC = /\.(?:js|mjs|css|map|json|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|eot|wasm)$/i;
app.get('*', (req, res, next) =>
  (req.path.startsWith('/assets/') || STATIC.test(req.path))
    ? res.status(404).type('text/plain').send('Not found') : next());

// SPA fallback: inject a <base href> + rewrite asset paths to the prefix, and
// NEVER cache the shell (it names hashed chunks; a cached shell + new build = the
// stale-shell error above). The hashed chunks themselves stay immutably cached.
app.get('*', (req, res) => {
  let html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  const cfg = JSON.stringify({ STRONGLY_URL: base, STRONGLY_HOST: process.env.STRONGLY_HOST || '',
                               STRONGLY_APP_ID: process.env.STRONGLY_APP_ID || '', API_URL: '/api' })
                   .replace(/</g, '\\u003c');
  html = html
    .replace('</head>', `<script>window.__RUNTIME_CONFIG__=${cfg}</script></head>`)
    .replace('<head>', `<head><base href="${base}/">`)
    .replace(/(src|href)="\.?\/assets\//g, `$1="${base}/assets/`)
    .replace(/href="\.?\/favicon/g, `href="${base}/favicon`);
  res.set('Cache-Control', 'no-store').send(html);
});
```

Always expose `GET /health → 200`.

### 1c checklist (why each line exists)
- `base: './'` → assets are relative, not root-absolute.
- Static served at `/assets`, **before** auth → CSS/JS load without a login.
- `STRONGLY_URL` required, fail loud → no silently-broken UI.
- 404 static-looking paths in the fallback → kills "module script failed".
- `<base href>` + asset rewrite → every relative URL resolves under the prefix.
- `Cache-Control: no-store` on the shell → no stale-shell after redeploy.

---

## 2. Deploy an app via the REST API

Flow: **upload a bundle (this BUILDS the image, asynchronously) → wait for the
build to complete → deploy → poll the pod.** `deploy` is rejected while the build
is still `pending`, so you must poll `build-status` to `completed` before you call
it. Never report success until the pod is running. Set once (outside Strongly):

```bash
export STRONGLY_API_KEY=sk-...            # Settings → API Keys (apps:write, apps:deploy)
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
```

A bundle is a `.zip` of your source **with a `Dockerfile`**; keep it small.

```bash
# 1) Create + upload the bundle (multipart). The upload BUILDS the image
#    asynchronously. Fields: name, description, resources (JSON string).
APP_ID=$(curl -s "${auth[@]}" \
  -F name=my-app -F 'resources={"memory":"1Gi","cpu":"500m"}' \
  -F "file=@bundle.zip;type=application/zip" \
  "$BASE/apps/upload" | jq -r '.data._id')

# 2) Poll the build to completed BEFORE deploying (queued|building|completed|failed).
#    deploy errors out if you call it while the build is still pending.
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/build-status" | jq -r '.data.status'      # until "completed"
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/build-logs?level=error" | jq -r '.data'   # on "failed"

# 3) Deploy the built image, then poll the pod to healthy.
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/deploy"
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/status" | jq '.data'                      # until state=running, ready_replicas=1

# Subsequent versions: upload again (rebuilds async), poll build to completed, deploy again.
curl -s "${auth[@]}" -F "file=@bundle.zip;type=application/zip" "$BASE/apps/$APP_ID/upload"
```

Lifecycle: `GET /apps` · `GET/PUT /apps/:id` · `PUT /apps/:id/env` ·
`PUT /apps/:id/permissions` · `POST /apps/:id/start|stop|restart` ·
`GET /apps/:id/logs` · `GET /apps/:id/metrics` · `DELETE /apps/:id`. Git-based
deploys: `POST /apps` (JSON) with `repository` + `branch`, then `deploy`.

---

## 3. Identity

The proxy signs the user in and passes identity as a **signed JWT**, the app
reads it, never builds a login screen. It arrives one of two ways, both the same
token:

- **`X-Strongly-User-Token`**, set by the proxy for end-user browser requests.
- **`Authorization: Bearer <jwt>`**, set for server-to-server / agent calls
  (e.g. a Strongly agent acting in your app as its owning user).

Read either. Verify if the signing secret is present in the pod, otherwise decode
(the secret lives only in platform services; network isolation is the trust
boundary). Identity is under `claims.user` (or `claims.owner`):

```js
// auth.js (from kanban)
import jwt from 'jsonwebtoken';
const readClaims = (t) => { if (!t) return null;
  const s = process.env.STRONGLY_JWT_SECRET;
  try { return s ? jwt.verify(t, s) : jwt.decode(t); }   // bad signature w/ secret => reject
  catch { return null; } };
const extractToken = (req) => req.headers['x-strongly-user-token']
  || (req.headers.authorization?.match(/^Bearer\s+(.+)/i)?.[1]) || null;

app.use('/api', (req, _res, next) => {
  const c = readClaims(extractToken(req));
  req.user = c?.user || c?.owner || null;   // NO invented user; null when absent
  next();
});
```

Convenience headers also exist (`X-Strongly-User-Id/Email/Name/Roles`,
`X-Strongly-Org-Id`); the JWT is canonical. Common roles: `admin`, `developer`,
`app`, map them to your app's roles.

---

## 4. Wiring: `STRONGLY_SERVICES`

Everything you connect (addons, data sources, AI models, workflows) arrives as one
JSON env var. Read connections from it, never hardcode a host or key. The shape is
a category tree under a top-level **`services`** object; addons and data sources
are keyed **by type**, each holding an **array** (you can connect more than one of
a type), and each entry carries its connection under `.connection` and any secrets
under `.auth.credentials`:

```js
const s = (JSON.parse(process.env.STRONGLY_SERVICES || '{}')).services || {};

// ADDON (a managed store you provisioned), e.g. postgres. addons.<type> is an
// array: take [0], or match on configId when a type has more than one.
const pg   = s.addons?.postgres?.[0];               // or ?.find(a => a.configId === 'orders-db')
const conn = pg?.connection?.connection_string;     // also pg.connection.uri; host/port/database on .connection
const user = pg?.auth?.credentials?.username;       // password in pg.auth.credentials.password
// pg.internal === true => the app's OWN metadata store; hide it from any user "pick a database" list.

// DATA SOURCE (an external connection), same type-keyed shape, e.g. s3:
const s3     = s.datasources?.s3?.[0];
const bucket = s3?.connection?.bucket;              // fields vary by type; see references/datasources.md
const akid   = s3?.auth?.credentials?.access_key_id;

// AI MODEL via the AI GATEWAY. Not a top-level array: one gateway holding the
// models you connected. Call the gateway (OpenAI-compatible) at its base_url.
const gw    = s.aigateway;
const model = gw?.available_models?.[0];            // { vendor_model_id, provider, modelType, display_name, ... }
// POST `${gw.base_url}/...` with model.vendor_model_id; see references/ai-gateway.md.

// WORKFLOWS you connected:
const wf = s.workflows?.available_workflows?.[0];   // trigger via s.workflows.engine.api_endpoint
```

- Everything hangs off `STRONGLY_SERVICES.services`. Addons and data sources are
  `services.<addons|datasources>.<type>[]`; the AI gateway is `services.aigateway`
  (`available_models` + `providers` + `base_url`); workflows are `services.workflows`.
- Match a specific store on **`configId`** (stable, = the manifest addon `id`), not
  the dynamic `id` (`mongodb-abc123`), when a type has more than one.
- Respect **`internal: true`** addons (the app's own store), hide them from any
  user-facing "pick a database" UI.
- Connections live under `service.connection` (`connection_string`/`uri`, `host`,
  `port`, `database`, ...), secrets under `service.auth.credentials`. Degrade
  honestly if a service is absent; don't fabricate one.

You choose what's wired at create time by declaring ids in the `addons`,
`dataSources`, `aiModels`, `workflows` arrays (discover via `GET $BASE/addons`,
`/datasources`, `/ai-models`, `/workflows`). How you pass them depends on the route:
- JSON `POST $BASE/apps` and `PUT $BASE/apps/:id`: send them as top-level body
  fields, e.g. `{"addons":["<id>"]}`. On `PUT` each array REPLACES the connected set.
- Multipart `POST $BASE/apps/upload` (zip bundle): they are NOT standalone form
  fields; put them in the `metadata` JSON string, e.g. `metadata={"addons":["<id>"]}`.

Changing the connected set updates the app DEFINITION; `STRONGLY_SERVICES` is
regenerated from it at build/deploy, so redeploy an already-running app to apply a
change (see `references/addons.md` section 7). Declaring ids up front, at create or
upload, is the one-shot path with no extra redeploy.

---

## 5. Artifacts (the Library API)

An **artifact** is a file the app produces for the user (report, export, PDF/HTML,
document). Store it in the platform Library (S3-backed, encrypted) instead of the
app's ephemeral disk, then hand the user a **short-lived pre-signed URL** so the
download goes browser → S3, not streamed back through the app and proxy.

The app calls the platform API for this. **Inside Strongly the bearer is
auto-injected** (see `SKILL.md`), the app doesn't manage a key; it calls
`$STRONGLY_API_URL/api/v1/...` and auth is handled. (Outside Strongly, an
`X-API-Key` is used.)

```bash
# Save: POST $BASE/artifacts  (artifacts:write)
curl -s -X POST "$STRONGLY_API_URL/api/v1/artifacts" -H 'Content-Type: application/json' \
  -d '{"title":"Q3 report","artifact_type":"report","contentType":"application/pdf",
       "encoding":"base64","content":"'"$(base64 -i report.pdf)"'"}'   # -> data._id

# Serve: GET $BASE/artifacts/:id/download-url?ttlSeconds=600  (max 900) -> pre-signed URL
```

Serving pattern behind the proxy: the app's own endpoint (which knows the user
from §3) mints a download URL and **302-redirects** the browser to it, the heavy
bytes go browser → S3 directly, only a small redirect passes through the app.

```js
app.get('/download/:id', async (req, res) => {
  if (!req.user) return res.status(401).end();
  const r = await fetch(`${process.env.STRONGLY_API_URL}/api/v1/artifacts/${req.params.id}/download-url`);
  res.redirect(302, (await r.json()).data.url);   // bearer auto-injected in-cluster
});
```

Also: `GET /artifacts` (gallery), `/artifacts/:id/versions` + `/restore`,
`PATCH`/`DELETE`, and `/share` · `/unshare` · `/toggle-public` · `/toggle-org-share`.

---

## 6. The Strongly manifest (`deploy.json`)

`deploy.json` at the **bundle root** is the app's manifest. It declares the deploy
wizard the platform shows the user and what to provision; the provisioned
connections come back to the running app via `STRONGLY_SERVICES` (§4). Required
for a marketplace offering; optional for a one-off app (which just needs a
`Dockerfile` + the REST calls in §2, and gets default resources).

Full structure, grounded in the working **kanban** manifest:

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
| `name` / `displayName` / `version` / `type` / `description` | Identity. `type` is `"app"`. |
| `steps[]` | The deploy-wizard steps shown to the user (`id` ∈ `permissions`, `resources`, `addons`, `ml-models`, `ai-models`), each `required` or not. |
| `permissions` | `allowPublic`, `allowUserSelection`, `defaultPublic`, who can reach the app. |
| `resources` | `defaults` + selectable `options` for `cpu`, `memory`, `disk`, `instances`. |
| `addons[]` | Managed stores to provision: `id` (this becomes the `configId` you match in `STRONGLY_SERVICES`), `type`, `required`, `allowExisting`, `internal` (hide from users), `defaults`/`options`, `backupConfig`. |
| `aiGateway` | `{ required, minModels, maxModels, supportedProviders }`, AI models the app can use. |
| `models[]` | ML models to deploy alongside the app (`artifact`, `framework`, `inference.endpoint`). |
| `environmentVariables` | `{ configurable, defaults }`, non-secret config injected as env vars. |
| `healthCheck` | `{ path, port, initialDelay, period, timeout, failureThreshold }`, the readiness path (serve it, see §1). |
| `seedData` | Optional one-time init script run on deploy. |

The manifest and the REST deploy work together: your **bundle** (`Dockerfile` +
source + `deploy.json`) is what you upload in §2. `deploy.json` declares what the
platform provisions; the app reads those provisioned connections at runtime from
`STRONGLY_SERVICES`. `addons[].id` in the manifest is the `configId` you match on
in code, keep them in sync.

---

## Checklist
- [ ] Vite `base: './'`; client base derived from the URL (no `import.meta.env.BASE_URL`).
- [ ] Server: static `/assets` before auth; `STRONGLY_URL` required (fail loud); 404 static-looking paths in the SPA fallback; `<base href>` + asset rewrite; `Cache-Control: no-store` on the shell.
- [ ] `GET /health → 200`.
- [ ] Identity by reading `X-Strongly-User-Token` **or** `Authorization: Bearer`; verify-if-secret-else-decode; no invented user.
- [ ] Services from `STRONGLY_SERVICES`, matched on `configId`, internal addons hidden.
- [ ] Artifacts saved to the Library; downloads via 302 to a short-lived pre-signed URL.
- [ ] After deploy: build `completed` AND pod healthy before declaring success; read build-logs on failure.
- [ ] When unsure about any of this, compare against the **kanban** app.
