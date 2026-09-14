# Private ingress: Tailscale -> Envoy Gateway -> apps (`*.home.datalab.gg`)

## Architecture

Remote Tailscale client -> tailnet -> Tailscale operator -> Envoy Gateway
Service in `kube-system` (`loadBalancerClass: tailscale`) -> per-app ClusterIP
Services. The live Envoy device is `home-ingress` at `100.125.103.115`; the
former Traefik device remains available as `home-ingress-traefik` at
`100.111.204.32` during the rollback soak period.

Envoy Gateway terminates TLS with the shared production wildcard certificate.
No router port forwarding. No public LoadBalancer. No per-app Tailscale
services. The existing Traefik resources remain available as rollback during
the migration.

## Domains

- `*.home.datalab.gg` and `home.datalab.gg` resolve (public DNS-only A
  records) to the Tailscale IP `100.125.103.115`. DNS visibility is public
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
- `Gateway/kube-system/home-ingress` references the wildcard Secret directly.

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
2. An HTTPRoute attached to `kube-system/home-ingress` (no per-app
   certificate needed). The application namespace must carry the
   `gateway-access: home-ingress` label.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example
  namespace: example-ns
spec:
  parentRefs:
    - name: home-ingress
      namespace: kube-system
      sectionName: https
  hostnames: [example.home.datalab.gg]
  rules:
    - backendRefs:
        - name: example
          port: 80
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

# Envoy Gateway / routing
kubectl get gatewayclass envoy
kubectl get gateway,httproute -A
kubectl -n kube-system get svc -l gateway.envoyproxy.io/owning-gateway-name=home-ingress -o wide
kubectl -n kube-system get svc traefik-tailscale -o jsonpath='{.spec}'  # rollback path
kubectl run curl-test --image=curlimages/curl:8.22.0 --restart=Never --rm -i \
  --command -- curl -sv --resolve automate.home.datalab.gg:443:10.43.75.249 \
  https://automate.home.datalab.gg/

# Remote (from a tailnet laptop)
tailscale status | grep home-ingress
curl -v https://automate.home.datalab.gg/
```

## Live private service

- n8n at `https://automate.home.datalab.gg` (`n8n/` manifests: ClusterIP
  Service + HTTPRoute; `N8N_HOST`/`N8N_PROTOCOL`/`WEBHOOK_URL` env match the
  public URL). The temporary `test` validation namespace was removed after
  proving the path.
- Nextcloud at `https://nas.home.datalab.gg` (`nextcloud/` manifests:
  ClusterIP Service + HTTPRoute, MariaDB, Redis, and an SMB CSI-backed PVC for
  application/data storage). The old FileBrowser resources are removed.

  The data PVC uses the dedicated `nextcloud` subdirectory of the NAS's
  `NetworkShare` export at `192.168.0.242`; existing share contents are not
  mounted as part of Nextcloud.
- Kibana at `https://es.home.datalab.gg` (`elastic/` manifests; ECK-managed
  Kibana service behind the same private Envoy Gateway). Elasticsearch,
  Kibana, and Elastic Agent are version 9.5.3.
