# Enterprise sign-in

An active owner or administrator configures login providers under **Administration → Authentication**. Each Human connects their own Nexus account under **Settings → Sign-in methods**. A provider identifies the person. Their existing Nexus membership controls their role and access.

## Connect GitLab

1. Create a sign-in provider and choose **GitLab or OpenID Connect**. Enter a name people will recognize and your exact GitLab issuer, such as `https://gitlab.example.com`. Save the draft and copy its callback URL. Set the installation's canonical HTTPS `BASE_URL` before registering a production callback.
2. Register a confidential OAuth application in GitLab with that exact redirect URI and the scopes `openid profile email`. Enter its Application ID and client secret on the Nexus provider. The secret is write-only and encrypted in the database. Keep the installation's encryption keys with your protected backup.
3. Test the configuration in your browser. On success, enable the provider to show its button on the login page. To connect your own account, open personal sign-in settings, choose the provider and confirm the external account shown.
4. Invite another member and have them accept using GitLab. If GitLab does not share their email, the invitation still supplies the assigned address. A verified email returned by GitLab must match the invitation. [GitLab OIDC claims](https://docs.gitlab.com/integration/openid_connect_provider/#shared-information)

If your reverse proxy records access logs, omit query strings for SSO callbacks and invitation or recovery links. These requests carry short-lived codes or one-time credentials.

For a provider offering plain OAuth 2.0, choose **OAuth 2.0**, configure the authorization, token and authenticated user-information endpoints, and specify the field containing a stable account ID. Email, display name and username can change. For GitLab's plain OAuth mode the endpoints are `/oauth/authorize`, `/oauth/token` and `/api/v4/user`. Use the `read_user` scope and `id` for the account ID.

## Register or connect an existing member

Keep registration by invitation unless your provider identifies an appropriate set of employees. To enable registration without an invitation, use a closed enterprise provider or configure the required company group. For GitLab.com this requires OIDC and an exact group path. New uninvited users need a verified email and receive the member role.

Returning members sign in by their external account ID. If an unconnected external account has the same email as an existing Nexus account, sign in to that Nexus account first and connect from Settings. A subject already connected to someone else cannot be claimed. If your address changes at the provider, your existing connection keeps working.

## Require enterprise sign-in

Start in mixed mode. The Authentication page lists active members who still need an external connection. Once all active members, including owners and administrators, have a connected enabled provider, select the SSO-only policy. Invitations then require enterprise sign-in. Terminal users can run `cmctl login --device` or `cmctl setup --device` and approve the displayed code in their browser.

- Members can disconnect a provider when they have another login method allowed by the current policy. A local password only counts in mixed mode.
- Disabling a provider preserves bindings and blocks new logins through it. Nexus refuses a change that would remove an active member's last login method. SSO-only mode also requires at least one enabled provider.
- Deletion is blocked for every provider while SSO-only is active. To retire a provider, move members to an alternative, explicitly switch to mixed mode, disable the old provider and confirm deletion. This deletes its bindings and local secret. Manage the upstream OAuth application separately.
- Existing sessions keep their expiry and revocation rules when a provider or policy changes. Suspend or remove a departing member in Nexus to cut off their member access immediately.

## Reconnect a member

When a member has lost their sole external identity, confirm their identity through your organization's recovery process. On the deployment host, issue a one-time link for the existing Nexus member. Specify the public UUID of the lost provider when replacing an old connection.

```sh
./cybros compose exec nexus bin/rails 'member_recovery:mint_sso[member@example.com,lost-provider-uuid]'
```

On bare metal, run the same Rails task from the Nexus directory with the deployment's Rails environment. If the old provider was deleted, omit the second argument. Give the link privately to the intended member. They authenticate using an enabled provider and confirm the replacement. The link expires after 15 minutes. Issuance fences the member's existing credentials immediately. An expired link can be superseded by minting another. A user suspended or removed in Nexus must be reactivated or restored by an authorized administrator first.
