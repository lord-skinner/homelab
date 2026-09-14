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

section "Envoy Gateway resources"
gatewayclass_json="$(kubectl get gatewayclass envoy -o json 2>/dev/null || echo '{}')"
if jq -e '[.status.conditions[]? | select(.type == "Accepted" and .status == "True")] | length > 0' <<<"$gatewayclass_json" >/dev/null; then
  pass "GatewayClass envoy Accepted=True"
else
  fail "GatewayClass envoy is not Accepted=True"
fi

gateway_json="$(kubectl -n kube-system get gateway home-ingress -o json 2>/dev/null || echo '{}')"
for condition in Accepted Programmed; do
  if jq -e --arg type "$condition" '[.status.conditions[]? | select(.type == $type and .status == "True")] | length > 0' <<<"$gateway_json" >/dev/null; then
    pass "Gateway kube-system/home-ingress $condition=True"
  else
    fail "Gateway kube-system/home-ingress is not $condition=True"
  fi
done
if jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0' <<<"$gateway_json" >/dev/null; then
  pass "Gateway kube-system/home-ingress Ready=True"
elif jq -e '(.status.conditions // []) as $c | ([.status.listeners[]?.conditions[]? | select(.type == "Programmed" and .status == "True")] | length) == ([.status.listeners[]?] | length) and ([.status.listeners[]?] | length) > 0 and ([$c[] | select(.type == "Programmed" and .status == "True")] | length) > 0' <<<"$gateway_json" >/dev/null; then
  # Envoy Gateway v1.9 reports readiness as top-level Programmed plus
  # listener Programmed conditions rather than a top-level Ready condition.
  pass "Gateway kube-system/home-ingress Ready (inferred from Programmed listeners)"
else
  fail "Gateway kube-system/home-ingress has no Ready=True or equivalent programmed listeners"
fi

httproutes_json="$(kubectl get httproute -A -o json 2>/dev/null || echo '{"items":[]}')"
route_count="$(jq '[.items[] | select(.metadata.annotations["gateway.envoyproxy.io/ai-gateway-generated"] != "true")] | length' <<<"$httproutes_json")"
if [[ "$route_count" -eq 0 ]]; then
  fail "no HTTPRoutes found"
else
  while IFS=$'\t' read -r ns name accepted resolved; do
    [[ -z "$name" ]] && continue
    [[ "$accepted" == true ]] && pass "HTTPRoute $ns/$name Accepted=True" || fail "HTTPRoute $ns/$name is not Accepted=True"
    [[ "$resolved" == true ]] && pass "HTTPRoute $ns/$name ResolvedRefs=True" || fail "HTTPRoute $ns/$name is not ResolvedRefs=True"
  done < <(jq -r '.items[] | select(.metadata.annotations["gateway.envoyproxy.io/ai-gateway-generated"] != "true") | [.metadata.namespace,.metadata.name,([.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length > 0),([.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length > 0)] | @tsv' <<<"$httproutes_json")
fi

ai_controller_json="$(kubectl -n envoy-ai-gateway-system get deployment ai-gateway-controller -o json 2>/dev/null || echo '{}')"
if jq -e '(.status.availableReplicas // 0) == (.spec.replicas // 0) and (.spec.replicas // 0) > 0' <<<"$ai_controller_json" >/dev/null; then
  pass "Agent Router controller is available"
else
  fail "Agent Router controller is unavailable"
fi

ai_backends_json="$(kubectl get aiservicebackend -A -o json 2>/dev/null || echo '{"items":[]}')"
ai_backend_count="$(jq '.items | length' <<<"$ai_backends_json")"
if [[ "$ai_backend_count" -eq 0 ]]; then
  fail "no AIServiceBackends found"
else
  while IFS=$'\t' read -r ns name accepted; do
    [[ -z "$name" ]] && continue
    [[ "$accepted" == true ]] && pass "AIServiceBackend $ns/$name Accepted=True" || fail "AIServiceBackend $ns/$name is not Accepted=True"
  done < <(jq -r '.items[] | [.metadata.namespace,.metadata.name,([.status.conditions[]? | select(.type == "Accepted" and .status == "True")] | length > 0)] | @tsv' <<<"$ai_backends_json")
fi

ai_routes_json="$(kubectl get aigatewayroute -A -o json 2>/dev/null || echo '{"items":[]}')"
ai_route_count="$(jq '.items | length' <<<"$ai_routes_json")"
if [[ "$ai_route_count" -eq 0 ]]; then
  fail "no AIGatewayRoutes found"
else
  while IFS=$'\t' read -r ns name accepted; do
    [[ -z "$name" ]] && continue
    [[ "$accepted" == true ]] && pass "AIGatewayRoute $ns/$name Accepted=True" || fail "AIGatewayRoute $ns/$name is not Accepted=True"
  done < <(jq -r '.items[] | [.metadata.namespace,.metadata.name,([.status.conditions[]? | select(.type == "Accepted" and .status == "True")] | length > 0)] | @tsv' <<<"$ai_routes_json")
fi

semantic_router_json="$(kubectl -n vllm-semantic-router-system get deployment semantic-router -o json 2>/dev/null || echo '{}')"
if jq -e '(.status.availableReplicas // 0) == (.spec.replicas // 0) and (.spec.replicas // 0) > 0' <<<"$semantic_router_json" >/dev/null; then
  pass "vLLM Semantic Router is available"
else
  fail "vLLM Semantic Router is unavailable"
fi
semantic_router_endpoints="$(kubectl -n vllm-semantic-router-system get endpoints semantic-router -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)"
[[ -n "$semantic_router_endpoints" ]] && pass "Semantic Router gRPC Service has ready endpoints" || fail "Semantic Router gRPC Service has no ready endpoints"

semantic_policy_json="$(kubectl -n kube-system get envoypatchpolicy semantic-router-extproc -o json 2>/dev/null || echo '{}')"
for condition in Accepted Programmed; do
  if jq -e --arg type "$condition" '[.status.ancestors[]?.conditions[]? | select(.type == $type and .status == "True")] | length > 0' <<<"$semantic_policy_json" >/dev/null; then
    pass "EnvoyPatchPolicy kube-system/semantic-router-extproc $condition=True"
  else
    fail "EnvoyPatchPolicy kube-system/semantic-router-extproc is not $condition=True"
  fi
done

proxy_service="$(kubectl -n kube-system get svc -l gateway.envoyproxy.io/owning-gateway-name=home-ingress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
proxy_deployment="$(kubectl -n kube-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=home-ingress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$proxy_service" ]]; then
  proxy_endpoints="$(kubectl -n kube-system get endpoints "$proxy_service" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "$proxy_endpoints" ]] && pass "Envoy proxy Service $proxy_service has ready endpoints" || fail "Envoy proxy Service $proxy_service has no ready endpoints"
else
  fail "no Envoy proxy Service found for Gateway home-ingress"
fi

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
check_log "Envoy Gateway controller errors" envoy-gateway-system deploy/envoy-gateway '(^|[[:space:]])(error|ERROR|fatal|FATAL|panic|PANIC)([[:space:]]|$)|"log.level":"error"'
check_log "Agent Router controller errors" envoy-ai-gateway-system deploy/ai-gateway-controller '(^|[[:space:]])(error|ERROR|fatal|FATAL|panic|PANIC)([[:space:]]|$)|"log.level":"error"'
if [[ -n "${proxy_service:-}" ]]; then
  if [[ -n "${proxy_deployment:-}" ]]; then
    check_log "Envoy proxy configuration/upstream errors" kube-system "deploy/$proxy_deployment" '"response_flags":"[^-]|configuration.*(error|rejected)|cluster.*(warming|unhealthy)'
  else
    fail "Envoy proxy Service exists but its Deployment was not found"
  fi
fi
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
