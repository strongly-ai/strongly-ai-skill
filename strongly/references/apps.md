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
  the app's permissions: `PUT /apps/:id/permissions` with `isPublic` and
  `allowedUsers`; the manifest has no permissions field).
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

An app is reached **only** through a platform proxy at a relative base path,
never on a bare origin, in both places it runs:

| Where | Base path |
|---|---|
| Deployed (Apps) | `/api/proxy/<app id>/` |
| Running in a workspace while you build it | `/api/workspace-proxy/<workspace id>/port/<port>/` |

Two facts drive everything, the same in both:

- The proxy **strips its prefix** before the request reaches your app: the
  browser asks for `/api/proxy/app-xyz/assets/x.js`, your app receives
  `/assets/x.js`.
- The proxy sends the prefix it stripped as the **`X-Forwarded-Prefix`** request
  header (e.g. `/api/proxy/app-xyz`). Build every URL from it, per request; then
  the same build works deployed and in the workspace. (A deployed app also gets
  `STRONGLY_URL`, `STRONGLY_HOST` and `STRONGLY_APP_ID` env vars; a workspace
  sets none of them, so don't depend on them for paths. Every workspace, job and
  app has `STRONGLY_API_URL` for API calls and `STRONGLY_BASE_URL`, the public
  address, for full links.)
- Listen on **`PORT`**, else 3000: a deployed app gets `PORT` from the platform;
  in a workspace 8080 is taken by VS Code, so run on 3000 (or another free port)
  and open `$STRONGLY_BASE_URL/api/workspace-proxy/$STRONGLY_WORKSPACE_ID/port/3000/`
  (with its trailing slash; without it the platform redirects there). Only the workspace's owner can open its
  port URLs (as only they can open the workspace), signed in to the platform:
  it is for testing while you build, not for sharing; deploy the app to share it.

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
// Deployed: /api/proxy/<app>. In a workspace: /api/workspace-proxy/<ws>/port/<n>.
const PROXY_PREFIX = /^(\/api\/proxy\/[^/]+|\/api\/workspace-proxy\/[^/]+\/port\/\d+)/;
export const getRuntimeBase = (p = location.pathname) => (p.match(PROXY_PREFIX)?.[1] ?? '');
export const getBasename = (p = location.pathname) => getRuntimeBase(p) || '/';   // router
export const getApiBase  = (p = location.pathname) => `${getRuntimeBase(p)}/api`; // fetch base
```

```tsx
<BrowserRouter basename={getBasename()}>…</BrowserRouter>
// fetch(`${getApiBase()}/boards`)  ->  /api/proxy/app-xyz/api/boards deployed,
//   /api/workspace-proxy/ws-1/port/3000/api/boards in a workspace, /api with no proxy
```

### 1c. Server: serve assets, require the prefix, don't hand HTML to the module loader

The single-container pattern (kanban `Dockerfile`): `vite build` → copy `dist` to
`server/public`, node serves static **and** API on one port.

```js
// Static BEFORE auth (assets must not require a login). Proxy already stripped
// the prefix, so serve at /assets, not /<prefix>/assets.
app.use('/assets', express.static(path.join(pub, 'assets'), { maxAge: '1d', etag: true }));
app.use(express.static(pub, { index: false }));           // favicon, etc.
app.use('/api', apiLimiter, authMiddleware, apiRouter);   // API auth AFTER static

// The prefix the proxy stripped, per request: /api/proxy/<app> deployed,
// /api/workspace-proxy/<ws>/port/<n> in a workspace. With no proxy in front
// (curl on the pod) there is no prefix.
const prefixOf = (req) => (req.get('X-Forwarded-Prefix') || '').replace(/\/$/, '');

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
  const base = prefixOf(req);
  let html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  const cfg = JSON.stringify({ BASE_PATH: base, API_URL: '/api' })
                   .replace(/</g, '\\u003c');
  html = html
    .replace('</head>', `<script>window.__RUNTIME_CONFIG__=${cfg}</script></head>`)
    .replace('<head>', `<head><base href="${base}/">`)
    .replace(/(src|href)="\.?\/assets\//g, `$1="${base}/assets/`)
    .replace(/href="\.?\/favicon/g, `href="${base}/favicon`);
  res.set('Cache-Control', 'no-store').send(html);
});
```

Always expose `GET /health → 200`, and listen on `PORT`, else 3000:

```js
app.listen(Number(process.env.PORT || 3000), '0.0.0.0');
```

### 1c checklist (why each line exists)
- `base: './'` → assets are relative, not root-absolute.
- Static served at `/assets`, **before** auth → CSS/JS load without a login.
- Prefix from `X-Forwarded-Prefix` per request → the same build works deployed and in a workspace.
- `PORT`, else 3000 → 8080 is VS Code's in a workspace.
- 404 static-looking paths in the fallback → kills "module script failed".
- `<base href>` + asset rewrite → every relative URL resolves under the prefix.
- `Cache-Control: no-store` on the shell → no stale-shell after redeploy.

### 1d. Build pitfalls that fail a deploy
- **Node 18 in the generated Dockerfile.** Without your own `Dockerfile`, a Node,
  React or fullstack app builds `FROM node:18-alpine`. A dependency that needs
  Node 20+ (current Vite, React Router 7 and others) fails the build: pin versions
  that support Node 18, or ship a `Dockerfile` `FROM node:20-alpine` (it is used as
  written).
- **Express 5** (what `npm i express` installs now): `app.get('*', ...)` crashes
  at start ("Missing parameter name"). Use `app.get('/{*splat}', ...)` or a final
  `app.use((req, res) => ...)` for the SPA fallback.
- **`.gitignore` decides what is built.** A volume or GitHub source builds what
  is committed: anything ignored (`dist/`, `build/`, `.env`, a generated file) is
  not in the build. Build artifacts inside the `Dockerfile`, set settings as the
  app's environment variables (not an ignored `.env`), and commit
  `package-lock.json` so `npm ci` works.

---

## 2. Deploy an app via the REST API

An app builds from one of three **sources**, then deploys the built image:

| Source | When | How |
|---|---|---|
| **Volume** | The code is on a Strongly volume kept on the **Strongly filesystem** (anything under `/volumes/` in a workspace, by default) | `bundleSourceType: "volume"`, `bundleSource: {volumeId, folderPath?}` |
| **Upload** | The code is anywhere else you can zip it (a workspace folder outside `/volumes/`, your laptop) | multipart `POST /apps/upload` (below) |
| **GitHub** | The code is on a **GitHub-backed** volume, or the user asks to build from a GitHub repo | `bundleSourceType: "github"`, `bundleSource: {repoUrl, branch, sshKeyId, subdirectory?}` |

**Choose the source from where the code is, before anything else:**

1. **Under `/volumes/`: ask the volume, not git.** Run `pwd`. If it is inside
   `/volumes/<scope>/<volume name>/code`, the code is on that volume. Do NOT
   decide from `git remote -v`: a volume's code dir is always a git clone, so it
   always shows a remote. Read the volume instead (`GET /volumes`, match the
   name, look at `code.filesystemType`):
   - `strongly` (the default): deploy from the **volume**. No GitHub repo, SSH
     key or zip is involved; never ask the user to set up SSH or push to GitHub.
   - `github`: the volume's code lives in GitHub. Deploy with the **GitHub**
     source using that volume's own `code.repoUrl`, `code.branch` and
     `code.sshKeyId` (the key is already registered; it is how the volume
     clones). Push the workspace's changes first (the workspace Sync).
2. **Not on a volume: upload a zip.** Zip the app folder and upload it. (Or, to
   keep rebuilding from the workspace, move the code into a volume and use 1.)
3. **A GitHub repo that is not on a volume: only when the user asks.** It needs
   an SSH key the user ALREADY registered (`GET /users/me/github-ssh-keys`); if
   they have none, offer 1 or 2 rather than walking them through SSH setup.

### From a workspace's volume (recommended when you built it in a workspace)

A workspace mounts its project volume's code at `/volumes/local/<project name>/code`
(the code you write; a shared project volume's code under `/volumes/shared/` is
read-only, and a shared volume created on its own holds data only, with no code to
build). That directory is a git clone of the volume's code. The build takes the volume's code **as last synced**, so sync first:

```bash
# 1) Save the code to the volume: the workspace's Sync (commits and pushes the
#    project volume's code; also the Sync button on the workspace page) ...
#    Inside the workspace its own id is $STRONGLY_WORKSPACE_ID (the hostname is a
#    lowercased deployment name, not the id); from outside, find it by name with
#    GET /workspaces?search=<name>.
WORKSPACE_ID="${STRONGLY_WORKSPACE_ID}"
curl -s -X POST "${auth[@]}" "$BASE/workspaces/$WORKSPACE_ID/sync"
#    ... or from a terminal in the workspace:
#    cd /volumes/local/my-project/code && git add -A && git commit -m "v2" && git push

# 2) Find the volume id (by name) and create the app from it. folderPath is the
#    folder inside the volume's code that holds strongly.manifest.yaml; omit it
#    when the app is the whole code. The app needs a size: environmentId, or cpu + memory.
#    To give the app the volume's data too (its data/ at
#    /volumes/local/<name>/data while the volume is not shared, or
#    /volumes/shared/<name>/data once it is), also pick the volume in "volumes" and set a
#    "disk": a volume is kept on the app's disk, and one without a disk is refused.
#    Size it with cpu/memory/disk as below: an environmentId whose environment has
#    no disk (the standard Small, Medium and Large have none) is refused volumes.
#    Building from a volume does NOT mount it: without "volumes" the app has no data/.
VOLUME_ID=$(curl -s "${auth[@]}" "$BASE/volumes" | jq -r '.data[] | select(.name=="my-project") | ._id')
APP_ID=$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -X POST "$BASE/apps" -d "{
  \"name\": \"my-app\", \"cpu\": \"0.5\", \"memory\": \"1GB\", \"disk\": \"5GB\",
  \"bundleSourceType\": \"volume\",
  \"bundleSource\": {\"volumeId\": \"$VOLUME_ID\", \"folderPath\": \"apps/my-app\"},
  \"volumes\": [\"$VOLUME_ID\"]
}" | jq -r '.data.appId')
```

### From GitHub (a GitHub-backed volume, or a repo the user names)

```bash
# The build clones the repo with one of the user's GitHub SSH keys (registered in
# their profile settings; listed here). repoUrl must be the SSH form. For a
# GitHub-backed volume use the volume's own code.repoUrl, code.branch and
# code.sshKeyId. A repo with no key listed: deploy from a volume or a zip instead.
SSH_KEY_ID=$(curl -s "${auth[@]}" "$BASE/users/me/github-ssh-keys" | jq -r '.data[0]._id')
APP_ID=$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -X POST "$BASE/apps" -d "{
  \"name\": \"my-app\", \"cpu\": \"0.5\", \"memory\": \"1GB\",
  \"bundleSourceType\": \"github\",
  \"bundleSource\": {\"repoUrl\": \"git@github.com:acme/my-app.git\", \"branch\": \"main\", \"sshKeyId\": \"$SSH_KEY_ID\"}
}" | jq -r '.data.appId')
```

### From an uploaded zip

A bundle is a `.zip` of your source (a `strongly.manifest.yaml` and/or a
`Dockerfile`); keep it small.

```bash
APP_ID=$(curl -s "${auth[@]}" \
  -F name=my-app -F 'resources={"memory":"1Gi","cpu":"500m"}' \
  -F "file=@bundle.zip;type=application/zip" \
  "$BASE/apps/upload" | jq -r '.data._id')
```

### Then, for every source: build → deploy → running

```bash
# Poll the build to completed BEFORE deploying (pending|building|completed|failed).
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/build-status" | jq -r '.data.status'      # until "completed"
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/build-logs?level=error" | jq -r '.data'   # on "failed"

# Deploy the built image, then poll the pod to healthy.
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/deploy"
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/status" | jq -r '.data.status'            # until "running" ("error": read /logs)
```

### New versions (same app id: URL, config and permissions are kept)

```bash
# Volume or GitHub app: sync (volume), then rebuild from the app's recorded source.
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/rebuild"
# ... or switch the app to another source (it becomes the app's source):
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/rebuild" \
  -d "{\"bundleSourceType\": \"volume\", \"bundleSource\": {\"volumeId\": \"$VOLUME_ID\"}}"
# Zip app: upload the new bundle.
curl -s "${auth[@]}" -F "file=@bundle.zip;type=application/zip" "$BASE/apps/$APP_ID/upload"
# All three return 202 and build asynchronously: poll build-status to completed,
# then deploy again. The running version keeps serving until that deploy.
```

Lifecycle: `GET /apps` · `GET/PUT /apps/:id` · `PUT /apps/:id/env` ·
`PUT /apps/:id/permissions` · `POST /apps/:id/start|stop|restart` ·
`GET /apps/:id/logs` · `GET /apps/:id/metrics` · `DELETE /apps/:id`.

### Branded sign-in, the app's own users, and usage

An app can have its own public sign-in, sign-up, forgot-password and sign-out
pages at `<platform>/<slug>/`, with its logo and name, for a customer's or a
team's own users. Anyone who signs up there becomes an **app user** whose home
app is this app (they land in it full screen, never in the platform) and is
listed in the app's permissions.

```bash
# Turn it on (only the fields sent change; enabling also enables Home App).
# access: "instant" (usable at once; email verification when mail is set up)
# or "approval" (an app admin activates each account).
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/auth" -d '{
  "enabled": true, "slug": "client-portal", "signupEnabled": true,
  "access": "approval", "allowedDomains": ["example.com"] }'
# -> data.auth.pages = { signIn, signUp, forgotPassword, signOut }; share signIn.
# GET /apps/:id returns the same under data.auth (logo omitted; hasLogo).

# The app's users: status active | pending (waiting for approval) | archived
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/auth/users?status=pending&search=&sort=-createdAt&limit=50"
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/auth/users/$USER_ID/activate"       # approve / re-enable
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/auth/users/$USER_ID/deactivate"     # signed out, cannot sign in
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/auth/users/$USER_ID/password-reset" # emails the branded reset link
curl -s -X DELETE "${auth[@]}" "$BASE/apps/$APP_ID/auth/users/$USER_ID"              # off the app; account kept

# Usage (the platform's own count of proxied requests; range 7d | 30d | 90d)
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/analytics?range=30d"          # summary, per day, session lengths, starts by weekday/hour
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/analytics/users?range=30d&sort=-minutes&limit=50"  # who used it: sessions, minutes, requests, lastSeen
curl -s "${auth[@]}" "$BASE/apps/$APP_ID?include=analytics&range=30d"  # detail with the summary
```

### Charging for access (the owner's own Stripe account)

**Needs the Stripe App Payments plugin.** Paid access exists only while the Stripe App Payments marketplace plugin is installed and on for the organization (`POST /plugins/stripe-app-payments/install`, admin; in multi-tenant an organization developer). Without it every paid-access endpoint answers `409 plugin-not-installed` and the Auth tab shows no Paid access card. The plugin refuses to be disabled while any app still charges.

An app with branded sign-in can sell access with the owner's OWN Stripe keys
(no platform fee; nothing goes through Strongly). This is NOT Strongly billing:
it is unrelated to the Strongly subscription, credits or FinOps, and nothing
here touches them. Plans are recurring Stripe
prices; a plan is `individual` (one person pays for themself) or `team` (one
payer pays per seat and invites members, who pay nothing).

```bash
# Keys (stored encrypted, never readable back) and settings; the owner registers
# data.paidAccess.webhookUrl in their Stripe dashboard and pastes its signing secret.
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/paid-access" -d '{
  "stripeSecretKey": "sk_live_...", "stripeWebhookSecret": "whsec_...", "graceDays": 3 }'
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/paid-access/plans/pro" \
  -d '{ "name": "Pro", "kind": "individual", "stripePriceId": "price_...", "trialDays": 14 }'
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/paid-access/plans/team" \
  -d '{ "name": "Team", "kind": "team", "stripePriceId": "price_...", "minSeats": 2 }'
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/paid-access" -d '{ "enabled": true }'
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/paid-access"                         # settings (key masked) and plans
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/paid-access/subscriptions?status=active"  # payer, plan, status, seats
```

Users of the app pick a plan at `<platform>/<slug>/plans` (Stripe Checkout)
and manage it at `<platform>/<slug>/billing` (Stripe Customer Portal; a team
payer also runs seats, members and invites there). The proxy serves a user
while a subscription covers them; the owner, collaborators, app admins and
platform admins never need one. Inside the app, link to `_strongly/billing`
and `_strongly/plans` (`target="_top"`). A covered user's token carries
`user.plan` `{ id, kind, status }`: gate features on it, never on anything
the client sends.

**Sign-out inside a home app.** A home app fills the screen with no platform
chrome, so the app links its own sign-out: `<a href="_strongly/sign-out"
target="_top">Sign out</a>` (relative to the app's root; `target="_top"` so the
whole page navigates, not the frame). It ends the session, clears the cookie and
lands on the app's branded sign-in page. From script: `POST` the same address,
then set `window.top.location.href` to the `redirect` it answers. The page
`auth.pages.signOut` does the same from a plain link.

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

**Volumes are not services:** an app reads a volume's files directly. Pass
`volumes: ["<volume id>", ...]` on create (`POST /apps`) or update (`PUT /apps/:id`,
applied at the next deploy/start/restart); each must be one the app's owner may
use (their own, or shared with them). The owner's own project volume that is not
shared mounts at `/volumes/local/<name>`; every shared volume, the owner's own
included, mounts at `/volumes/shared/<name>`. `code/` is read-only (absent for a
volume created as shared, which holds data only; a project's volume that is shared
or kept from a deleted project keeps its code), `data/` at its latest
data, read and write, every written file saved to the volume as a new version as
the app goes (no Sync). The app needs a disk size (its volumes are kept on it).
This is how sample data in a volume's `data/` reaches a deployed app.

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
const wf = s.workflows?.available_workflows?.[0];   // POST its input to wf.endpoints.proxy_url (no auth header)
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

## 6. The manifest (`strongly.manifest.yaml`)

An app's **`strongly.manifest.yaml`** sits in its root (next to its `Dockerfile`,
or in the `folderPath` you deploy from). Write one: it sets the type, port and
health check explicitly (without one the build guesses the type from the files).
The build refuses a manifest with an invalid field, naming it. `type` is one of
`react`, `nodejs`, `static`, `fullstack`, `flask`, `rshiny`, `mcp_server` or
`custom`; any other value (`app`, for one) fails the build:

```yaml
# strongly.manifest.yaml
version: "1.0"
type: nodejs            # react | nodejs | static | fullstack | flask | rshiny | mcp_server | custom
name: kanban
description: Project board with real-time collaboration

ports:
  - port: 3000          # the port the app listens on; PORT is set to it
    name: http

env:
  - name: NODE_ENV
    value: production

health_check:
  path: /health
  initial_delay: 15
  period: 30
```

| Key | Purpose |
|---|---|
| `version` / `type` / `name` / `description` | Identity; `type` from the list above. |
| `ports[]` | `port`, `name`, `expose`. The app listens on its port (the first with `expose`, else the first) and the platform routes to it; `PORT` is set to the same port, so binding `PORT` or the declared port both work, and a Dockerfile that runs the app on that port needs no change. Ports below 1024 (static's 80) work too. |
| `env[]` | `name`, `value`, `required`, `secret` (stored as a secret), `buildtime` (a build arg), `description`. |
| `runtime` | `command`, `working_dir`, `health_check_path`, `startup_timeout`. |
| `health_check` | `path`, `initial_delay`, `period`, `timeout`, `failure_threshold`: the readiness probe (serve it, §1). |
| `resources` | `cpu_request`, `memory_request`, `cpu_limit`, `memory_limit`, `gpu`. |
| `proxy` | `websocket`, `timeout`. |

What the app is connected to (addons, data sources, AI models, workflows) is set
on the app (§2, §4), not in this file; the running app reads the connections from
`STRONGLY_SERVICES`.

**Marketplace offerings only:** an offering also ships a `deploy.json`, the
deploy **wizard** the marketplace shows (its steps, resource options, and the
addons it provisions, whose `addons[].id` becomes the `configId` you match in
`STRONGLY_SERVICES`). See `references/marketplace.md`. A one-off app never needs
one; `strongly.manifest.yaml` is the file the build reads.

---

## Checklist
- [ ] Vite `base: './'`; client base derived from the URL (no `import.meta.env.BASE_URL`).
- [ ] `strongly.manifest.yaml` in the app root with a `type` the builder accepts.
- [ ] Server: listen on `PORT`, else 3000; base from `X-Forwarded-Prefix` per request; static `/assets` before auth; 404 static-looking paths in the SPA fallback; `<base href>` + asset rewrite; `Cache-Control: no-store` on the shell.
- [ ] `GET /health → 200`.
- [ ] Identity by reading `X-Strongly-User-Token` **or** `Authorization: Bearer`; verify-if-secret-else-decode; no invented user.
- [ ] Services from `STRONGLY_SERVICES`, matched on `configId`, internal addons hidden.
- [ ] Artifacts saved to the Library; downloads via 302 to a short-lived pre-signed URL.
- [ ] After deploy: build `completed` AND pod healthy before declaring success; read build-logs on failure.
- [ ] When unsure about any of this, compare against the **kanban** app.
