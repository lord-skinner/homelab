#!/usr/bin/env bash
# Non-mutating health and smoke checks for the homelab K3s cluster.
set -uo pipefail

PROM_NAMESPACE="${PROM_NAMESPACE:-elastic-stack}"
PROM_SERVICE="${PROM_SERVICE:-prometheus-kube-prometheus-prometheus}"
LOG_WINDOW="${LOG_WINDOW:-15m}"
FAILURES=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$*" >&2; }
section() { printf '\n== %s ==\n' "$*"; }

section "Prerequisites"
for command in kubectl jq curl; do
  command -v "$command" >/dev/null 2>&1 && pass "$command is available" || fail "required command is missing: $command"
done
(( FAILURES == 0 )) || exit 2

section "Nodes and pressure conditions"
nodes_json="$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')"
node_count="$(jq '.items | length' <<<"$nodes_json")"
[[ "$node_count" -eq 5 ]] && pass "all five expected nodes are present" || fail "expected 5 nodes, found $node_count"
while IFS=$'\t' read -r name ready pressure; do
  [[ -z "$name" ]] && continue
  [[ "$ready" == True ]] || fail "$name is not Ready"
  [[ "$pressure" == none ]] || fail "$name has pressure conditions: $pressure"
  [[ "$ready" == True && "$pressure" == none ]] && pass "$name Ready with no memory/disk/PID pressure"
done < <(jq -r '.items[] | [.metadata.name,([.status.conditions[] | select(.type == "Ready") | .status] | first // "Unknown"),([.status.conditions[] | select((.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") and .status == "True") | .type] | if length == 0 then "none" else join(",") end)] | @tsv' <<<"$nodes_json")

section "Workload availability"
for kind in deploy sts ds; do
  json="$(kubectl get "$kind" -A -o json 2>/dev/null || echo '{"items":[]}')"
  while IFS=$'\t' read -r ns name desired ready; do
    [[ -z "$name" ]] && continue
    if [[ "$kind" == deploy ]]; then label=Deployment; else [[ "$kind" == sts ]] && label=StatefulSet || label=DaemonSet; fi
    if [[ "$desired" == "$ready" ]]; then pass "$label $ns/$name ready ($ready/$desired)"; else fail "$label $ns/$name unavailable ($ready/$desired)"; fi
  done < <(jq -r --arg kind "$kind" '.items[] | if $kind == "deploy" then [.metadata.namespace,.metadata.name,(.spec.replicas // 0),(.status.availableReplicas // 0)] elif $kind == "sts" then [.metadata.namespace,.metadata.name,(.spec.replicas // 0),(.status.readyReplicas // 0)] else [.metadata.namespace,.metadata.name,.status.desiredNumberScheduled,.status.numberReady] end | @tsv' <<<"$json")
done

section "Persistent volumes"
pvc_json="$(kubectl get pvc -A -o json 2>/dev/null || echo '{"items":[]}')"
while IFS=$'\t' read -r ns name phase; do
  [[ -z "$name" ]] && continue
  [[ "$phase" == Bound ]] && pass "PVC $ns/$name Bound" || fail "PVC $ns/$name is $phase"
done < <(jq -r '.items[] | [.metadata.namespace,.metadata.name,.status.phase] | @tsv' <<<"$pvc_json")

section "n8n PostgreSQL"
if kubectl -n n8n exec deploy/postgres -- psql -U n8n -d n8n -Atqc 'SELECT current_user, current_database();' 2>/dev/null | grep -q 'n8n'; then pass "PostgreSQL data volume accepts the n8n role/database"; else fail "PostgreSQL role/database check failed"; fi
postgres_log="$(kubectl -n n8n logs deploy/postgres --since="$LOG_WINDOW" 2>/dev/null || true)"
postgres_bad="$(grep -c 'role "postgres" does not exist' <<<"$postgres_log" || true)"
[[ "$postgres_bad" -eq 0 ]] && pass "no PostgreSQL probe failures in the last $LOG_WINDOW" || fail "$postgres_bad PostgreSQL probe failures in the last $LOG_WINDOW"

section "Ingress backend consistency"
ingress_json="$(kubectl get ingress -A -o json 2>/dev/null || echo '{"items":[]}')"
while IFS=$'\t' read -r ns ingress service port; do
  [[ -z "$ingress" ]] && continue
  if ! kubectl -n "$ns" get svc "$service" >/dev/null 2>&1; then fail "Ingress $ns/$ingress references missing Service $service"; continue; fi
  svc_json="$(kubectl -n "$ns" get svc "$service" -o json 2>/dev/null || echo '{}')"
  if ! jq -e --arg p "$port" '[.spec.ports[] | (.port|tostring)] | index($p) != null' <<<"$svc_json" >/dev/null; then fail "Ingress $ns/$ingress references missing Service port $port"; continue; fi
  endpoints="$(kubectl -n "$ns" get endpoints "$service" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "$endpoints" ]] && pass "Ingress $ns/$ingress -> $service:$port has endpoints" || fail "Ingress $ns/$ingress -> $service:$port has no ready endpoints"
done < <(jq -r '.items[] as $i | ($i.spec.rules // [])[] as $rule | ($rule.http.paths // [])[] | [$i.metadata.namespace,$i.metadata.name,.backend.service.name,(.backend.service.port.number // .backend.service.port.name // "")] | @tsv' <<<"$ingress_json")

section "Prometheus alerts and scrape targets"
pf_log="$(mktemp)"
kubectl -n "$PROM_NAMESPACE" port-forward "svc/$PROM_SERVICE" 19090:9090 >"$pf_log" 2>&1 & pf_pid=$!
cleanup() { kill "$pf_pid" >/dev/null 2>&1 || true; rm -f "$pf_log"; }
trap cleanup EXIT
prom_ready=0
for _ in {1..20}; do curl --silent --fail --max-time 2 http://127.0.0.1:19090/-/ready >/dev/null 2>&1 && prom_ready=1 && break; sleep 1; done
if [[ "$prom_ready" -eq 1 ]]; then
  alerts="$(curl --silent --fail http://127.0.0.1:19090/api/v1/alerts 2>/dev/null || echo '{}')"
  firing="$(jq '[.data.alerts[]? | select(.state == "firing")] | length' <<<"$alerts")"
  [[ "$firing" -eq 0 ]] && pass "Prometheus has no firing alerts" || fail "Prometheus has $firing firing alert(s)"
  down="$(curl --silent --fail --get --data-urlencode 'query=up == 0' http://127.0.0.1:19090/api/v1/query 2>/dev/null || echo '{}')"
  down_count="$(jq '.data.result | length' <<<"$down")"
  [[ "$down_count" -eq 0 ]] && pass "Prometheus has no down scrape targets" || fail "Prometheus has $down_count down scrape target(s)"
else
  fail "Prometheus API did not become ready: $(tr '\n' ' ' <"$pf_log")"
fi

section "Recent restarts and recurring log patterns"
recent=0
while IFS=$'\t' read -r ns pod container finished; do
  [[ -z "$pod" || -z "$finished" ]] && continue
  if (( $(date -d "$finished" +%s 2>/dev/null || echo 0) > $(date +%s) - 900 )); then recent=1; fail "$ns/$pod container $container terminated at $finished"; fi
done < <(kubectl get pods -A -o json 2>/dev/null | jq -r '.items[] as $p | ($p.status.containerStatuses[]?, $p.status.initContainerStatuses[]?) | select(.lastState.terminated.finishedAt != null) | [$p.metadata.namespace,$p.metadata.name,.name,.lastState.terminated.finishedAt] | @tsv')
(( recent == 0 )) && pass "no container termination in the last 15 minutes"
check_log() { local label=$1 ns=$2 resource=$3 pattern=$4 count; count="$(kubectl -n "$ns" logs "$resource" --since="$LOG_WINDOW" --all-containers=true 2>/dev/null | grep -Eic "$pattern" || true)"; [[ "$count" -eq 0 ]] && pass "$label: no matches in $LOG_WINDOW" || fail "$label: $count match(es) in $LOG_WINDOW"; }
check_log "CSI-SMB errors" kube-system daemonset/csi-smb-node 'error|fail|socket.*warn'
check_log "Traefik backend errors" kube-system deploy/traefik 'service.*not found|endpoints.*not found|backend.*error'
check_log "Elastic Agent export failures" elastic-stack daemonset/elastic-agent-agent 'export.*fail|failed.*export|export.*error'

section "Application smoke checks with certificate validation"
for host in automate.home.datalab.gg nas.home.datalab.gg es.home.datalab.gg; do
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 5 --max-time 20 "https://$host/" 2>/dev/null || echo 000)"
  [[ "$status" =~ ^[23][0-9][0-9]$ ]] && pass "$host TLS verified and returned HTTP $status" || fail "$host returned HTTP $status or failed certificate validation"
done

section "Filebrowser removal check"
kubectl get namespace filebrowser >/dev/null 2>&1 && fail "namespace filebrowser still exists" || pass "namespace filebrowser is absent"
filebrowser_resources="$(kubectl get all,ingress,pvc -A -o json 2>/dev/null | jq -r '.items[] | select((.metadata.name | ascii_downcase | contains("filebrowser")) or (.metadata.namespace | ascii_downcase | contains("filebrowser"))) | [.kind,.metadata.namespace,.metadata.name] | @tsv')"
[[ -z "$filebrowser_resources" ]] && pass "no Filebrowser resources remain" || fail "Filebrowser resources remain: $filebrowser_resources"

trap - EXIT
cleanup
printf '\nSummary: %d failure(s)\n' "$FAILURES"
(( FAILURES == 0 ))
