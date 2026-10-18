# Users

An installation is one Account. Users are the people who sign in: owners, administrators and ordinary members. Each Agent has a human manager. Administrators manage installation settings and user access; they do not inspect or manage how a user works with their own agents, conversations or credentials.

## Add a human member

An active owner or administrator adds a human through an invitation or a temporary password. Both create a new member; neither restores a removed one.

### Invite by link or email

Open **Administration → Invitations** (`/admin/invitations`), enter the email address and choose the member or administrator role. The invited email and role are fixed; revoke and recreate to change them. An address already registered to a member cannot be invited.

- An invitation is valid for seven days; there is one invitation per address, including expired ones.
- Without outbound email, copy the invitation link and share it privately. Possession of the link permits joining with its fixed email and role; mailbox ownership is not separately verified.
- With SMTP and a job worker configured, creation requests an email and **Resend** renews the invitation for seven days (at least 60 seconds apart). "Email requested" records the request, not delivery.
- Revoking invalidates every copy of the link.

The recipient chooses a display name and password on the join page; acceptance creates the identity and consumes the invitation atomically.

### Create with a temporary password

Open **Administration → Users → Add user** (`/admin/users/new`), choose the email, display name and role and set a temporary password. Share it privately. The user chooses a new password at first sign-in.

## Password recovery

Neither procedure restores a suspended or removed member, changes a role or signs anyone in.

**Email reset.** The member opens `/passwords/new`, submits their email and follows the link to `/passwords/edit?token=…`. The link is valid for 15 minutes. A successful reset invalidates earlier browser and API sessions and the member's personal access tokens. Email reset needs configured outbound mail and a running job worker; the response never reveals whether an address exists.

**Deployment-local recovery** when email is unavailable, run on the host:

```sh
# Docker stack, from the installation directory
./cybros compose exec nexus bin/rails 'member_recovery:status[member@example.com]'
./cybros compose exec nexus bin/rails 'member_recovery:mint[member@example.com]'
```

`status` inspects without creating a secret. `mint` prints a one-time consume path valid for 15 minutes, immediately fences the member's existing sessions and tokens, and blocks password sign-in until recovery completes. Convey the path privately; opening it does not consume it, submitting a new password does. Minting again supersedes the earlier capability. Expiry does not clear the fence — mint another.

Agent and executor credentials have their own lifecycle; recovery is not a shutdown command for them.

## Roles and self-service

- Owners and administrators: account-wide settings, invitations, member removal, model providers, retention, budgets, system upgrade.
- Every human: their own profile, email and password under **Settings**, personal access tokens and API sessions, their agents (steward) and runners (manager), and the workspaces they own.
- Changing an email requires the current password and invalidates outstanding reset links. An ordinary password change invalidates earlier sessions and tokens but keeps the current browser signed in.

## Suspend and remove

Suspending a human blocks their access; their private workspaces become inaccessible until reactivation. Removing a human first requires every workspace they own that is not deleted to be transferred or deleted. Removal immediately cuts the member's access and closes admission for the agents and runners they manage; running work is stopped at data-safe points by bounded background convergence rather than pretended to have stopped.

For a specific agent, an administrator can reassign its steward or remove and restore it. Removing an agent immediately revokes its member access and application credentials and force-stops its related work asynchronously; an independent runner is unaffected. Restore does not revive old credentials; the application reconnects.

## Users and Agents in administration

**Administration → Users** lists people who can sign in. Search by name or email, filter by
status, and choose **Manage** to change a role, suspend or restore access, or remove a user.
The owner can transfer ownership from another active administrator's page.

**Administration → Agents** lists Agent identities separately. Administrators can change an
Agent's manager or remove and restore its access. Connection settings, API keys and allowances
remain on the current manager's personal **Agents** pages.
