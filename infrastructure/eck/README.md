# Elastic Cloud on Kubernetes

This repository uses Elastic Cloud on Kubernetes (ECK) 3.5.0 to manage the
Elastic Stack. ECK is installed cluster-wide in `elastic-system`; the stack
resources live in the `elastic-stack` namespace.

The current manifests use Elasticsearch, Kibana, and Elastic Agent 9.5.3.
Elasticsearch data uses three 50Gi local-path volumes, one per node. Kibana
is exposed privately at `https://es.home.datalab.gg`.

Install or upgrade ECK with:

```bash
./install-eck.sh
```

Then inspect the generated `elastic` password:

```bash
kubectl -n elastic-stack get secret elasticsearch-es-elastic-user \
  -o go-template='{{.data.elastic | base64decode}}'; echo
```

The initial Elastic Agent collects Kubernetes API, node, pod, container,
volume, event, and kubelet metrics. Add the Kubernetes integration in Kibana
later when you want managed dashboards and container log collection.
