#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo "Missing $SCRIPT_DIR/.env; copy .env.example to .env and set all values." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

SMB_USERNAME="${SMB_USERNAME:-guest}"
SMB_PASSWORD="${SMB_PASSWORD:-}"

for var in MARIADB_PASSWORD MARIADB_ROOT_PASSWORD NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD; do
  if [[ -z "${!var:-}" || "${!var}" == replace-with-* ]]; then
    echo "$var must be set to a real value in .env" >&2
    exit 1
  fi
done

kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl -n nextcloud create secret generic nextcloud-secrets \
  --from-literal=MARIADB_PASSWORD="$MARIADB_PASSWORD" \
  --from-literal=MARIADB_ROOT_PASSWORD="$MARIADB_ROOT_PASSWORD" \
  --from-literal=NEXTCLOUD_ADMIN_USER="$NEXTCLOUD_ADMIN_USER" \
  --from-literal=NEXTCLOUD_ADMIN_PASSWORD="$NEXTCLOUD_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n nextcloud create secret generic nextcloud-smb-credentials \
  --from-literal=username="$SMB_USERNAME" \
  --from-literal=password="$SMB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

for file in "$SCRIPT_DIR"/*.yaml; do
  [[ "$(basename "$file")" == "namespace.yaml" ]] && continue
  kubectl apply -f "$file"
done

echo "Nextcloud deployed at https://nas.home.datalab.gg"
