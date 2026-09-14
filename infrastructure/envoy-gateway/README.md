# Envoy Gateway migration

This directory stages the Envoy Gateway replacement for the K3s-managed
Traefik ingress. The old Traefik `Ingress`, Middleware, TLSStore, and
`traefik-tailscale` resources are intentionally retained until cutover and
the soak period complete.

## Install and stage

```bash
./infrastructure/envoy-gateway/install-envoy-gateway.sh
./infrastructure/envoy-gateway/apply-home-ingress.sh
```

The pinned release is Envoy Gateway `v1.9.1`, installed from the OCI chart
`oci://docker.io/envoyproxy/gateway-helm`. Gateway API and Envoy Gateway CRDs
are applied from that same pinned chart before Helm runs. This permits an
existing K3s/provider-managed Gateway API CRD set to be upgraded in place.

The generated proxy Service is a Tailscale LoadBalancer. It used the temporary
annotation `home-ingress-envoy` during staging and now uses `home-ingress`.
The generated Service name is controller-owned; find it with:

```bash
kubectl -n kube-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=home-ingress -o wide
```

During staging, test the existing hostnames with SNI/Host directed to the
temporary Tailscale address. Confirm the wildcard certificate, HTTP 301
redirects, all three backends, and Nextcloud's `X-Forwarded-Proto: https`.
The Gateway's port-80 redirect works in-cluster; the current tailnet grant
allows TCP 443 only, so external HTTP requests remain blocked until TCP 80 is
added to the tailnet policy.

## Cutover and rollback

The cutover is complete. After the rollback soak period, remove or rename the
old `kube-system/traefik-tailscale` Service. Verify the Tailscale address and DNS
before retiring Traefik. Update Cloudflare's two DNS-only records only if the
Tailscale address changes.

For rollback, restore the old Service hostname/Service, suspend or delete the
Envoy HTTPRoutes, and keep/apply the three existing Traefik Ingresses and the
Nextcloud Middleware. Disable the K3s Traefik addon only after the soak period;
do not use `helm uninstall traefik`, because K3s owns that release.

## Health checks

`scripts/cluster-health-check.sh` checks Envoy Gateway controller availability,
GatewayClass/Gateway conditions, every HTTPRoute's `Accepted` and
`ResolvedRefs` conditions, proxy endpoints, controller/proxy error logs, and
the existing TLS smoke endpoints.
