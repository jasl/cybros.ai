# Deploy with Dokploy

Use Dokploy to run Nexus, PostgreSQL and a full-mode rho on one server. Dokploy owns deployment, HTTPS routing and image updates. The application images include the required runtimes; no host Ruby or JavaScript installation is needed.

## Create the service

1. In a Dokploy project, create a **Compose** service on your deployment server. Choose **Docker Compose**, rather than Docker Stack.
2. Select the **Raw** source and paste [the Compose configuration](https://github.com/jasl/cybros.ai/blob/main/install/dokploy/compose.yaml).
3. Open **Environment** and copy [the environment example](https://github.com/jasl/cybros.ai/blob/main/install/dokploy/.env.example). Set two browser-reachable HTTPS origins without trailing slashes:

   ```dotenv
   CYBROS_NEXUS_URL=https://nexus.example.com
   CYBROS_RHO_URL=https://rho.example.com
   ```

4. Generate an independent value for each empty secret field with `openssl rand -hex 32`. Save the database password, Rails secret and three encryption keys in **Environment**. Keep a private backup; retain these values with their associated data volumes.
5. Leave `NEXUS_SETUP_SECRET` empty for direct first-owner setup. The first person to complete setup creates the administrator account. If you want to restrict that step, generate a separate value with `openssl rand -hex 32` and save it as `NEXUS_SETUP_SECRET` in **Environment**. Retrieve it from that tab when creating the first owner; rho never receives or displays it.
6. Set `CYBROS_IMAGE_TAG` to a published UTC release tag (`yyMMddHHmm`), or use `latest` for the initial installation. Save the environment.

The configuration runs the database, volume initialization, migrations, Nexus, background jobs, the model runner and rho. Data initialization and migration containers exit successfully after their work; the other five services remain running.

## Configure HTTPS

Point two domains you control at the server. Dokploy's generated `sslip.io` domains are HTTP-only and do not provide HTTPS for this recipe. In the Compose service's **Domains** tab, add these routes:

| Domain | Service | Container port | Path |
| --- | --- | --- | --- |
| The host from `CYBROS_NEXUS_URL` | `nexus` | `80` | `/` |
| The host from `CYBROS_RHO_URL` | `rho` | `7777` | `/` |

Enable HTTPS and select the appropriate certificate provider for both routes. TLS terminates at Dokploy's Traefik proxy; the upstream container protocol is HTTP. No application or database port is published directly on the host.

If the service dropdown is empty before the first deployment, choose **Manual** and enter the service name from the table.

Use **Preview Compose** to check the domain routing and networks, then deploy. Nexus, rho and the other services retain their shared Compose network for internal communication. rho reaches Nexus at `http://nexus`; browser authorization uses the public Nexus origin and the exact rho `/auth/callback` URL.

Wait for deployment to finish. Check `https://nexus.example.com/up` and `https://rho.example.com/healthz` using your own domains, then open rho. HTTP health confirms the services are reachable; it does not configure a provider or prove model execution.

## Configure Cloudflare caching

If the rho domain is proxied through Cloudflare, configure caching before opening the WebUI. rho serves HTML, JavaScript modules and CSS at stable URLs with `Cache-Control: no-cache`, so browsers revalidate them after an upgrade. A Cloudflare Browser TTL override such as four hours can replace that header and leave browsers running old scripts after a successful deployment.

In the Cloudflare zone, open **Caching → Cache Rules** and create a rule named **rho: revalidate unversioned frontend**:

1. Select **Custom filter expression** and enter the expression below, replacing `rho.example.com` with the hostname from `CYBROS_RHO_URL`:

   ```text
   (http.host eq "rho.example.com" and not starts_with(http.request.uri.path, "/assets/"))
   ```

2. Set **Cache eligibility** to **Bypass cache**.
3. Add **Browser TTL** and select **Respect origin TTL**. Bypassing the edge cache alone does not configure the browser's cache policy.
4. Deploy the rule and confirm it is **Active**. Ensure no other matching rule overrides these settings.

Keep the rule scoped to rho's hostname. The `/assets/` exception preserves rho's long-lived immutable caching for fingerprinted files; ordinary modules, styles and extension modules must not be placed there under unversioned names. This requirement also applies when another deployment layout puts rho behind Cloudflare.

After deployment, check the public URL through Cloudflare, using your own domain:

```sh
curl -fsS -D - -o /dev/null https://rho.example.com/
curl -fsS -D - -o /dev/null https://rho.example.com/app.js
curl -fsS -D - -o /dev/null https://rho.example.com/styles/base.css
```

Each response should be successful and retain `Cache-Control: no-cache`, without a positive `max-age` override. With this rule, `CF-Cache-Status: DYNAMIC` is expected. Repeat the checks after upgrades and verify the page with an ordinary browser reload. Health endpoints alone do not detect stale frontend files.

Changing the rule or purging Cloudflare's edge cache cannot invalidate copies already stored in a browser under the old TTL. Existing affected browsers may need a one-time cache-bypassing reload or to wait for that TTL to expire. Once they receive the corrected headers, later upgrades require only an ordinary reload.

## Create the owner and connect rho

Choose **Connect to Nexus** on rho. Nexus opens first boot when the database has no Account. Create the first owner and approve rho's connection. A setup secret is requested only if you configured one. Authorization returns to rho and binds its bundled Runner through the ordinary connection flow.

After the first Account exists, setup cannot create another owner. If somebody else initializes a new installation first, ordinary redeployment retains that account because it preserves the database. To start over, discard that installation's data volumes and initialize a fresh installation; this also discards any data already stored there.

Configure a provider and model in settings, then send a normal conversation to verify inference. Provider credentials belong to this Nexus installation; deployment does not import credentials from another installation.

## Preserve data and update

The Compose service owns four named volumes:

| Volume | Contents |
| --- | --- |
| `postgres-data` | Nexus databases |
| `nexus-storage` | Uploaded files |
| `rho-home` | rho identity, settings, connections and runtime state |
| `rho-work` | Working files available to the bundled Runner |

Redeploy the same Compose service to retain these volumes. A new service or project can receive different volume names. Deleting volumes deletes their contents. Preserve the environment secrets as well as the volumes when backing up or moving the installation.

Before an upgrade, stop new work and take a consistent backup. Change `CYBROS_IMAGE_TAG` to the selected published release and redeploy. The migration service prepares the databases before Nexus and its workers start. Follow deployment logs and confirm both health endpoints afterward.

This layout does not run the standalone installation updater. Update images through Dokploy; the application's built-in upgrade action is unavailable. Do not run the standalone stack installer over Dokploy's service directory.

Dokploy's [Compose documentation](https://docs.dokploy.com/docs/core/docker-compose) describes named-volume backups and redeployment. Choose a backup method that keeps database state, uploaded files, rho state and working files consistent; a running database volume copy alone is not a database backup procedure.

## Next

- [Models and providers](models-and-providers.md)
- [Deployment layouts](deployment-layouts.md)
