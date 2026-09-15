# Homelab documentation site

The private documentation site is served by a small two-replica Nginx deployment and exposed through the shared Envoy Gateway at `https://docs.home.datalab.gg/`. The namespace is labeled for the Gateway's explicit route admission policy, so the site remains Tailscale-only.

The site is intentionally dependency-light: the checked-in ConfigMap contains the static page and CSS, and the repository remains the source of truth for detailed manifests and runbooks. Update `site-config.yaml`, then run `./apply-docs-site.sh`.
