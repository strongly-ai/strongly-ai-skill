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
# Inside Strongly (a workspace, app or job): BASE="$STRONGLY_API_URL/api/v1"; auth=()   # signed in as you, no key
```

Most of this is self-serve on your own record. Actions that manage other users,
or that change the organization and its members, need a higher scope and an
admin or org-owner role; those are called out below and never assumed.

---

## 1. Your account (current user)

The self-serve endpoints act only on the authenticated caller. `GET /users`
and `GET /users/:id` answer each user as exactly `_id`, `username`, `email` and
`role` (`admin`, `developer`, `app`, or `null`); `_id` is what `/users/:id` takes.
`GET /me` answers you: your `_id`,
`username`, `email` and `role`, your `organization` (`_id`, `role`,
`isMultiTenant`, `isSolo`: that is the org id used in sections 2 and 3) and the
`apiKey` the call used (its `_id`, `name`, `keyPrefix`, `scopes`, `expiresAt`).

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/me` | You: `_id`, `username`, `email`, `role`, `organization`, `apiKey` | (any key) |
| PATCH | `/me` | Update your own profile (`name`) | `users:write` |
| DELETE | `/me` | Delete your own account: revokes your API keys and login tokens, schedules data erasure | `users:write` |
| GET | `/users` | List users visible within your organization, each `_id`, `username`, `email`, `role` (`q`, `active`, `archived`, `limit`, `cursor`, `sort`) | `users:read` |
| GET | `/users/:id` | Another user in your organization: `_id`, `username`, `email`, `role` (visibility-filtered) | `users:read` |

```bash
# Capture your org id for later sections
ORG_ID=$(curl -s "${auth[@]}" "$BASE/me" | jq -r '.data.organization._id')

# Update your display name
curl -s -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Ada Lovelace"}' "$BASE/me" | jq '.data'
```

`DELETE /me` is irreversible and locks you out immediately; it only ever
targets the caller (there is no id or body), so it can never delete anyone else.

**Admin-only user management** (needs the `users:admin` scope and an admin role;
these act on *other* users, not yourself):

| Method | Path | Purpose | Scope |
|---|---|---|---|
| POST | `/users` | Create a user (`email`, `name`, `role`); answers the user as `GET /users/:id` does plus `temporaryPassword`, shown only here | `users:admin` |
| PATCH | `/users/:id` | Update another user | `users:admin` |
| GET | `/users/:id/assets` | Summarize resources a user owns (impact check before archiving) | `users:admin` |
| POST | `/users/:id/archive` | Archive a user, with `assetAction` (`transfer`, `transfer-to-admin`, `delete`, `leave-as-is`) and `transferToUserId`; `delete` deletes their resources under the calling administrator's authority, never as the user | `users:admin` |
| POST | `/users/:id/unarchive` | Reactivate an archived user | `users:admin` |
| POST | `/users/:id/reset-password` | Reset a user's password | `users:admin` |

---

## 2. Organization, members, and invitations

Reading the organization and its members is self-serve for members
(`organizations:read`). Changing the organization, removing members, changing a
member's role, and inviting or cancelling invitations all require
`organizations:write` and are restricted to an org owner or admin.

Every account belongs to exactly one organization, so nobody is added to one by
id: a person joins an organization only by invitation, sent to an email address
with no account yet, and signs up into it from the invitation.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/organizations` | List organizations you belong to (`status`, `limit`, `cursor`); platform admins receive all | `organizations:read` |
| GET | `/organizations/:id` | Get one organization | `organizations:read` |
| PATCH | `/organizations/:id` | Update the organization (owner/admin) | `organizations:write` |
| GET | `/organizations/:id/members` | List members, enriched with names and emails | `organizations:read` |
| PATCH | `/organizations/:organizationId/members/:id` | Change a member's `role` (owner/admin) | `organizations:write` |
| DELETE | `/organizations/:organizationId/members/:id` | Remove a member (owner/admin) | `organizations:write` |
| POST | `/organizations/:id/invitations` | Invite by `email` + `role` (owner/admin) | `organizations:write` |
| GET | `/organizations/:id/invitations` | List pending invitations | `organizations:read` |
| DELETE | `/organizations/:organizationId/invitations/:id` | Cancel a pending invitation (owner/admin) | `organizations:write` |

```bash
# Who is in my org
curl -s "${auth[@]}" "$BASE/organizations/$ORG_ID/members" | jq '.data'

# Invite a teammate (owner/admin)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"email":"teammate@example.com","role":"member"}' \
  "$BASE/organizations/$ORG_ID/invitations" | jq '.data'
```

Member ids and invitation ids come from the `members` and `invitations` list
responses; pass them as the last `:id`.

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
| GET | `/me/notifications` | List your notifications (`unreadOnly`, `limit`, `cursor`) | `notifications:read` |
| GET | `/me/notifications/unread-count` | Count of your unread notifications | `notifications:read` |
| POST | `/me/notifications/mark-all-read` | Mark all your notifications read; answers `{ count }` | `notifications:write` |
| PATCH | `/me/notifications/:id` | `{ read }`: mark one of your notifications read or unread; answers the notification | `notifications:write` |
| DELETE | `/me/notifications/:id` | Delete one of your notifications (`204`) | `notifications:write` |
| POST | `/me/push-devices` | Register an APNs/device push token (`token`, optional `platform`, default `ios`) | `notifications:write` |

```bash
# Unread inbox and count
curl -s "${auth[@]}" "$BASE/me/notifications?unreadOnly=true" | jq '.data'
curl -s "${auth[@]}" "$BASE/me/notifications/unread-count" | jq '.data.count'

# Mark all read, then clear one
curl -s -X POST "${auth[@]}" "$BASE/me/notifications/mark-all-read" | jq '.data.count'
curl -s -X DELETE "${auth[@]}" "$BASE/me/notifications/$NOTIF_ID" | jq '.data'

# Register a mobile push token (from the mobile app after the user grants push)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"token":"<apns-hex-token>","platform":"ios"}' \
  "$BASE/me/push-devices" | jq '.data'
```

The push token is deduped by value on your user record, so re-registering the
same token is safe and just refreshes its timestamp.

---

## Checklist
- [ ] Auth set per `SKILL.md` (outside Strongly: `X-API-Key`; inside: injected bearer), `$BASE` chosen to match.
- [ ] Read yourself with `GET /me` first; take `organization._id` from it for the org, credit, and transaction calls.
- [ ] Self-serve on your own record: `GET`/`PATCH` `/me`, and `DELETE /me` (irreversible, caller-only).
- [ ] Treat user create/update/archive/unarchive/reset-password as `users:admin`, acting on other users only.
- [ ] Treat org update, member add/remove/role, and invite/cancel as `organizations:write` and org owner/admin.
- [ ] Credits and transactions are read-only at the organization level and shared across members.
- [ ] Notifications and their single-item routes are scoped to you; ownership is enforced on `:id` read/delete.
- [ ] Register a push device with `notifications:write`; the token is deduped, so re-registering is safe.
