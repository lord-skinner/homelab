# Cluster health and rollout verification

Run the non-mutating check from a workstation with access to the cluster:

```bash
./scripts/cluster-health-check.sh
```

It checks node readiness and pressure, Deployment/StatefulSet/DaemonSet
availability, PVC phase, PostgreSQL role/probe noise, ingress Service ports and
endpoints, Gateway API and Envoy proxy conditions/endpoints, Prometheus alerts
and `up == 0` targets, recent restarts, recurring CSI-SMB/Traefik/Envoy/Elastic
Agent errors, valid hostname TLS, application smoke
endpoints, and complete Filebrowser removal. It uses a local Prometheus
port-forward and makes no Kubernetes resource changes.

The smoke checks intentionally do not use `curl -k`. Expected healthy responses
are HTTP 200 for n8n and HTTP 302 for Nextcloud and Kibana; any 2xx/3xx status
with successful certificate verification is accepted.

## Post-rollout observation

Run the check immediately after a rollout and again after at least 15 minutes:

```bash
./scripts/cluster-health-check.sh
sleep 900
./scripts/cluster-health-check.sh
```

The second run is the acceptance point. Historical restarts and messages from
before the rollout are not remediation failures. CSI-SMB socket warnings and
Traefik `service not found` messages can occur while controllers or ingress are
converging; they are failures if they continue in the post-rollout log window.

Elastic Agent may emit its known upgrade-cleanup warning about an orphaned
versioned symlink. Treat it as informational unless export failures occur or
the Agent resource/pods become unavailable.

## PostgreSQL probe correction

The PostgreSQL container is initialized with the configured `n8n` role and
database. Both probes therefore use:

```text
pg_isready -U n8n -d n8n
```

After applying `n8n/postgres-deployment.yaml`, verify the persistent data and
the application connection without changing data:

```bash
kubectl -n n8n exec deploy/postgres -- psql -U n8n -d n8n -Atqc \
  'SELECT current_user, current_database();'
kubectl -n n8n rollout status deploy/postgres --timeout=5m
kubectl -n n8n logs deploy/postgres --since=15m | \
  rg 'role "postgres" does not exist' || true
```

The role query should return `n8n|n8n`, and the log search should be empty.
