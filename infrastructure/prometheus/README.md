# Prometheus ingestion

Prometheus is installed as a scraper and remote-write client only. Grafana
and Alertmanager are intentionally disabled. The Prometheus server sends its
time-series data to Elasticsearch's native Prometheus remote-write endpoint,
where Elasticsearch stores it in TSDS data streams. Kibana is the UI.

Install or upgrade the current pinned chart with:

```bash
./install-prometheus.sh
```

## Data-stream layout

Prometheus data is stored in `metrics-generic.prometheus-default` and its
future backing indices. The custom template gives each backing index three
primary shards and one replica, allowing the primaries to distribute across
the three-node Elasticsearch cluster. Its priority is above Elastic's
built-in Prometheus template, so future data-stream rollovers inherit this
layout.

The existing one-primary stream cannot be resharded in place. The reset below
is destructive: it permanently deletes all Prometheus history and buffered
samples in that stream. It does not touch Elastic Agent streams or unrelated
Elasticsearch/Kibana indices. Do not run it during normal Helm installation
or upgrades.

From this directory, run the reset only when data loss is intentional:

```bash
./reset-prometheus-data-stream.sh
```

The script validates the exact target stream, stops Prometheus, installs the
template, deletes only that stream, and restores one Prometheus replica.

## Recovery and verification

After the reset, inspect the recreated stream and backing index with:

```bash
NAMESPACE=elastic-stack
kubectl -n "$NAMESPACE" port-forward svc/elasticsearch-es-http 9200:9200
ES='https://127.0.0.1:9200'
AUTH="elastic:$(kubectl -n "$NAMESPACE" get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 --decode)"
STREAM='metrics-generic.prometheus-default'
curl --fail --silent --insecure --user "$AUTH" "$ES/_data_stream/$STREAM" | jq .
BACKING_INDEX="$(curl --fail --silent --insecure --user "$AUTH" "$ES/_data_stream/$STREAM" | jq -r '.data_streams[0].indices[0].index_name')"
curl --fail --silent --insecure --user "$AUTH" "$ES/$BACKING_INDEX/_settings/index.number_of_shards,index.number_of_replicas,index.mode" | jq .
curl --fail --silent --insecure --user "$AUTH" "$ES/_cluster/health?pretty"
curl --fail --silent --insecure --user "$AUTH" "$ES/_cat/shards/$BACKING_INDEX?v"
kubectl -n "$NAMESPACE" rollout status statefulset/prometheus-prometheus-kube-prometheus-prometheus --timeout=10m
kubectl -n "$NAMESPACE" logs statefulset/prometheus-prometheus-kube-prometheus-prometheus --since=15m | rg 'remote storage|remote_write|context deadline exceeded|VersionConflictEngineException'
```

The health gate is: three primaries, one replica, green cluster health, one
primary on each Elasticsearch node, a remote-write queue near zero, send lag
under two minutes, no new version conflicts or `context deadline exceeded`
errors, and zero remote-write failure/retry rates for 15 minutes. Confirm that
new documents have current timestamps with:

```bash
curl --fail --silent --insecure --user "$AUTH" "$ES/$BACKING_INDEX/_search?size=1&sort=%40timestamp:desc" | jq '.hits.hits[0]._source["@timestamp"]'
```

To check queue depth, lag, and 15-minute failure/retry rates directly in
Prometheus, port-forward it and run:

```bash
kubectl -n "$NAMESPACE" port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
curl --get --silent http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=prometheus_remote_storage_samples_pending'
curl --get --silent http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=time() - prometheus_remote_storage_queue_highest_sent_timestamp_seconds'
curl --get --silent http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=rate(prometheus_remote_storage_samples_failed_total[15m])'
curl --get --silent http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=rate(prometheus_remote_storage_retries_total[15m])'
```

The chart also provides kube-state-metrics and node-exporter. Elasticsearch
and Elastic Agent remain responsible for the native Elastic Kubernetes
metrics streams; Prometheus provides the Prometheus-compatible scrape and
remote-write path for applications and future exporters.
