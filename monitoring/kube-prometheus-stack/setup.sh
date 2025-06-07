# https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Check for the latest version of the chart
helm search repo prometheus-community
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace kube-prometheus-stack


# get the Grafana admin password
kubectl --namespace kube-prometheus-stack get secrets kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo


# convert the helm chart to yaml
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --output-dir .


# clean up 
helm uninstall kube-prometheus-stack
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com
kubectl delete crd alertmanagers.monitoring.coreos.com
kubectl delete crd podmonitors.monitoring.coreos.com
kubectl delete crd probes.monitoring.coreos.com
kubectl delete crd prometheusagents.monitoring.coreos.com
kubectl delete crd prometheuses.monitoring.coreos.com
kubectl delete crd prometheusrules.monitoring.coreos.com
kubectl delete crd scrapeconfigs.monitoring.coreos.com
kubectl delete crd servicemonitors.monitoring.coreos.com
kubectl delete crd thanosrulers.monitoring.coreos.com
