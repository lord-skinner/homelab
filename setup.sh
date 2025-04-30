# add disks mounted in workers to  nodePathMap
kubectl -n kube-system edit cm local-path-config

# run this after updating cm local-path-config
kubectl apply -f storage.yaml
