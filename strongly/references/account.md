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
An app user (`role` `app`) holds no API keys: they use the platform only through
their app, and a user changed to `app` loses every key they held. An app user
sees only themselves in `GET /users`.
`GET /me` answers you: your `_id`,
`username`, `email` and `role`, your `organization` (`_id`, `role`,
`isMultiTenant`, `isSolo`: that is the org id used in sections 2 and 3), the
`apiKey` the call used (its `_id`, `name`, `keyPrefix`, `scopes`, `expiresAt`) and
`homeAppId` (an app user's Home App, else `null`). An app user's own credential
reaches only `GET /me`, `GET /me/app-cards`, `DELETE /me/app-sign-ins/:id` and
`DELETE /me`; everything else answers `403` `app-user-restricted`.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/me` | You: `_id`, `username`, `email`, `role`, `homeAppId`, `organization`, `apiKey` | (any key) |
| GET | `/me/app-cards` | The apps you may open, as cards, your Home App first: `_id`, `name`, `displayName`, `thumbnail` (icon data URL), `available` (opens now); nothing else of an app (`limit`, `cursor`) | (any key) |
| PATCH | `/me` | Update your own profile (`name`) | `users:write` |
| DELETE | `/me` | Delete your own account: revokes your API keys and login tokens, schedules data erasure; the account is archived with its memberships | `users:write` |
| POST | `/me/api-keys` | Create one of your API keys (`name`, `scopes`, `expiresInDays?`); the secret is shown once | (any key) |
| GET | `/me/api-keys` | Your API keys, never their secrets (`status`: `active`, `revoked`, `expired`) | (any key) |
| POST | `/me/api-keys/:id/revoke` | Revoke one: it stops working at once and stays listed as `revoked`; 409 if already revoked | (any key) |
| DELETE | `/me/api-keys/:id` | Delete one that no longer works (revoked or expired); 409 for a key that still works (revoke it first) | (any key) |
| POST | `/me/api-keys/:id/rotate` | Rotate one: a new key with the same name, scopes and expiry; the old one is revoked | (any key) |
| GET | `/me/app-sign-ins` | The apps signed in as you: each install of the Strongly iPhone app and of a connected app (`_id` = the install, `clientId`, `appId`, `appName`, `deviceName`, `platform`, `signedInAt`, `lastUsedAt`, `expiresAt`); each install has its own credential, so signing in on one never signs out another; browsers are not listed (`limit`, `cursor`) | (any key) |
| DELETE | `/me/app-sign-ins/:id` | Sign one install out: its key and sessions stop working at once, nothing else; 404 for an install with nothing signed in | (any key) |
| GET | `/users` | List users visible within your organization, each `_id`, `username`, `email`, `role` (`q`, `active`, `limit`, `cursor`, `sort`); an archived user is never listed, and `GET /users/:id` answers `404` for one | `users:read` |
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
| POST | `/users/:id/archive` | Archive a user. Their resources are deleted or transferred, the only two choices: when they own anything one is required (neither is `400` `validation-error`), and only a user who owns nothing is archived with neither (`assetAction` `null`). Ask the admin which, and to whom; never choose for them. `transferTo` gives them to one of `GET /users/:id/assets` `transferRecipients` (`{userId, name, email, label}`, label "Name (email)": single-tenant any active admin or developer; multi-tenant any active developer of their organization, never an admin; anyone else is `400`): ownership, access and sharing move (the receiver leaves the share lists), the resources stay in their organization, and FinOps books their cost to the receiver from that moment, running workloads included with no redeploy, while earlier cost stays with the archived user. `deleteResources: true` (not with `transferTo`) deletes their resources under the calling administrator's authority, never as the user. Either way, or when they own nothing, every organization they leave with no active member is archived with them and its Kubernetes namespace removed (single-tenant their own organization; multi-tenant one whose other members are all gone), unless it still holds resources (transferred ones stay where they run); unarchiving the user, in the dashboard only, restores it. Resources include Library records and agent primitives (knowledge bases, pools/Imprints, skills, rules, prompts, memories, artifacts, tasks, preferences), governance solutions and policies, and their STAN sessions, conversations, memories, skills and artifacts, moved or deleted like the rest. Users are never deleted: their memberships (organization, app-user entries, team seats) are archived with them, so they count as no member or seat. Their budgets stop (scoped to them, or of an organization archived with them: `stopped.reason` `user-archived`) and their governance part stops (pending approval requests withdrawn; requests they were to review decided by the reviewers left, or sent to the platform admins); unarchiving restores both. `GET /users/:id/assets` counts them all | `users:admin` |
| POST | `/users/:id/reset-password` | Reset a user's password | `users:admin` |

There is no unarchive in the API (or STAN or the SDKs): an administrator unarchives a user by
hand in the dashboard (Add User or Invite with their email offers **Unarchive**; `POST /users`
and invitations refuse an archived user's email with `409`). Never offer to unarchive through
the API.

---

## 2. Organization, members, and invitations

Reading the organization and its members is self-serve for members
(`organizations:read`). Changing the organization, removing members, changing a
member's role, and inviting or cancelling invitations all require
`organizations:write` and are restricted to an org owner or admin.

Every account belongs to exactly one organization, so nobody is added to one by
id: a person joins an organization only by invitation, sent to an email address
with no account yet, and signs up into it from the invitation.

Show an organization to a person by its `label`, `<owner> (<organization id>)`
(for example `Zack Hudson (org-zack-hudson-7ohe2kqcw)`), the format every
Strongly list uses. Names need not be unique. A person's own organization is
`<name>'s Organization`, from their account's name; a user's name and an
organization's name are never empty or an email address (`400`). An
organization is archived only when it holds nothing (`422 resource-in-use`
otherwise): transfer or delete its resources first. An archived organization is never
listed (`status` takes `active` or `suspended`) and `GET`/`PATCH /organizations/:id`
answer `404` for it, so the API never brings one back.

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

Credits exist only when billing is enabled (otherwise `409 billing-disabled`).
They are held at the organization level and read by the organization's owner
and platform admins (`organizations:read`). Amounts are whole credits
(their dollar price is the platform's plan catalog: a purchase answers its
`chargeCents`), and every amount field's name ends in `Credits`.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/organizations/:id/credits` | `balanceCredits` = `planCreditsBalance` + `grantCreditsBalance` + `additionalCreditsBalance`; `planMonths` (this month's plan credits: `issuedCredits`, `usedCredits`, `remainingCredits`, `expiresAt`), `nextPlanMonth` (`amountCredits`), `grantPeriods`, `overdraftCredits` (what is owed), `lifetimeAddedCredits`, `lifetimeUsedCredits`, `autoPurchase`; on Strongly Cloud `allowance` (`allowanceCredits`, `usedCredits`, `remainingCredits`, `renewsAt`, `lots`) | `organizations:read` |
| POST | `/organizations/:id/credit-purchases` | Buy additional credits: `{ "credits": <a whole number, at least the minimum purchase> }`; returns `amountCredits`, `chargeCents` (what Stripe charges, US cents: 1,000 credits cost $10.00) and a Stripe Checkout `url` to pay at. Strongly Cloud: `paymentMethod` `checkout` (default) or `saved-card` (charged now; returns `purchaseId`, `amountCredits`, `chargeCents`, `status`, `expiresAt`; send an `Idempotency-Key` header so a retry charges once) | `organizations:write` |
| GET | `/organizations/:id/credit-purchases` | Strongly Cloud: unexpired purchases (bought or auto-refilled), soonest-expiring first: `purchasedAt`, `expiresAt`, `issuedCredits`, `usedCredits`, `remainingCredits` (`limit`, `cursor`) | `organizations:read` |
| GET | `/organizations/:id/credit-settings` | Strongly Cloud: `lowBalanceAlert` (`enabled`, `thresholdPercent`, `thresholdCredits`), `autoRefill` (`enabled`, `thresholdPercent`, `thresholdCredits`, `amountCredits`, `maxPerDay`, `refillsToday`, `disabledReason` `payment_failed`), `baseCredits` (the plan's monthly credits) | `organizations:read` |
| PATCH | `/organizations/:id/credit-settings` | Strongly Cloud: change only the fields given: `lowBalanceAlert {enabled, thresholdPercent 1-100}`, `autoRefill {enabled, thresholdPercent 1-100, amountCredits (a whole number, at least 1000), maxPerDay 1-10}` (owner/admin) | `organizations:write` |
| GET | `/organizations/:id/transactions` | Credit transaction history (`type`, `q`, `sort` one of `createdAt`, `type`, `description`, `amountCredits`, `balanceAfterCredits`; `limit`, `cursor`); each has `amountCredits`, `balanceBeforeCredits`, `balanceAfterCredits` | `organizations:read` |
| GET | `/organizations/:id/credit-grants` | The org's credit grants, each with per-month issued/used/expired/remaining | `organizations:read` |
| GET | `/organizations/:organizationId/credit-grants/:id` | One credit grant | `organizations:read` |
| POST | `/organizations/:id/credit-grants` | Platform admin: create a grant (`label`, `amountCredits`, `startsAt` UTC midnight, `periodCount` (months) or `endsAt`) | `organizations:write` |
| PATCH | `/organizations/:organizationId/credit-grants/:id` | Platform admin: change the months to come: `label`, `amountCredits`, `startsAt`, `periodCount` (merge patch) | `organizations:write` |
| POST | `/organizations/:organizationId/credit-grants/:id/end` | Platform admin: stop after the current month | `organizations:write` |
| GET | `/organizations/:id/credit-resets` | Strongly Cloud: the org's allowance resets, newest first (`note`, `expiresAt`, `status` one of `available`, `applying`, `applied`, `expired`, `revoked`; once applied `restoredCredits` and `overdraftPaidCredits`); owner, org admins and platform admins | `organizations:read` |
| POST | `/organizations/:id/credit-resets` | Platform admin: issue a reset (`note`, `expiresAt` ISO 8601 in the future) | `organizations:write` |
| POST | `/organizations/:organizationId/credit-resets/:id/apply` | Owner or org admin: refill this month's allowance to its full amount, once; `overdraftPaidCredits` of `restoredCredits` paid an overdrawn balance first | `organizations:write` |
| POST | `/organizations/:organizationId/credit-resets/:id/revoke` | Platform admin: revoke a reset not yet applied | `organizations:write` |

```bash
curl -s "${auth[@]}" "$BASE/organizations/$ORG_ID/credits" | jq '.data'
curl -s "${auth[@]}" "$BASE/organizations/$ORG_ID/transactions?limit=50" | jq '.data'

# Platform admin: 50,000 credits ($500) a month for 12 months from 1 November (unused credit expires each month)
curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
  -d '{"label":"Partner deal, year 1","amountCredits":50000,"startsAt":"2026-11-01T00:00:00Z","periodCount":12}' \
  "$BASE/organizations/$ORG_ID/credit-grants" | jq '.data'
```

How credits work (the user guide's "How Credits Work" page says the same):

- Your plan's credits are added at the start of each month and expire at the end of that month. An annual plan adds each month's credits at the start of that month too (`subscription_credit`, `subscription_credit_expiry`).
- On Strongly Cloud purchased credits expire 12 months after their purchase, each purchase on its own (`credit_purchase`, `auto_purchase`; an expired purchase is `credit_purchase_expiry`); credit a platform admin adds (`admin_allocation`) never expires. All of it is forfeited with the rest of your credits when your subscription ends. You can buy any whole number of credits from the platform's minimum purchase; the purchase answer's `chargeCents` is what it costs.
- A credit grant adds a set amount of credit every month for a number of months. Each month's grant credit expires at the end of that month; it never rolls over (`grant_credit`, `grant_expiry`). Started months never change; a `PATCH` applies to the months to come.
- Plan and grant credit is used first, the soonest-expiring first. Additional credits are used only after it runs out.
- Usage is always charged in full. If it takes your balance below zero, the next credit that arrives (plan, grant or additional) pays off what you owe first (`overdraft_payoff`, `reference.paidCredits`).
- When your balance is zero or below, new launches are refused and running workloads are stopped. Stopped resources are deleted 30 days later unless credit is added. Credit that makes the balance positive stops the deletion clock; you restart your workloads yourself.
- A move to a higher plan takes effect at once: the price difference for the rest of the billing period is charged then, and the higher plan's extra credits for the rest of this month are added, expiring with the month (`upgrade_credit`; in `planMonths`, `upgradeCredits` of the month's `issuedCredits`). A move to a lower plan takes effect at your next renewal. A cancel takes effect at the end of the period you have paid for.
- When your subscription ends, every credit you still have (plan, grant and additional) is forfeited. Usage up to the end is paid from it first (`credit_forfeiture`: `reference.planCredits`, `grantCredits`, `additionalCredits`).
- No money is refunded: not when you cancel, not when you move to a lower plan, and not for unused plan, grant or additional credits.
- Usage is charged in credits; a usage charge carries what was charged, not how it was worked out. For what each resource cost, use FinOps.

On Strongly Cloud (the credit-settings and `GET` credit-purchases routes answer `404` elsewhere):

- Purchased credits expire 12 months after their purchase, each purchase on its own; an auto-refill is a purchase. Credit left at expiry is a `credit_purchase_expiry` transaction. They are forfeited with the rest of your credits when your subscription ends.
- Plan and grant credit is used first, the soonest-expiring first. Purchased credits are used only after it runs out, the soonest-expiring purchase first.
- The low-balance alert and auto-refill are both off by default. Thresholds are a percent of the plan's monthly credits (20% of a $50 month is $10.00).
- The alert notifies the owner and admins once per fall to the threshold (in the app always, by email if their email setting is on), again only after the balance is back above it; with it on they are also told 14 days before a purchase expires.
- Auto-refill charges the saved card `amountCredits` when the balance falls below its threshold, at most `maxPerDay` a day. A declined card, or one that needs authentication, credits nothing and turns auto-refill off (`disabledReason: payment_failed`; owner and admins notified) until it is turned on again. Refill history: `transactions?type=auto_purchase`.
- A saved-card purchase the bank wants confirmed answers `authentication-required` (402): use `checkout`. A declined card: `card-declined` (402). No saved card: `no-saved-card` (409).
- Confirm the amount with the user before buying credits or turning auto-refill on.
- Only the organization's owner or an admin buys or changes settings; other members get `403`.

---

## 4. Notifications and push device

Notifications belong to the signed-in user; every read and mutation is scoped to
you, and ownership is checked on the single-notification routes. Registering a
push device mutates your user record, so it needs a write scope.

| Method | Path | Purpose | Scope |
|---|---|---|---|
| GET | `/me/notifications` | List your notifications, newest first (`q` on title and message, `unreadOnly`, `limit`, `cursor`) | `notifications:read` |
| GET | `/me/notifications/unread-count` | Count of your unread notifications | `notifications:read` |
| GET | `/me/notifications/stats` | Every notification of yours counted: `{ total, unread, byType[{type, total, unread}] }` (not a page) | `notifications:read` |
| POST | `/me/notifications/mark-all-read` | Mark all your notifications read; answers `{ count }` | `notifications:write` |
| PATCH | `/me/notifications/:id` | `{ read }`: mark one of your notifications read or unread; answers the notification | `notifications:write` |
| DELETE | `/me/notifications/:id` | Delete one of your notifications (`204`) | `notifications:write` |
| POST | `/me/push-devices` | Register an APNs/device push token (`token`, optional `platform`, default `ios`); answers the device (`201`) | `notifications:write` |
| DELETE | `/me/push-devices/:id` | Unregister one of your devices by its push token (`204`) | `notifications:write` |

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

The platform registers the token with Strongly's push relay (the one service
holding the iPhone app's APNs key) and then keeps it on your user record, so
re-registering the same token is safe and just refreshes its timestamp. A
platform with no relay configured answers `503` naming the missing
`PUSH_RELAY_URL` / `PUSH_RELAY_KEY`; a relay that refuses answers `502`.

```bash
# Unregister a device (the id is its push token)
curl -s -X DELETE "${auth[@]}" "$BASE/me/push-devices/<apns-hex-token>" -o /dev/null -w '%{http_code}\n'
```

---

## Checklist
- [ ] Auth set per `SKILL.md` (outside Strongly: `X-API-Key`; inside: injected bearer), `$BASE` chosen to match.
- [ ] Read yourself with `GET /me` first; take `organization._id` from it for the org, credit, and transaction calls.
- [ ] Self-serve on your own record: `GET`/`PATCH` `/me`, and `DELETE /me` (irreversible, caller-only).
- [ ] Treat user create/update/archive/reset-password as `users:admin`, acting on other users only; unarchive is by hand in the dashboard only.
- [ ] Treat org update, member add/remove/role, and invite/cancel as `organizations:write` and org owner/admin.
- [ ] Credits, transactions and credit grants are read by the org's owner and platform admins; only platform admins create, change or end a grant. Allowance resets are read by the owner, org admins and platform admins, applied by the owner or an org admin, and issued or revoked only by platform admins.
- [ ] Notifications and their single-item routes are scoped to you; ownership is enforced on `:id` read/delete.
- [ ] Register a push device with `notifications:write`; the token is deduped, so re-registering is safe.
