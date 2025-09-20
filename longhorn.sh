#!/bin/bash

helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn in the longhorn-system namespace
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace

export alias k="sudo kubectl"

k label node k3s-arm-node-0 longhorn=enabled
k taint node k3s-arm-node-0 longhorn=dedicated:NoSchedule

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --set defaultSettings.defaultDataLocality=best-effort \
  --set "persistence.default.nodeSelector.longhorn=enabled" \
  --set "persistence.default.tolerations[0].key=longhorn" \
  --set "persistence.default.tolerations[0].operator=Equal" \
  --set "persistence.default.tolerations[0].value=dedicated" \
  --set "persistence.default.tolerations[0].effect=NoSchedule"
