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
  the app's permissions: `POST /apps/:id/permissions/members` `{ userId, role }`
  per person, `PATCH /apps/:id/permissions` `{ "visibility": "public" }` for
  everyone; the manifest has no permissions field).
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
| Deployed, on a platform with an apps domain | the same `/api/proxy/<app id>/`, on `https://<slug>.<apps domain>` (the same `X-Forwarded-Prefix`, `STRONGLY_URL` and headers: the app runs unchanged) |
| Running in a workspace while you build it | `/api/workspace-proxy/<workspace id>/port/<port>/` |

Where a deployed app opens is `address` from `GET /apps/:id`; never build it. On a
platform with an apps domain (the admin's `APPS_DOMAIN`) every app is its own
origin: signed-in users are signed in to it through Strongly on their first page
load there, its own cookies, `localStorage`, IndexedDB and service workers work,
and its pages can never use the viewer's Strongly session. The platform's own
host then serves no app content to anything that comes through its load balancer:
a page load of `<platform>/api/proxy/<app>/...` is redirected (`303`) to the app's
address, the same path; every other request (API key, token, cookie or none)
answers `409` JSON naming `appUrl`; a websocket upgrade `403`.

Calling an app from code (not a browser):
- A script or the SDK outside the platform uses its `address` and sends `X-API-Key`.
- A workload inside the platform (a job, a workspace, a workflow node, an agent,
  another app) calls `$STRONGLY_API_URL/api/proxy/<app id>/...` (the dashboard's
  in-cluster address) with no auth header, the same on every platform, with or
  without an apps domain: its auth-proxy signs the call as the workload's owner,
  it never leaves the cluster, and the app is served to that owner by the app's
  sharing (`403` for an owner it is not shared with). Never call the app's
  `address` from a workload: that goes out through the internet and carries no
  identity.

A browser's Strongly login cookie is never accepted at the app's address.

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
- Calls to platform services (`STRONGLY_API_URL`, the gateway) go through the
  pod's auth-proxy, which keeps HTTP/1.1 connections open (idle 600s, says
  `Connection: close` whenever it closes one): use the HTTP client's normal
  connection pool; never open a connection per call. Streams (SSE) and
  WebSockets pass through as written.
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
- **Node in the generated Dockerfile.** Without your own `Dockerfile`, a Node,
  React or fullstack app builds `FROM node:22.23.4-alpine` (the patched October
  2026 Node.js security release). An app that ships its own `Dockerfile` is built
  from it as written: base it on a patched Node (`node:22.23.4-alpine` or later),
  never Node 18 or 20, which are end-of-life and get no security fixes.
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
| **Upload** | The code is anywhere else you can zip it (a workspace folder outside `/volumes/`, your laptop) | multipart `POST /apps/import` (below) |
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
   an SSH key the user ALREADY registered (`GET /me/github-ssh-keys`); if
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
#    GET /workspaces?q=<name>.
WORKSPACE_ID="${STRONGLY_WORKSPACE_ID}"
curl -s -X POST "${auth[@]}" "$BASE/workspaces/$WORKSPACE_ID/sync"
#    ... or from a terminal in the workspace:
#    cd /volumes/local/my-project/code && git add -A && git commit -m "v2" && git push

# 2) Find the volume id (by name) and create the app from it. folderPath is the
#    folder inside the volume's code that holds strongly.manifest.yaml; omit it
#    when the app is the whole code. The app needs a size: environmentId, or cpu + memory.
#    The size is the whole pod: it must be more than the platform's share beside the app
#    (GET $BASE/apps/minimum-size: platform, or withVolumes when it mounts volumes).
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
}" | jq -r '.data._id')
```

### From GitHub (a GitHub-backed volume, or a repo the user names)

```bash
# The build clones the repo with one of the user's GitHub SSH keys (registered in
# their profile settings; listed here). repoUrl must be the SSH form. For a
# GitHub-backed volume use the volume's own code.repoUrl, code.branch and
# code.sshKeyId. A repo with no key listed: deploy from a volume or a zip instead.
SSH_KEY_ID=$(curl -s "${auth[@]}" "$BASE/me/github-ssh-keys" | jq -r '.data[0]._id')
APP_ID=$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -X POST "$BASE/apps" -d "{
  \"name\": \"my-app\", \"cpu\": \"0.5\", \"memory\": \"1GB\",
  \"bundleSourceType\": \"github\",
  \"bundleSource\": {\"repoUrl\": \"git@github.com:acme/my-app.git\", \"branch\": \"main\", \"sshKeyId\": \"$SSH_KEY_ID\"}
}" | jq -r '.data._id')
```

### From an uploaded zip

A bundle is a `.zip` of your source (a `strongly.manifest.yaml` and/or a
`Dockerfile`); keep it small.

```bash
APP_ID=$(curl -s "${auth[@]}" \
  -F name=my-app -F 'resources={"memory":"1Gi","cpu":"500m"}' \
  -F "file=@bundle.zip;type=application/zip" \
  "$BASE/apps/import" | jq -r '.data._id')
```

### Then, for every source: build → deploy → running

```bash
# Poll the build to completed BEFORE deploying (pending|building|completed|failed).
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/build-status" | jq -r '.data.status'      # until "completed"
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/build-logs?level=error" | jq -r '.data'   # on "failed"
# The whole build log as a file: a signed download link (5 minutes), fetched without credentials.
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/build-logs/download" | jq -r '.data.url' | xargs curl -s -o build.log

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
curl -s -X PUT "${auth[@]}" -F "file=@bundle.zip;type=application/zip" "$BASE/apps/$APP_ID/source"
# All three return 202 and build asynchronously: poll build-status to completed,
# then deploy again. The running version keeps serving until that deploy.
```

### Version history and rollback

Every rollout that runs something new (a new build, or changed settings) records a version:
its image (`build.version`, `build.repositoryUri`), its settings (environment or size,
instances, capacity, autoscaling, services, volumes, environment variable NAMES; values stay
on the app), `deployedBy`/`deployedByName`, `deployedAt`; `isCurrent` marks the one running.
Rolling back deploys a version's image and settings again as a NEW current version
(`rolledBackFrom`), with no downtime; its settings are checked as an edit is, and what it
changes is recorded in the app's activity. Confirm with the user before rolling back; the
version running now answers 409.

```bash
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/versions" \
  | jq '.data[] | {_id, versionNumber, image: .build.version, isCurrent, deployedByName}'
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/versions/$VERSION_ID/deploy" | jq '.data.versionNumber'
```

Lifecycle: `GET /apps` · `GET /apps/stats` · `GET/PATCH /apps/:id` · `PUT /apps/:id/env` ·
`GET/PATCH /apps/:id/permissions` + `…/permissions/members` · `POST /apps/:id/start|stop|restart` ·
`GET /apps/:id/logs` · `GET /apps/:id/metrics` · `GET /apps/:id/time-series` · `DELETE /apps/:id`.

`GET /apps/:id/time-series?window=24h|7d|30d` is the app's CPU and memory over time from
Kubecost's hourly records (the mean used, the busiest hour, its size; null where it did not
run), for its owner, collaborators and admins; `GET /apps/:id/metrics` measures it now.

`GET /apps/stats` counts the apps `GET /apps` lists, with the same filters (`q`, `status`,
`environmentId`, `publicAccess`), over every one you may see: `{ total, byStatus[{status, total}],
instances }` (replicas set, added up), most first.

Who can open an app is ONE place in the dashboard: the app's **Permissions** tab
(sections Access, Users, Sign-in, Native apps, Connected apps (MCP), Domains).
Access is the platform's Access Control (`PATCH /apps/:id/permissions`
`visibility` public = "Allow all users": every signed-in user) plus how app users
get in: Private, Sign-in required (branded sign-in, below) or Public (below).
Users is one list of everyone who can open it by name, `GET /apps/:id/users`
(`type` platform = a Strongly user, app = an app user; `access` owner, editor =
Can edit, user = Can use). It names other people, so only those who manage the
app read it (owner, Can edit, app admins, administrators); anyone who only uses
it (Can use, an app user, a Home App user) gets 403. Add a Strongly user with `POST
/apps/:id/permissions/members` (`role` editor or user); add an app user as their
Home App with `POST /apps/:id/users`, or to use only with role user.

### Branded sign-in, the app's own users, and usage

An app can have its own public sign-in, sign-up, forgot-password and sign-out
pages at `<platform>/app/<slug>/`, with its logo and name, for a customer's or a
team's own users. Anyone who signs up there becomes an **app user** whose home
app is this app (they land in it full screen, never in the platform) and is
listed in the app's permissions. Their organization follows the tenancy mode:
single-tenant (one user per organization) they get their OWN organization and
namespace, and their clone of the app's base lives there; multi-tenant they
join the APP's organization and their clone lives there (binding an existing
user requires them to be an active member of the app's organization). Either
way the app owner lists and manages them (`GET /apps/:id/users?type=app`) and their
clone uses the owner's models, tool workflows, workspace and MCP servers.

```bash
# Turn it on (only the fields sent change; enabling also enables Home App).
# Every new account confirms its email with a 6-digit code first. access:
# "instant" (usable once confirmed) or "approval" (then an app admin activates it).
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/auth" -d '{
  "enabled": true, "slug": "client-portal", "signupEnabled": true,
  "access": "approval", "allowedDomains": ["example.com"] }'
# -> data.auth.pages = { signIn, signUp, forgotPassword, signOut }; share signIn.
# GET /apps/:id returns the same under data.auth (logo omitted; hasLogo).
# The pages' look: primaryColor (buttons and links), buttonTextColor, backgroundColor
# (#RRGGBB; null = the platform's own) and headingFont (a Google Fonts family). The
# button text on the button and the links on the background must meet WCAG AA (4.5:1)
# or the PATCH is refused (400, the detail names the pair to change).
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/auth" -d '{
  "primaryColor": "#0F2340", "buttonTextColor": "#C9A227", "backgroundColor": "#F7F8FA",
  "headingFont": "Cormorant Garamond" }'

# Everyone who can open it by name (type platform | app, access owner | editor | user);
# status active | pending (waiting for approval) | archived (owner, app admins, admins only)
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/users?type=app&status=pending&q=&sort=-createdAt&limit=50"
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/users/$USER_ID"                       # one user; PATCH and reset-password answer it too
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' -d "{\"userId\": \"$USER_ID\"}" \
  "$BASE/apps/$APP_ID/users"                                                  # add an app user (POST /users role app): Home App + their agent clone; 409 if another app's
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' -d '{"active":true}' \
  "$BASE/apps/$APP_ID/users/$USER_ID"                                         # approve / re-enable
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' -d '{"active":false}' \
  "$BASE/apps/$APP_ID/users/$USER_ID"                                         # signed out, cannot sign in
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' -d '{"role":"admin"}' \
  "$BASE/apps/$APP_ID/users/$USER_ID"                                         # their role in the app (appRole): admin | user; owner or platform admin only
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/users/$USER_ID/reset-password" # emails a reset code (Home App users)
curl -s -X DELETE "${auth[@]}" "$BASE/apps/$APP_ID/users/$USER_ID"                   # off the app; account kept

# Usage (the platform's own count of proxied requests; range 7d | 30d | 90d)
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/analytics?range=30d"          # summary, per day, session lengths, starts by weekday/hour
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/analytics/users?range=30d&sort=-minutes&limit=50"  # who used it: sessions, minutes, requests, lastSeen
curl -s "${auth[@]}" "$BASE/apps/$APP_ID?include=analytics&range=30d"  # detail with the summary
```

### Charging for access (the owner's own Stripe account)

**Needs the Stripe App Payments plugin.** Paid access exists only while the Stripe App Payments marketplace plugin is installed and on for the organization (`POST /plugins/instances` with `pluginId` `stripe-app-payments`, admin; in multi-tenant an organization developer). Without it every paid-access endpoint answers `409 plugin-not-installed` and the app's Permissions tab shows no Paid access card. The plugin refuses to be turned off or uninstalled while any app still charges (`409 invalid-state`).

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

Users of the app pick a plan at `<platform>/app/<slug>/plans` (Stripe Checkout)
and manage it at `<platform>/app/<slug>/billing` (Stripe Customer Portal; a team
payer also runs seats, members and invites there). The proxy serves a user
while a subscription covers them; those who manage the app (the owner, Can edit
collaborators, app admins, platform admins and, multi-tenant, the organization's
admins) never need one. Plans are for the app's users (app users, Can use,
Home App users). Inside the app, link to `_strongly/billing`
and `_strongly/plans` (`target="_top"`). A covered user's token carries
`user.plan` `{ id, kind, status }`: gate features on it, never on anything
the client sends.

### Native app sign-in (the developer's own iPhone app)

A developer can ship their own iPhone app for the app's users, with native
sign-in screens (no web pages). Its users are app users only, bound to the app
as their Home App, by the same rules as the branded pages (sign-up open or
closed, instant or approval access, allowed domains, the agent cloned for each
user). Only the settings are REST; the sign-in itself is DDP (Meteor), never
REST: the app proxy runs on the Meteor login token it gives.

```bash
# Turn it on (needs the branded sign-in settings saved; enables Home App).
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/native-sign-in" \
  -d '{ "enabled": true, "iosBundleIds": ["com.example.portal"] }'
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/native-sign-in"   # { appId, nativeSignIn: { enabled, iosBundleIds, updatedAt, updatedBy } }
```

The iPhone app uses the `StronglyAppAuth` Swift package (iOS 17+) with the
Server URL and App ID shown in the Native apps section of the app's Permissions tab. Over DDP it calls, all with the
appId: `appSignIn.app`, `appSignIn.signUp` (emails a 6-digit code),
`appSignIn.verifyEmail`, `appSignIn.sendCode` (`verify-email` | `reset-password`),
`appSignIn.resetPassword`, Meteor `login` with `{ appSignIn: { appId, email,
password: { digest, algorithm: "sha-256" }, device: { name, platform, bundleId,
installId } } }` (answers the login token; refuses platform accounts
`not-an-app-user`, another app's users `other-app-user`, unconfirmed
`email-not-verified`, waiting `account-inactive`; a `device` without its
`installId` is a 400). The session is that install's own (`installId`, made once
and kept in the Keychain): signing in never signs out the Strongly app, another
install or a browser, and signing in again on the install replaces only its
earlier session; it is exempt from the browser 60-minute idle timeout and
5-session limit, and signs out after 30 days without use (renewed on each use),
on `logout`, a password reset, or deactivation/archive. The branded web pages
send no `device`: a browser session.
`logout`, `appSignIn.sessions`, `appSignIn.endSession`,
`appSignIn.signOutEverywhere`, `appSignIn.deleteAccount` (password confirmed;
the platform's account deletion, required by the App Store). Codes are
single-use, last 10 minutes, take 5 guesses; wrong passwords and codes lock the
address out of the app for 15 minutes. Signed in, `apps.getProxyUrl` gives the
app's proxy URL, opened with the `meteor_login_token` cookie (with an apps
domain it is the app's address, and the native SDK's `openApp()` signs the
session in there through the app's sign-in handoff; the app gets the
user as from the web, `X-Strongly-User-Token`); direct REST calls send the
token as `X-Strongly-Login-Token` and reach only `GET /me` and `DELETE /me`
(every other route 403 `app-user-restricted`; call the app's own API through
the proxy instead). Sessions follow the platform's rules (5 per user, 60 minutes idle).
Chat with the user's agent from the phone as a stream, never a plain request:
the app relays the platform's run SSE (`POST /agents/:agentId/threads/:id/runs`
with `Accept: text/event-stream`) unchanged and the phone reads it with
`AppProxySession.events(path, body:)`. A user's on-demand clone wakes when they
sign in (or open the app), so it is usually warm by their first question; a
message to one still asleep wakes its pod: `thread.run.waiting_for_pod` arrives
at once (show "waking"), then `pod_ready`, `message.delta`, `completed`; no
request timeout applies.
Face ID sign-in: after an email sign-in, `enableBiometricSignIn(reason:)` asks
once and keeps the login token only in the Keychain under `.biometryCurrentSet`
(`WhenPasscodeSetThisDeviceOnly`, never synced, unreadable once enrolment
changes); at launch `signInWithBiometrics(reason:)` reads it after Face ID and
resumes it with Meteor `login`; `disableBiometricSignIn()` turns it off; sign
out and account deletion remove it. `BiometricSignInError` names the case
(`cancelled`, `failed`, `lockedOut`, `invalidated`, `sessionEnded`, ...); the
app then shows its email sign-in. The app needs `NSFaceIDUsageDescription`.

### Remote MCP for the app's users (Claude, ChatGPT)

An app can offer its own MCP server to its users' AI clients: each user adds
the server URL to Claude (Settings, Connectors, Add custom connector) or
ChatGPT (connectors), signs in on the app's branded page, approves the client
on a consent page that lists the scopes, and the client then sees only that
user's data. The platform runs the OAuth 2.1 server (PKCE S256, DCR and Client
ID Metadata Documents, rotating refresh tokens) and checks every request at
`<platform>/mcp/apps/<appId>` before forwarding it to the app's MCP path.
Needs branded sign-in; only the owner or a platform admin changes it.

```bash
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/remote-mcp" \
  -d '{ "enabled": true, "path": "/mcp",
        "scopes": [{ "name": "records:read", "description": "Read your records" }],
        "redirectHosts": ["claude.ai", "chatgpt.com"], "loopbackRedirects": false }'
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/remote-mcp"        # { appId, remoteMcp, serverUrl, issuer, jwksUrl }
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/mcp-connections"   # every user's connections (paged)
curl -s -X DELETE "${auth[@]}" "$BASE/apps/$APP_ID/mcp-connections/$CONNECTION_ID"   # disconnect at once
```

The app's MCP endpoint (Streamable HTTP; stateless JSON mode of the official
SDKs works) receives only checked requests, with the user as
`X-Strongly-User-Token` and the access token as `X-Strongly-Mcp-Token`: an
ES256 JWT (`typ at+jwt`; `iss` = `<platform>/oauth/apps/<appId>`, `aud` =
the server URL, `sub` = user id, `client_id`, `scope`). Verify it with
`<platform>/oauth/jwks` (the app gets the issuer and audience as
`STRONGLY_MCP_ISSUER` and `STRONGLY_MCP_SERVER_URL`),
enforce the scopes in every tool, read only `sub`'s data, never take a user id
as a tool argument. The app shows a user their own connections with
`GET /me/mcp-connections` and `DELETE /me/mcp-connections/:id` (called with the
user's token, only that app's). Turning it off disconnects everyone; every
authorization, token, refresh, revocation and tool call is audited.

**Sign-out inside a home app.** A home app fills the screen with no platform
chrome, so the app links its own sign-out: `<a href="_strongly/sign-out"
target="_top">Sign out</a>` (relative to the app's root; `target="_top"` so the
whole page navigates, not the frame). It ends the session, clears the cookie and
lands on the app's branded sign-in page. From script: `POST` the same address,
then set `window.top.location.href` to the `redirect` it answers. The page
`auth.pages.signOut` does the same from a plain link.

---

### Public apps (anyone on the internet, no sign-in)

A public app (a marketing site with a waitlist form) is served to anyone without
signing in on the platform's apps domain, never the dashboard's origin:
`https://<slug>.<apps domain>/api/proxy/<app id>/` (`url` from the GET; never build it).
`slug` is the app's one slug, shared with branded sign-in: an app is public OR
signs people in. It is served at the same `/api/proxy/<app id>/` path on its own
host as everywhere (the host's root sends a browser there), as an
ordinary website: its own cookies (made host-only), `localStorage` and service
workers work. A caller with a credential is served as anyone. A platform
without an apps domain answers `404 public-apps-disabled`.

Requests carry NO identity (no `X-Strongly-User-Token`); while it is a public
site its pods have NO Strongly API access (the API refuses its token) and it
uses only its granted add-ons, data sources and models: a waitlist form writes
to the app's own database add-on from the app's server route. Only the owner or
an admin may turn it on, and only after the user acknowledges the risk
(`riskAcknowledged: true`): quote `risk` from the GET and wait for their yes.

```bash
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/public-access"     # status off|preparing|live, slug, url, host, pathUrls, risk, conflicts
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/public-access" \
  -d '{ "enabled": true, "riskAcknowledged": true, "slug": "myzoe-site" }'
# poll until "status": "live" (its pods restart once without platform access)
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/public-access" -d '{ "enabled": false }'
```

- A whole-app site can not have branded/native sign-in, Home App, paid access,
  workflows, feature stores or agents. A product with a signed-in area is TWO
  apps: the public site, and a branded sign-in app it links to.
- `paths: ["/oauth", "/webhooks"]` makes only those prefixes of a signed-in app
  public, at `https://<slug>.<apps domain>/api/proxy/<app id>/<path>` (`pathUrls`): OAuth
  callbacks, webhooks, an MCP server. The caller's own `Authorization` reaches
  the app; Strongly credentials are refused. Register `pathUrls` with the other
  service; never a dashboard address.
- Edge: its own load balancer with per-IP rate limits (anonymous form posts
  tighter: 429), body limit `maxRequestBytes` (413), HTTPS only.

#### Custom domains (the owner's own domain, certificate automatic or uploaded)

Any app on a platform with an apps domain, public or signed-in (a signed-in app
signs its users in through Strongly there too).

```bash
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/apps/$APP_ID/domains" -d '{ "hostname": "www.example.com" }'
# answers dnsRecords: tell the user to set them exactly:
#   routing:     CNAME www.example.com -> <slug>.<apps domain>   (apex: true = root domain: ALIAS/ANAME/flattened CNAME)
#   ownership:   TXT _strongly-verify.www.example.com "strongly-verify=<token>"  (required for a root domain or a provider that hides the CNAME)
#   certificate: CNAME _<hash>.www.example.com -> _<hash>.acm-validations.aws  (automatic certificate; keep it, it renews with it)
curl -s "${auth[@]}" "$BASE/apps/$APP_ID/domains"                       # status pending|active|failed, dns, certificate, lastCheckError
curl -s -X POST "${auth[@]}" "$BASE/apps/$APP_ID/domains/$DOMAIN_ID/refresh"   # check now (a failed certificate is requested again)
curl -s -X DELETE "${auth[@]}" "$BASE/apps/$APP_ID/domains/$DOMAIN_ID"
```

- Served (`active`) once DNS shows the hostname is this app's (its CNAME names
  the app's address, or its TXT ownership record carries its token: reaching the
  shared load balancer alone is `dns.status: unverified`) and the certificate is issued: usually minutes (DNS up to 48 hours). The platform
  checks every minute until then, hourly after.
- `lastCheckError` names the problem: a CNAME pointing elsewhere, a record not
  in DNS yet, CAA records that do not allow `amazon.com`, a missing validation
  record (renewal would fail).
- Own certificate: `POST /apps/:id/certificates` `{certificate, privateKey, chain,
  domainIds}` (PEM; checked: key matches, chain reaches a trusted root, valid now,
  covers each domain; the key goes to AWS Certificate Manager only).
  `PUT /apps/:appId/certificates/:id` replaces it in place (renewal, no gap);
  `PATCH /apps/:appId/domains/:id {"certificate": {"source": "issued"}}` or
  `{"source": "uploaded", "certificateId"}` switches. Never ask a user to paste
  a private key into a chat: they upload it in the Domains section or by API.

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
`X-Strongly-Org-Id`); the JWT is canonical. The user claim carries two roles,
never interchangeable: **`appRole`**, the user's role IN THIS APP (`owner`,
`admin`, `user`, `viewer`): gate the app's features on it; and **`role`**, their
PLATFORM role (`admin`, `developer`, `app`), which only the platform reads. An
app admin who signed up through the branded page is `role: "app"`,
`appRole: "admin"`. Never use `role` for the app's own permissions.

---

### An agent for each user (per-user-agent apps)

Build the agent once as a normal agent (the BASE, an agent the app's OWNER
owns). The app makes each user's own **clone** of it itself, when the user first
needs it (the platform makes none on sign-up or binding): owned by the user,
recording the app (`appId`) and its base (`baseAgentId`). Clones and their rules
are the agents reference's "Agent clones"; what is app-specific:

The app's **backend** calls `$STRONGLY_API_URL/api/v1` forwarding the request's
`X-Strongly-User-Token` **unchanged** (never decoded and re-signed, never
stored: it expires in an hour). The pod's auth-proxy adds the app owner's bearer
token; on the user's areas (`/agents`, `/primitives`, `/library`) the call acts
as the signed-in user, through the app:

- `POST /agents/:id/clone` (the base: one of the app owner's own agents, or one
  shared with the user to clone) makes the user's clone when they have none
  (409 names an existing one). `POST /agents` with Agent Builder input
  makes an agent of the app's own design for the user instead.
- `GET /agents` lists only that user's agents of this app; another user's agent
  answers 404. Then `POST /agents/:id/start`, `POST /agents/:id/threads`,
  `POST /agents/:agentId/threads/:id/runs` (SSE), `DELETE /agents/:id`.
- `POST /library/knowledge-bases` + `.../:id/documents` make and fill the user's
  own knowledge base, private to their clone.
- An app's clone uses the models, tool workflows, workspace and MCP servers an
  app user cannot hold as the app's OWNER; the base's data sources and add-ons
  as its user. It may do what the base's allowlist grants, NEVER adding data
  sources or add-ons. The app's own request for the user (no clone calling) and
  an agent of the app's own design are granted no feature. Gateway calls record user + clone + app.
- App users reach their agents ONLY this way, through their Home App; the
  dashboard stays closed to them. With their own sign-in an app user sees only
  their app cards (name and icon), opens an app full screen, and changes their
  own password and MFA; every other method, publication and REST route answers
  them 403 `app-user-restricted`. Developers and admins through an app are held
  to the same rule.
- Deleted with its tasks and per-user layer when the app deletes it, the user
  is removed/unbound from the app or archived, or the app is deleted (the base
  stays).
- A user token that does not verify is refused (401 with why), never run as
  the owner. A user token alone (no bearer) is not a credential.

Python SDK: `client.for_user(token).agents.clone(base_agent_id)`, `client.agents.clones(id)`,
`client.agents.sync(id)`, `client.agents.set_allowed_features(id, [...])`.
User guide: Agent Clones (agents/agent-clones).

## 4. Wiring: `STRONGLY_SERVICES`

**Volumes are not services:** an app reads a volume's files directly. Pass
`volumes: ["<volume id>", ...]` on create (`POST /apps`) or update (`PATCH /apps/:id`:
a running app rolls out with them at once); each must be one the app's owner may
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
`/data-sources`, `/ai-gateway/models`, `/workflows`). How you pass them depends on the route:
- JSON `POST $BASE/apps` and `PATCH $BASE/apps/:id`: send them as top-level body
  fields, e.g. `{"addons":["<id>"]}`. On `PATCH` each array REPLACES the connected set.
- Multipart `POST $BASE/apps/import` (zip bundle): they are NOT standalone form
  fields; put them in the `metadata` JSON string, e.g. `metadata={"addons":["<id>"]}`.

`STRONGLY_SERVICES` is built from the connected set at every rollout. Changing the
set (or the volumes, the environment variables or the autoscaling) with
`PATCH /apps/:id` rolls a running app out at once with no downtime; a stopped app
gets it when it starts. Declaring ids up front, at create or upload, is the
one-shot path.

**Autoscaling:** `autoscaling` on `POST /apps` or `PATCH /apps/:id` is the whole
block `{ "enabled": true, "minReplicas": 1-20, "maxReplicas": 1-50 (more than
minReplicas), "cpuThreshold": 1-100, "memoryThreshold": 1-100 (percent of the
app's size), "scaleUpCooldown": 30-600, "scaleDownCooldown": 60-900 (seconds) }`;
`"autoscaling": null` turns it off (the app runs `instances`). Kubernetes reads
the CPU and memory use itself: there is no polling interval.

---

## 5. Artifacts (the Library API)

An **artifact** is a file the app produces for the user (report, export, PDF/HTML,
document). Store it in the platform Library (S3-backed, encrypted, up to 100 MB)
instead of the app's ephemeral disk, then hand the user a **signed download link**
(`POST /library/artifacts/:id/download`) so the download goes browser → S3, not
streamed back through the app and proxy. The platform issues the link only to a
caller who may read the artifact, records it in the audit log, and the link works
for **5 minutes**, saved as the artifact's title (`attachment`, never cached).
Anyone holding the link can use it until it expires: mint it per request, for the
signed-in user, never cache or share it.

The app calls the platform API for this. **Inside Strongly the bearer is
auto-injected** (see `SKILL.md`), the app doesn't manage a key; it calls
`$STRONGLY_API_URL/api/v1/...` and auth is handled. (Outside Strongly, an
`X-API-Key` is used.)

```bash
# Save: POST $BASE/library/artifacts  (artifacts:write)
curl -s -X POST "$STRONGLY_API_URL/api/v1/library/artifacts" -H 'Content-Type: application/json' \
  -d '{"title":"Q3 report","artifact_type":"report","contentType":"application/pdf",
       "encoding":"base64","content":"'"$(base64 -i report.pdf)"'"}'   # -> data._id

# Serve: POST $BASE/library/artifacts/:id/download  (artifacts:read)
#   -> {url, expiresAt, expiresInSeconds: 300, fileName, sizeBytes}
```

Serving pattern behind the proxy: the app's own endpoint (which knows the user
from §3) issues a download link and **302-redirects** the browser to it, the heavy
bytes go browser → S3 directly, only a small redirect passes through the app.

```js
app.get('/download/:id', async (req, res) => {
  if (!req.user) return res.status(401).end();
  const r = await fetch(`${process.env.STRONGLY_API_URL}/api/v1/library/artifacts/${req.params.id}/download`,
    { method: 'POST' });                          // bearer auto-injected in-cluster
  res.redirect(302, (await r.json()).data.url);
});
```

Also: `GET /library/artifacts` (gallery), `/library/artifacts/:id/versions` + `…/versions/:version/restore`,
`PATCH`/`DELETE`, and sharing through `/library/artifacts/:id/permissions` (members and visibility).

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
