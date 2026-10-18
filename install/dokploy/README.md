# Cybros on Dokploy

Paste `compose.yaml` into a Dokploy Compose service using the Raw source, and
configure its Environment tab from `.env.example`. Follow the
[deployment guide](../../guides/operate/dokploy.md) for HTTPS domains, Cloudflare caching, first boot,
persistent storage and upgrades.

Dokploy owns this deployment's lifecycle. This recipe uses named volumes and
does not run the standalone stack updater.
