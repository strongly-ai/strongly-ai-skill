# Account

Your **account** is your identity on the platform (profile, roles), the
**organization** you belong to (its members, pending invitations, and shared
credit balance), and your **notification** inbox plus mobile push registration.
Everything here is reachable through the same `/api/v1` REST API as the rest of
the platform.

Read this when the task is: reading or updating the signed-in user's own
profile, deleting your own account, seeing who is in your organization, inviting
or removing teammates, checking the organization's credit balance and credit
transactions, or working with your notifications and registering a mobile push
device.

**Auth** follows the two-context rule in `SKILL.md`: outside Strongly you send
`X-API-Key` to `$HOST/api/v1`; inside Strongly the platform injects the bearer
and you set no auth header. Below, `$BASE` is whichever applies, and `auth` is
the header array for the outside-Strongly case:

```bash
BASE="$HOST/api/v1"; auth=(-H "X-API-Key: $STRONGLY_API_KEY")
```

Most of this is self-serve on your own record. Actions that manage other users,
or that change the organization and its members, need a higher scope and an
admin or org-owner role; those are called out below and never assumed.

---

## 1. Your account (current user)

The self-serve endpoints act only on the authenticated caller. `GET /users/me`
also returns your organization context (`organization.id`, `role`,
`isMultiTenant`, `isSolo`), which is where you read the org id used in section 2
and 3.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/users/me` | Your profile + organization context | `users:read` |
| PUT | `/users/me` | Update your own profile (`name`) | `users:write` |
| DELETE | `/users/me` | Delete your own account: revokes your API keys and login tokens, schedules data erasure | `users:write` |
| GET | `/users` | List users visible within your organization (`search`, `active`, `archived`, `limit`, `offset`, `sortBy`, `sortOrder`) | `users:read` |
| GET | `/users/:id` | Read another user in your organization (visibility-filtered) | `users:read` |

```bash
# Read yourself and capture the org id for later sections
ORG_ID=$(curl -s "${auth[@]}" "$BASE/users/me" | jq -r '.data.organization.id')

# Update your display name
curl -s -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Ada Lovelace"}' "$BASE/users/me" | jq '.data'
```

`DELETE /users/me` is irreversible and locks you out immediately; it only ever
targets the caller (there is no id or body), so it can never delete anyone else.

**Admin-only user management** (needs the `users:admin` scope and an admin role;
these act on *other* users, not yourself):

| Method | Path | Purpose | Scope |
|---|---|---|---|
| POST | `/users` | Create a user (`email`, `name`, `role`) | `users:admin` |
| PUT | `/users/:id` | Update another user | `users:admin` |
| GET | `/users/:id/assets` | Summarize resources a user owns (impact check before archiving) | `users:admin` |
| POST | `/users/:id/archive` | Archive a user, with `assetAction` (`transfer`, `transfer-to-admin`, `delete`, `leave-as-is`) and `transferToUserId` | `users:admin` |
| POST | `/users/:id/unarchive` | Reactivate an archived user | `users:admin` |
| POST | `/users/:id/reset-password` | Reset a user's password | `users:admin` |

---

## 2. Organization, members, and invitations

Reading the organization and its members is self-serve for members
(`organizations:read`). Changing the organization, adding or removing members,
changing a member's role, and inviting or cancelling invitations all require
`organizations:write` and are restricted to an org owner or admin.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/organizations` | List organizations you belong to (`status`, `limit`, `offset`); platform admins receive all | `organizations:read` |
| GET | `/organizations/:id` | Get one organization | `organizations:read` |
| PUT | `/organizations/:id` | Update the organization (owner/admin) | `organizations:write` |
| GET | `/organizations/:id/members` | List members, enriched with names and emails | `organizations:read` |
| POST | `/organizations/:id/members` | Add an existing user (`userId`, optional `role`, default `member`) (owner/admin) | `organizations:write` |
| PUT | `/organizations/:id/members/:subId` | Change a member's `role` (owner/admin) | `organizations:write` |
| DELETE | `/organizations/:id/members/:subId` | Remove a member (owner/admin) | `organizations:write` |
| POST | `/organizations/:id/invite` | Invite by `email` + `role` (owner/admin) | `organizations:write` |
| GET | `/organizations/:id/invitations` | List pending invitations | `organizations:read` |
| DELETE | `/organizations/:id/invitations/:subId` | Cancel a pending invitation (owner/admin) | `organizations:write` |

```bash
# Who is in my org
curl -s "${auth[@]}" "$BASE/organizations/$ORG_ID/members" | jq '.data'

# Invite a teammate (owner/admin)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"email":"teammate@example.com","role":"member"}' \
  "$BASE/organizations/$ORG_ID/invite" | jq '.data'
```

Member ids and invitation ids come from the `members` and `invitations` list
responses; pass them as `:subId`.

---

## 3. Credits and transactions

Credits are held at the organization level and shared across its members. Both
reads are self-serve for members (`organizations:read`).

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/organizations/:id/credits` | Current credit balance for the organization | `organizations:read` |
| GET | `/organizations/:id/transactions` | Credit transaction history (`limit`) | `organizations:read` |

```bash
curl -s "${auth[@]}" "$BASE/organizations/$ORG_ID/credits" | jq '.data'
curl -s "${auth[@]}" "$BASE/organizations/$ORG_ID/transactions?limit=50" | jq '.data'
```

---

## 4. Notifications and push device

Notifications belong to the signed-in user; every read and mutation is scoped to
you, and ownership is checked on the single-notification routes. Registering a
push device mutates your user record, so it needs a write scope.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/notifications` | List your notifications (`unreadOnly`, `limit`, `offset`) | `notifications:read` |
| GET | `/notifications/unread-count` | Count of your unread notifications | `notifications:read` |
| POST | `/notifications/read-all` | Mark all your notifications read | `notifications:read` |
| POST | `/notifications/:id/read` | Mark one notification read (yours only) | `notifications:read` |
| DELETE | `/notifications/:id` | Delete one notification (yours only) | `notifications:read` |
| POST | `/notifications/devices` | Register an APNs/device push token (`token`, optional `platform`, default `ios`) | `notifications:write` |

```bash
# Unread inbox and count
curl -s "${auth[@]}" "$BASE/notifications?unreadOnly=true" | jq '.data'
curl -s "${auth[@]}" "$BASE/notifications/unread-count" | jq '.data.count'

# Mark all read, then clear one
curl -s -X POST "${auth[@]}" "$BASE/notifications/read-all" | jq '.data'
curl -s -X DELETE "${auth[@]}" "$BASE/notifications/$NOTIF_ID" | jq '.data'

# Register a mobile push token (from the mobile app after the user grants push)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"token":"<apns-hex-token>","platform":"ios"}' \
  "$BASE/notifications/devices" | jq '.data'
```

The push token is deduped by value on your user record, so re-registering the
same token is safe and just refreshes its timestamp.

---

## Checklist
- [ ] Auth set per `SKILL.md` (outside Strongly: `X-API-Key`; inside: injected bearer), `$BASE` chosen to match.
- [ ] Read yourself with `GET /users/me` first; take `organization.id` from it for the org, credit, and transaction calls.
- [ ] Self-serve on your own record: `GET`/`PUT` `/users/me`, and `DELETE /users/me` (irreversible, caller-only).
- [ ] Treat user create/update/archive/unarchive/reset-password as `users:admin`, acting on other users only.
- [ ] Treat org update, member add/remove/role, and invite/cancel as `organizations:write` and org owner/admin.
- [ ] Credits and transactions are read-only at the organization level and shared across members.
- [ ] Notifications and their single-item routes are scoped to you; ownership is enforced on `:id` read/delete.
- [ ] Register a push device with `notifications:write`; the token is deduped, so re-registering is safe.
