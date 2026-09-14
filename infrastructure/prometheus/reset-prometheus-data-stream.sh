#!/usr/bin/env bash

set -euo pipefail

# This operation intentionally deletes all Prometheus data in the target stream.
NAMESPACE="${NAMESPACE:-elastic-stack}"
PROMETHEUS_RESOURCE="${PROMETHEUS_RESOURCE:-prometheus-kube-prometheus-prometheus}"
PROMETHEUS_STATEFULSET="${PROMETHEUS_STATEFULSET:-prometheus-$PROMETHEUS_RESOURCE}"
ES_SERVICE="${ES_SERVICE:-127.0.0.1:19200}"
TARGET_DATA_STREAM="${TARGET_DATA_STREAM:-metrics-generic.prometheus-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/prometheus-index-template.json"

[[ -r "$TEMPLATE_FILE" ]] || { echo "Template file is not readable: $TEMPLATE_FILE" >&2; exit 1; }

if [[ "$TARGET_DATA_STREAM" != "metrics-generic.prometheus-default" ]]; then
  echo "Refusing to run: TARGET_DATA_STREAM must be exactly metrics-generic.prometheus-default" >&2
  exit 1
fi

for command_name in kubectl curl jq; do
  command -v "$command_name" >/dev/null || { echo "$command_name is required" >&2; exit 1; }
done

kubectl -n "$NAMESPACE" get prometheus "$PROMETHEUS_RESOURCE" >/dev/null
kubectl -n "$NAMESPACE" get statefulset "$PROMETHEUS_STATEFULSET" >/dev/null

elastic_password="$(kubectl -n "$NAMESPACE" get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 --decode)"
es_url="https://$ES_SERVICE"
es_curl=(curl --fail --silent --show-error --insecure \
  --user "elastic:$elastic_password" -H 'Content-Type: application/json')

port_forward_pid=""
cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$ES_SERVICE" == "127.0.0.1:19200" ]]; then
  kubectl -n "$NAMESPACE" port-forward svc/elasticsearch-es-http 19200:9200 \
    >/dev/null 2>&1 &
  port_forward_pid=$!
  for _ in {1..30}; do
    if "${es_curl[@]}" "$es_url/" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

stream_json="$("${es_curl[@]}" "$es_url/_data_stream/$TARGET_DATA_STREAM")"
if [[ "$(jq -r '.data_streams | length' <<<"$stream_json")" != "1" ]] || \
   [[ "$(jq -r '.data_streams[0].name' <<<"$stream_json")" != "$TARGET_DATA_STREAM" ]]; then
  echo "Refusing to run: expected exactly one target data stream named $TARGET_DATA_STREAM" >&2
  exit 1
fi

echo "Scaling Prometheus to zero before deleting $TARGET_DATA_STREAM..."
kubectl -n "$NAMESPACE" patch prometheus "$PROMETHEUS_RESOURCE" \
  --type merge --patch '{"spec":{"replicas":0}}' >/dev/null
kubectl -n "$NAMESPACE" scale statefulset "$PROMETHEUS_STATEFULSET" --replicas=0 >/dev/null

for _ in {1..60}; do
  pods="$(kubectl -n "$NAMESPACE" get pods \
    -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=$PROMETHEUS_RESOURCE" \
    --no-headers 2>/dev/null || true)"
  [[ -z "$pods" ]] && break
  sleep 5
done
if [[ -n "$(kubectl -n "$NAMESPACE" get pods \
    -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=$PROMETHEUS_RESOURCE" \
    --no-headers 2>/dev/null || true)" ]]; then
  echo "Timed out waiting for Prometheus pods to terminate" >&2
  exit 1
fi

echo "Installing the three-primary-shard index template..."
"${es_curl[@]}" -X PUT "$es_url/_index_template/prometheus-time-series" \
  --data-binary "@$TEMPLATE_FILE" >/dev/null

echo "Deleting only $TARGET_DATA_STREAM..."
"${es_curl[@]}" -X DELETE "$es_url/_data_stream/$TARGET_DATA_STREAM" >/dev/null

echo "Restoring Prometheus with one replica..."
kubectl -n "$NAMESPACE" patch prometheus "$PROMETHEUS_RESOURCE" \
  --type merge --patch '{"spec":{"replicas":1}}' >/dev/null

echo "Waiting for Prometheus and the recreated data stream..."
kubectl -n "$NAMESPACE" rollout status statefulset/"$PROMETHEUS_STATEFULSET" --timeout=10m
for _ in {1..120}; do
  if stream_json="$("${es_curl[@]}" "$es_url/_data_stream/$TARGET_DATA_STREAM" 2>/dev/null)" && \
     [[ "$(jq -r '.data_streams | length' <<<"$stream_json")" == "1" ]]; then
    backing_index="$(jq -r '.data_streams[0].indices[0].index_name // empty' <<<"$stream_json")"
    if [[ -n "$backing_index" ]] && "${es_curl[@]}" "$es_url/$backing_index" >/dev/null 2>&1; then
      echo "Recreated $TARGET_DATA_STREAM with backing index $backing_index."
      exit 0
    fi
  fi
  sleep 5
done

echo "Timed out waiting for $TARGET_DATA_STREAM and its backing index" >&2
exit 1
