# Apps

A Strongly **app** is a containerized web app (any framework) that the platform
builds, deploys to Kubernetes, and serves **behind the Strongly proxy**. Users
reach it through the platform; the app gets the signed-in user's identity, its
connected services, and managed compute for free.

Read this reference when the task is: deploying or updating an app, making an app
work behind the proxy, reading the signed-in user, wiring an app to addons/
data sources/models, or saving and serving artifacts.

Everything here uses the base URL and `X-API-Key` auth from `SKILL.md`. Set once:

```bash
HOST="https://app.strongly.ai"      # the user's Strongly host
export STRONGLY_API_KEY="sk-..."    # from Settings → API Keys (scopes: apps:write, apps:deploy)
api() { curl -s -H "X-API-Key: $STRONGLY_API_KEY" "$HOST/api/v1$@"; }
```

---

## 1. Deploy an app via the REST API

The whole flow is: **upload a bundle → deploy → poll the build → poll the pod.**
Do not report success until the pod is running.

### Bundle

A bundle is a `.zip` of your app source containing a **`Dockerfile`** (the
platform builds the image from it). Include only what the image needs; keep it
small. The framework/runtime are inferred from the bundle — you rarely set them.

### First deploy (create + upload in one call)

`POST /api/v1/apps/upload` — `multipart/form-data`, scope `apps:write`.

| Field | Notes |
|---|---|
| `file` | the `.zip` bundle (required unless you only want an empty app record) |
| `name` | app name |
| `description` | optional |
| `resources` | JSON **string**, any of `{ memory, cpu, disk, gpu, gpu_type }`, e.g. `'{"memory":"1Gi","cpu":"500m"}'` |
| `environment` | JSON **string** of env vars, e.g. `'{"LOG_LEVEL":"info"}'` |
| `framework` / `runtime` | build hints; pass only if inference is wrong |

```bash
curl -s -H "X-API-Key: $STRONGLY_API_KEY" \
  -F "name=my-app" \
  -F 'resources={"memory":"1Gi","cpu":"500m"}' \
  -F "file=@bundle.zip;type=application/zip" \
  "$HOST/api/v1/apps/upload"
# -> { "success": true, "data": { "_id": "<APP_ID>", ... } }
```

This **creates** the app. Now build + deploy it:

```bash
curl -s -X POST -H "X-API-Key: $STRONGLY_API_KEY" \
  "$HOST/api/v1/apps/<APP_ID>/deploy"
```

`deploy` builds the Docker image and creates the Kubernetes deployment + service.
It returns immediately — the build runs asynchronously.

### Subsequent versions (upload + deploy in one call)

`POST /api/v1/apps/:id/upload` — `multipart/form-data`, scope `apps:deploy`.
Uploads a new bundle to an existing app **and deploys it** in one step. Optional
`environment` (JSON string), and `capacity_type=spot` to use spot instances.

```bash
curl -s -H "X-API-Key: $STRONGLY_API_KEY" \
  -F "file=@bundle.zip;type=application/zip" \
  "$HOST/api/v1/apps/<APP_ID>/upload"
# response includes deploy result, or { ..., "deployError": "..." } if deploy failed
```

### Poll the build, then the pod

```bash
# 1) build status: queued | building | completed | failed
api "/apps/<APP_ID>/build-status" | jq '.data'

# 2) if failed, read WHY (compiler / pip / npm output) — never redeploy blind:
api "/apps/<APP_ID>/build-logs?level=error" | jq -r '.data'

# 3) once build is completed, poll the running pod until healthy:
api "/apps/<APP_ID>/status" | jq '.data'   # replicas, pod health, resources

# 4) runtime errors in the RUNNING pod (a failed build has no pod — use build-logs there):
api "/apps/<APP_ID>/logs?level=error" | jq -r '.data'
```

Only claim the app is live once `build-status = completed` **and** `status`
shows the pod running/healthy.

### Lifecycle & config

| Action | Call |
|---|---|
| List / get | `GET /apps` · `GET /apps/:id` |
| Update metadata | `PUT /apps/:id` |
| Set env vars | `PUT /apps/:id/env` |
| Set access | `PUT /apps/:id/permissions` |
| Start / stop / restart | `POST /apps/:id/start` · `/stop` · `/restart` |
| Metrics | `GET /apps/:id/metrics` |
| Delete | `DELETE /apps/:id` |

> Git-based deploys: `POST /api/v1/apps` (JSON) accepts `repository` + `branch`
> instead of a bundle, then `deploy` builds from the repo.

---

## 2. Serve correctly behind the proxy

Deployed apps are **never** reached on a bare port — all traffic goes through the
platform proxy at a **relative base path** the app is told at runtime:

| Env var | Meaning | Example |
|---|---|---|
| `STRONGLY_URL` | the app's relative proxy base path | `/api/proxy/app-xyz123` |
| `STRONGLY_HOST` | platform host | `https://app.strongly.ai` |
| `STRONGLY_APP_ID` | the app's id | `app-xyz123` |

`STRONGLY_URL` is **relative on purpose** so the same build works from
`localhost`, staging, and production. The app must serve all routes and assets
from that base path.

**The #1 app bug is a blank screen** — a SPA served at `/api/proxy/app-xyz/` but
routing as if it were at `/`. Fix it by injecting the base path at runtime and
telling the router about it:

```js
// server: inject runtime config into index.html
const cfg = {
  STRONGLY_URL: process.env.STRONGLY_URL || '',
  STRONGLY_HOST: process.env.STRONGLY_HOST || '',
  STRONGLY_APP_ID: process.env.STRONGLY_APP_ID || '',
};
html = html.replace('</head>',
  `<script>window.__RUNTIME_CONFIG__=${JSON.stringify(cfg)}</script></head>`);
```

```tsx
// client: React Router honours the base path
const basePath = (window as any).__RUNTIME_CONFIG__?.STRONGLY_URL || '';
<BrowserRouter basename={basePath}><App /></BrowserRouter>
```

Build API calls against `STRONGLY_URL` too (`${STRONGLY_URL}/api/...`), never a
hardcoded origin. Always expose a health endpoint (e.g. `GET /health → 200`).

---

## 3. Identity: read the signed-in user (JWT)

The platform signs the user in **before** the request reaches the app and passes
their identity in **one header**, a signed JWT:

```
Browser ──▶ Strongly proxy ──▶ your app
                 └─ adds: X-Strongly-User-Token: <signed JWT>
```

Payload is small and flat:

```json
{ "user": { "id": "...", "email": "...", "name": "...", "role": "..." } }
```

**Decode, do not verify.** Use the standard `jsonwebtoken` library and call
`jwt.decode()` — **not** `jwt.verify()`. The signing secret
(`STRONGLY_JWT_SECRET`) lives only in the platform, never in app containers. The
proxy is the trust boundary: it will not forward a request without a valid token,
so the token you receive is already trustworthy, and platform backend services
re-verify on real data paths. A forged token could only change a name on screen,
never grant data access.

```js
// server/middleware/auth.js
const jwt = require('jsonwebtoken');
module.exports = (req, _res, next) => {
  const raw = req.headers['x-strongly-user-token'];
  req.user = null;
  if (raw) {
    try { req.user = jwt.decode(raw)?.user ?? null; } catch { req.user = null; }
  }
  next();               // NO fallback: missing/malformed token => req.user stays null
};
```

Never invent a user. If there's no token (e.g. running locally with no platform
in front), the honest state is "not signed in."

**Convenience headers.** The proxy also injects plain headers if you prefer not
to decode: `X-Strongly-User-Id`, `X-Strongly-User-Email`, `X-Strongly-User-Name`,
`X-Strongly-User-Roles` (comma-separated), `X-Strongly-Org-Id`. The JWT is
canonical; the headers are a shortcut for simple cases.

**Roles.** Common platform roles are `admin`, `developer`, `app`. Map them to
your app's own roles rather than checking Strongly role strings all over the code:

```js
const ROLE = { admin: 'Admin', developer: 'Editor', app: 'Viewer' };
const appRole = ROLE[(req.user?.role || '').toLowerCase()] || 'Viewer';
```

**Local dev.** With no platform in front, mint a dev token (`jwt.sign({user:{…}},
'dev-secret')`) and attach it as `X-Strongly-User-Token` via your dev proxy, so
you can exercise the signed-in path. Keep it opt-in (behind an env var) so the
default local state is honestly "not signed in."

---

## 4. Wiring: `STRONGLY_SERVICES`

Everything you connect to an app (addons, data sources, AI models, workflows)
arrives as a single JSON env var, `STRONGLY_SERVICES`. Read connection details
from there — never hardcode a host or key.

```json
{
  "addons":      [{ "id":"mongodb-abc123", "configId":"mongodb", "type":"mongodb",
                    "internal":false, "connectionString":"mongodb://…", "host":"…", "port":27017,
                    "database":"appdb", "username":"…", "password":"…" }],
  "dataSources": [{ "id":"analytics-db", "type":"postgres", "connectionString":"postgresql://…" }],
  "aiModels":    [{ "id":"claude", "provider":"anthropic", "model":"claude-…",
                    "endpoint":"https://…/v1", "apiKey":"sk-…" }],
  "mlModels":    [{ "id":"rate-predictor", "endpoint":"http://…/predict", "protocol":"rest" }]
}
```

```js
const services = JSON.parse(process.env.STRONGLY_SERVICES || '{}');
const db  = services.addons?.find(a => a.configId === 'mongodb');   // match on configId, NOT id
const ai  = services.aiModels?.[0];
const conn = db?.connectionString;
```

Best practices:

- **Match on `configId`, not `id`.** `id` is dynamic (`mongodb-abc123`); `configId`
  is the stable name you chose. Matching on `id` will not find the addon.
- **Prefer `connectionString`** when present; only reconstruct from
  host/port/user/pass if it's missing.
- **Respect `internal: true`.** Internal addons are the app's own store (e.g.
  Superset's metadata DB) and must be hidden from user-facing "pick a database"
  features. Filter them out where users choose data.
- **Degrade honestly.** If a service isn't present, say so; don't fabricate one.

You choose what's wired at create time — `POST /api/v1/apps` (and the upload
routes) accept `addons`, `dataSources`, `aiModels`, and `workflows` arrays of ids
(discover ids via `GET /api/v1/addons`, `/datasources`, `/ai-models`,
`/workflows`). Connected workflows are surfaced under
`STRONGLY_SERVICES.services.workflows` so the app can trigger them.

---

## 5. Artifacts best practices (with the proxy)

An **artifact** is a file the app produces for the user — a report, dashboard
export, generated PDF/HTML, a document. Store artifacts in the platform's Library
(S3-backed, SSE-KMS encrypted) instead of on the app's ephemeral disk, then hand
the user a **short-lived pre-signed URL** so the download goes straight to S3 and
does not stream a large body back through your app and the proxy.

**Save** — `POST /api/v1/artifacts`, scope `artifacts:write`:

```bash
curl -s -X POST -H "X-API-Key: $STRONGLY_API_KEY" -H "Content-Type: application/json" \
  -d '{
        "title": "Q3 report",
        "artifact_type": "report",
        "contentType": "application/pdf",
        "encoding": "base64",
        "content": "'"$(base64 -i report.pdf)"'"
      }' \
  "$HOST/api/v1/artifacts"
# -> { "success": true, "data": { "_id": "<ARTIFACT_ID>" } }
```

- `encoding`: `base64` for binary (default), `utf8` for text (HTML/markdown).
- `content` is uploaded to S3; only metadata is stored in Mongo.

**Serve** — `GET /api/v1/artifacts/:id/download-url` (scope `artifacts:read`)
returns a pre-signed URL, default TTL 5 min, `ttlSeconds` up to **900**:

```bash
api "/artifacts/<ARTIFACT_ID>/download-url?ttlSeconds=600" | jq -r '.data.url'
```

Pattern for a proxied app: the app's own endpoint (behind the proxy, so it knows
the signed-in user) calls the platform API with its `X-API-Key`, mints a
download URL, and **redirects the browser** to it (302). The heavy bytes flow
browser → S3 directly; your app and the proxy only pass a small redirect.

```js
app.get('/download/:id', async (req, res) => {
  if (!req.user) return res.status(401).end();               // identity from §3
  const r = await fetch(`${process.env.STRONGLY_HOST}/api/v1/artifacts/${req.params.id}/download-url`,
                        { headers: { 'X-API-Key': process.env.STRONGLY_API_KEY } });
  const { data } = await r.json();
  res.redirect(302, data.url);                                // browser → S3, not through the app
});
```

Other operations: `GET /artifacts` (list/gallery), `GET /artifacts/:id`
(metadata), `GET /artifacts/:id/versions` + `POST /artifacts/:id/restore`
(versioning), `PATCH /artifacts/:id`, `DELETE /artifacts/:id`, and
`POST /artifacts/:id/share` · `/unshare` · `/toggle-public` · `/toggle-org-share`
for sharing.

> Give the app its own API key as an env var (`STRONGLY_API_KEY`) so it can call
> the platform API for artifacts. That key is the app's, not the end user's —
> the end user is identified by the JWT from §3, the API key authorizes the app's
> platform calls.

---

## 6. `deploy.json` (wizard / marketplace apps)

The REST flow above is the direct path. Apps meant to be **published as
marketplace offerings** add a `deploy.json` at the bundle root that declares the
deployment wizard: `steps`, `permissions`, `resources` (defaults + options),
`addons`, `aiGateway`, `models` (ML), `environmentVariables`, `healthCheck`, and
optional `seedData`. The platform renders those as the user-facing deploy wizard
and provisions the declared services (delivered back via `STRONGLY_SERVICES`).
Reach for `deploy.json` only when packaging a reusable, user-configurable offering;
a one-off app just needs a `Dockerfile` and the REST calls above.

---

## Checklist

- [ ] Bundle has a `Dockerfile`; it's small.
- [ ] App serves every route/asset from `STRONGLY_URL`; router has the base path.
- [ ] Health endpoint returns 200.
- [ ] Identity read by **decoding** `X-Strongly-User-Token`; no invented user, no `verify()`.
- [ ] Services read from `STRONGLY_SERVICES`, matched on `configId`, internal addons filtered.
- [ ] Artifacts saved to the Library; downloads via short-lived pre-signed URL (302), not streamed through the app.
- [ ] After deploy: build-status `completed` **and** pod `status` healthy before declaring success; on build failure, read build-logs.
