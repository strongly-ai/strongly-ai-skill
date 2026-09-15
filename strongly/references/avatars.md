# Avatars

A Strongly **avatar** is a rendered digital presenter you create once and then
drive from your own app or workflow: a lightweight browser figure, an animated
portrait, or a real-time lip-synced face. You create it, upload its source, wait
for it to become **ready**, then preview and use it.

Read this when the task is: creating an avatar, choosing its **tier** and render
style, uploading the source asset that drives the render, tracking an avatar
through its statuses before using it, previewing it, or listing/updating/deleting
one.

**Auth** follows `SKILL.md`: inside Strongly the base is `$STRONGLY_API_URL/api/v1`
and the bearer is auto-injected; outside Strongly it is `$HOST/api/v1` with an
`X-API-Key` header. Below, `$BASE` is whichever applies, and the key needs
`avatars:read` to view and `avatars:write` to change anything.

```bash
# Outside Strongly: set once. (Inside Strongly, skip the header entirely.)
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")   # key needs avatars:read / avatars:write
```

Every response is the standard envelope: `{ "success": true, "data": … }` on
success, `{ "success": false, "error": { code, message } }` on failure.

---

## 1. Pick a tier and render style first  ← this decides the whole flow

An avatar's `tier` is fixed at create time and picks the render pipeline. It is
the single most important choice because it decides whether you upload a source
asset and how long the avatar takes to become usable.

| `tier` | What it is | Source asset you upload | Render style |
|---|---|---|---|
| `stylized_3d` | A lightweight figure rendered in the browser | A `.vrm` / glTF **model** (VRM style only) | `vrm` (default) or `orb` |
| `animated_portrait` | An animated portrait | A **portrait image** | (fixed) |
| `realtime_lipsync` | A real-time lip-synced face | A **portrait image** | (fixed) |

For `stylized_3d` you also choose a **`renderStyle`**:

- **`vrm`** (the default): renders from a 3D model you upload. Not usable until
  you upload that model.
- **`orb`**: a stylized sphere generated from a colour (`orbColor`, e.g.
  `#22d3ee`) and a size (`orbSize`, default `0.6`). No upload, no wait: an orb is
  `ready` the moment you create it.

`renderStyle`, `orbColor`, and `orbSize` apply to `stylized_3d` only; they are
ignored for the other tiers.

---

## 2. Statuses and the lifecycle  ← poll before you use it

An avatar moves through a small set of statuses. Read `status` on the avatar
(`GET /avatars/:id`) and do not preview or use it until it reaches `ready`.

- **`preprocessing`**, created, waiting for its source asset. (Every avatar
  starts here **except** an `orb`.)
- **`creating`**, an `animated_portrait` / `realtime_lipsync` avatar has its
  portrait and is being prepared for rendering. Keep polling.
- **`ready`**, usable: preview and drive it.

The transitions:

- `stylized_3d` + `orb` → **`ready`** immediately on create.
- `stylized_3d` + `vrm` → `preprocessing`, then **`ready`** once you upload the
  model.
- `animated_portrait` / `realtime_lipsync` → `preprocessing`, then `creating`
  once you upload the portrait, then **`ready`** once preparation finishes (poll).

```bash
# Poll until ready before previewing / using a portrait avatar
until [ "$(curl -s "${auth[@]}" "$BASE/avatars/$ID" | jq -r '.data.status')" = ready ]; do sleep 5; done
```

---

## 3. Create an avatar

`POST /avatars` (`avatars:write`). Required: `name`, `tier`. Everything else is
optional with sensible per-tier defaults.

```bash
# Tier 1, orb: no upload, ready immediately
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/avatars" -d '{
  "name": "Guide Orb", "tier": "stylized_3d",
  "renderStyle": "orb", "orbColor": "#22d3ee", "orbSize": 0.6
}' | jq '.data | {_id, status}'          # -> status "ready"

# Tier 1, VRM model: lands in preprocessing until you upload the model (§4)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/avatars" -d '{
  "name": "Reception 3D", "tier": "stylized_3d", "renderStyle": "vrm"
}' | jq '.data._id'

# Tier 3, real-time lip-sync: preprocessing until you upload a portrait (§4)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' "$BASE/avatars" -d '{
  "name": "Support Face", "tier": "realtime_lipsync",
  "onDemand": { "schedulingMode": "on_demand", "autoShutdownMinutes": 5 }
}' | jq '.data._id'
```

Optional fields:

| Field | Applies to | Meaning / default |
|---|---|---|
| `description` | all | Free text (default empty). |
| `renderStyle` | `stylized_3d` | `vrm` (default) or `orb`. |
| `orbColor` | `stylized_3d` orb | Hex colour (default `#22d3ee`). |
| `orbSize` | `stylized_3d` orb | Number (default `0.6`). |
| `config` | all | `{ resolution?, frameRate?, idleMotion? }` (defaults `512x512`, `30`, idle motion on). |
| `resources` | all | Compute overrides `{ cpu?, memory?, gpu?, gpuType? }`; omit to accept the per-tier defaults. |
| `onDemand` | `animated_portrait`, `realtime_lipsync` | `{ schedulingMode: on_demand \| always_on, autoShutdownMinutes }`. Defaults to `on_demand` with a 5-minute idle shutdown; set `always_on` to keep it warm. |

The response `data` is the created avatar, including its `_id` and initial
`status`.

---

## 4. Upload the source asset

Every avatar except an orb needs a source asset before it can render. Send it as
**`multipart/form-data`** with the file in the field named **`file`**:
`POST /avatars/:id/source` (`avatars:write`).

- `stylized_3d` (`vrm`): upload a `.vrm` / glTF **model**. On success the avatar
  goes to **`ready`**.
- `animated_portrait` / `realtime_lipsync`: upload a **portrait image**. The
  avatar goes to **`creating`**; poll `GET /avatars/:id` until `ready` (§2).

```bash
# Tier 1 VRM model
curl -s -X POST "${auth[@]}" -F "file=@presenter.vrm" "$BASE/avatars/$ID/source" | jq '.data'

# Tier 2/3 portrait image
curl -s -X POST "${auth[@]}" -F "file=@face.png" "$BASE/avatars/$ID/source" | jq '.data'
```

The response reports where the asset landed:

```json
{ "url": "https://…/presenter.vrm", "field": "sourceModel", "size": 184320 }
```

`field` is `sourceModel` for a `stylized_3d` model and `sourceImage` for a
portrait; `url` is the address the renderer fetches the source from. Uploading
again replaces the source.

---

## 5. Preview

`POST /avatars/:id/preview` (`avatars:write`) returns a way to see the avatar.
What comes back depends on the tier:

```bash
curl -s -X POST "${auth[@]}" "$BASE/avatars/$ID/preview" | jq '.data'
```

- `stylized_3d` **orb**: returns the orb parameters (`orbColor`, `orbSize`);
  there is no image URL because the orb is drawn in the browser (`previewUrl` is
  `null`).
- `stylized_3d` **vrm**: returns the model URL in `previewUrl`; render it
  client-side.
- `animated_portrait` / `realtime_lipsync`: renders a short clip and returns a
  `previewUrl`. The avatar must be **`ready`** first; if it is not deployed yet
  the call returns `503 service-unavailable`, so finish §2 before previewing.

---

## 6. List, get, update, delete

```bash
# List everything you can access (newest first). Optional exact-name filter.
curl -s "${auth[@]}" "$BASE/avatars"                 | jq '.data | {count, names: [.avatars[].name]}'
curl -s "${auth[@]}" "$BASE/avatars?name=Guide%20Orb" | jq '.data.avatars[0]._id'

# Get one
curl -s "${auth[@]}" "$BASE/avatars/$ID" | jq '.data | {name, tier, status}'

# Update: only these fields are mutable
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' "$BASE/avatars/$ID" -d '{
  "name": "Guide Orb v2", "description": "Homepage greeter",
  "config": { "frameRate": 24 }, "orbColor": "#34d399"
}' | jq '.data'

# Delete (also releases the avatar's rendering resources and stored source)
curl -s -X DELETE "${auth[@]}" "$BASE/avatars/$ID"
```

`?name=` is an **exact** match (whitespace-only is ignored and returns the full
list). Update accepts only `name`, `description`, `config`, `resources`,
`renderStyle`, `orbColor`, and `orbSize`; anything else is ignored, and you can
only update an avatar you own. Delete is final and enforces ownership.

---

## Endpoint reference

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/avatars` | List accessible avatars; optional `?name=<exact>` | `avatars:read` |
| GET | `/avatars/:id` | Get one avatar | `avatars:read` |
| POST | `/avatars` | Create an avatar (`name`, `tier` required) | `avatars:write` |
| PUT | `/avatars/:id` | Update mutable fields (owner only) | `avatars:write` |
| DELETE | `/avatars/:id` | Delete the avatar and release its resources (owner only) | `avatars:write` |
| POST | `/avatars/:id/source` | Upload the source asset (`multipart/form-data`, field `file`) | `avatars:write` |
| POST | `/avatars/:id/preview` | Preview: render handle (Tier 1) or a short clip (Tier 2/3) | `avatars:write` |

---

## Checklist
- [ ] Chose `tier` deliberately: `stylized_3d` (browser `vrm`/`orb`),
      `animated_portrait`, or `realtime_lipsync`. Tier is fixed at create time.
- [ ] For `stylized_3d`, set `renderStyle`: `orb` (colour + size, no upload,
      instantly ready) or `vrm` (upload a model).
- [ ] Uploaded the source asset via multipart field `file` for every avatar
      except an orb (VRM model for Tier 1, portrait image for Tier 2/3).
- [ ] Polled `GET /avatars/:id` until `status` is `ready` before previewing or
      using it (portrait avatars pass through `creating`).
- [ ] Previewed with the right expectation per tier (orb returns params, VRM
      returns a model URL, Tier 2/3 return a clip and require a ready avatar).
- [ ] Remembered update touches only the mutable fields, and both update and
      delete require that you own the avatar.
