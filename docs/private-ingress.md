# Private ingress: Tailscale -> Traefik -> apps (`*.home.datalab.gg`)

## Architecture

Remote Tailscale client -> tailnet -> Tailscale operator -> Service
`kube-system/traefik-tailscale` (`loadBalancerClass: tailscale`,
device `home-ingress`, `100.111.204.32`) -> existing k3s Traefik
(ClusterIP `10.43.75.249`) -> per-app ClusterIP Services.

Traefik terminates TLS with the shared production wildcard certificate.
No router port forwarding. No public LoadBalancer. No per-app Tailscale
services. The k3s-managed Traefik Service/Deployment are never edited;
everything here is additive.

## Domains

- `*.home.datalab.gg` and `home.datalab.gg` resolve (public DNS-only A
  records) to the Tailscale IP `100.111.204.32`. DNS visibility is public
  but `100.64.0.0/10` is unroutable off-tailnet: only tailnet members can
  connect. Verified: off-tailnet TCP 443 times out.
- If the `traefik-tailscale` Service is ever deleted/recreated, the proxy
  device (and its `100.x` IP) changes: update the two A records in
  Cloudflare (`*.home.datalab.gg`, `home.datalab.gg`, DNS-only,
  TTL 300). Operator upgrades/restarts keep the same device.

## TLS

- cert-manager `v1.21.1` (Helm, namespace `cert-manager`), Cloudflare
  DNS-01 via in-cluster Secret `cert-manager/cloudflare-api-token`
  (created from `$CLOUDFLARE_TOKEN`, never in Git).
- `ClusterIssuer/letsencrypt-staging` (debug target) and
  `ClusterIssuer/letsencrypt-production`.
- Production wildcard: `Certificate/kube-system/home-datalab-gg-wildcard`
  -> Secret `kube-system/home-datalab-gg-wildcard-tls`
  (`*.home.datalab.gg`, `home.datalab.gg`), auto-renewed.
- `TLSStore/kube-system/default` makes it Traefik's default certificate.

## Tailscale operator

- Chart `tailscale/tailscale-operator` pinned `1.102.3`, namespace
  `tailscale`. Non-secret values: `infrastructure/tailscale/operator-values.yaml`.
- OAuth credentials passed at install via
  `--set-string oauth.clientId/clientSecret` from `$TAILSCALE_CLIENT_ID` /
  `$TAILSCALE_CLIENT_SECRET`; stored only as in-cluster Secret
  `tailscale/operator-oauth` (Helm-managed).
- Operator + ingress proxy both carry `tag:k8s-operator` (the tag the
  OAuth client owns; the chart default `tag:k8s` was rejected by the API).
  Tailnet grants must target `tag:k8s-operator`, TCP 443.
- Kubernetes API is NOT exposed (`apiServerProxyConfig.mode: "false"`).

## Adding a new private service

Only two things, e.g. for `example.home.datalab.gg`:

1. A normal ClusterIP Service (no NodePort/LoadBalancer).
2. An Ingress like this (no per-app certificate needed):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example
  namespace: example-ns
spec:
  ingressClassName: traefik
  rules:
    - host: example.home.datalab.gg
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: example
                port:
                  number: 80
  tls:
    - hosts:
        - example.home.datalab.gg
```

DNS already covers it via the wildcard record. Never create another
Tailscale LoadBalancer per app.

## Troubleshooting

```bash
# Tailscale operator
kubectl get pods -n tailscale
kubectl logs -n tailscale deploy/operator --tail=50 | grep -iE "error|reconcile"
kubectl get svc -n kube-system traefik-tailscale -o wide   # EXTERNAL-IP = 100.x + MagicDNS
kubectl get sts -n tailscale                                # proxy StatefulSet

# DNS (public resolution of tailnet IP)
python3 -c "import socket; print(socket.gethostbyname('automate.home.datalab.gg'))"

# cert-manager
kubectl get certificate,certificaterequest,order,challenge -n kube-system
kubectl describe order -n kube-system <order-name>

# Traefik / routing
kubectl get tlsstore -n kube-system
kubectl get ingress -A
kubectl get svc -n kube-system traefik-tailscale -o jsonpath='{.spec}'
kubectl run curl-test --image=curlimages/curl:8.22.0 --restart=Never --rm -i \
  --command -- curl -sv --resolve automate.home.datalab.gg:443:10.43.75.249 \
  https://automate.home.datalab.gg/

# Remote (from a tailnet laptop)
tailscale status | grep home-ingress
curl -v https://automate.home.datalab.gg/
```

## Live private service

- n8n at `https://automate.home.datalab.gg` (`n8n/` manifests: ClusterIP
  Service + Ingress; `N8N_HOST`/`N8N_PROTOCOL`/`WEBHOOK_URL` env match the
  public URL). The temporary `test` validation namespace was removed after
  proving the path.
- FileBrowser at `https://nas.home.datalab.gg` (`filebrowser/` manifests:
  ClusterIP Service + Ingress; local `local-path` PVCs for `/srv` and
  state until the NAS export is reachable from the cluster).
