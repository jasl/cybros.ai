# Human member password recovery

Nexus offers email password reset and deployment-local recovery for an active
human member. Neither procedure restores a suspended or removed member, changes
their role, or signs them in automatically. After setting a new password, the
member returns to `/session/new` and signs in with their current email address.

Passwords must contain at least 8 characters, fit within 72 bytes, and contain
no null byte. The confirmation must match. A rejected password does not consume
the recovery capability or change the stored password.

## Reset through email

1. Open `/passwords/new` on the Nexus installation and submit the member's email.
2. Open the reset link in the email. It leads to `/passwords/edit?token=…`.
3. Set and confirm the new password, then sign in.

Email reset requires configured outbound mail and a running job worker. For
SMTP deployments, configure `SMTP_ADDRESS` and the canonical `BASE_URL` along
with the other mail settings in the [deployment guide](../nexus/README.md).
Configuration readiness does not guarantee successful mail delivery.

The request response does not reveal whether the address exists or is eligible.
If outbound mail is unavailable, the page explains that email reset is
unavailable; use the local procedure below. An identity with pending local
recovery cannot request or consume an emailed reset link until that recovery
is completed.

A reset link is valid for 15 minutes from token generation. A successful reset
changes the password, clears any requirement to replace a temporary password,
and invalidates earlier browser/API Sessions and human access tokens. Existing
reset links become invalid too. Requesting another email alone does not revoke
previous links; they remain subject to their expiry and the identity's state.

## Recover from the deployment host

Use this procedure when email reset is unavailable. Choose the commands for
your deployment below; the address is a placeholder. `status` inspects the
current state without creating or revealing a secret. `mint` creates the
one-time recovery capability.

For the combined Docker stack, run from its installation directory:

```sh
./cybros compose exec nexus bin/rails 'member_recovery:status[member@example.com]'
./cybros compose exec nexus bin/rails 'member_recovery:mint[member@example.com]'
```

For a bare-metal Nexus, run from `nexus/` with the installation's usual database
and credentials configuration:

```bash
RAILS_ENV=production bin/rails 'member_recovery:status[member@example.com]'
RAILS_ENV=production bin/rails 'member_recovery:mint[member@example.com]'
```

For standalone Nexus Compose, run from `nexus/`; that deployment calls its
service `app`:

```bash
docker compose --env-file .env.docker exec app bin/rails 'member_recovery:status[member@example.com]'
docker compose --env-file .env.docker exec app bin/rails 'member_recovery:mint[member@example.com]'
```

Minting prints a one-time consume path and its expiry. The path contains the
secret and is shown only by that invocation; `status` cannot retrieve it. Open
the printed path on this installation and set the new password in the browser.
Treat the complete path as a credential and convey it privately to the member.
Opening the form does not consume it; successfully submitting the new password
does. There is no remote mint endpoint or command that clears the pending fence
without completing recovery.

Minting immediately advances the identity's recovery generation and sets a
pending recovery fence. Existing browser/API Sessions and the human member's
access tokens stop authenticating, and password sign-in is blocked while the
fence remains. Agent and executor credentials have their own lifecycle; this
procedure is not a shutdown command for those separately registered resources.

The capability expires after 15 minutes and can succeed only once. Minting again
supersedes the earlier capability and starts a new generation. If the path is
lost or expires, mint another one. Expiry and eventual cleanup of its stored
record do **not** clear the pending fence or restore old credentials.

`status` reports the generation, whether the fence is pending, and the current
authorization's generation and expiry when present. Here, “current” means not
consumed or superseded; it may already be expired. Check the printed expiry.
“Current authorization: none” also does not imply that the fence is clear.

Successful consumption changes the password, marks the capability consumed,
clears the pending fence and any temporary-password requirement, and leaves the
generation at its minted value. Earlier credentials remain unusable. The member
must sign in again and issue replacement personal access tokens as needed.

## Email changes and recovery

Changing an email address under **Settings → Email** requires the current
password and invalidates outstanding email reset links. If a password reset
wins while an email change is verifying the old password, that email change is
rejected: an earlier password proof cannot move the recovery address after the
password has changed. If the email change wins first, the old reset link is
rejected instead. Obtain a new link for the current address when needed.

An ordinary password change under **Settings → Password** also invalidates
earlier Sessions and human access tokens, but keeps the requesting browser
signed in through a replacement Session. Email reset and local recovery issue
no replacement Session. API clients can sign in again through the
[Platform Session API](platform-api/v1/session.md).
