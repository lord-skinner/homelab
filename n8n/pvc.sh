kubectl run rsync-helper \
  --image=ogivuk/rsync \
  --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "rsync",
      "image": "ogivuk/rsync",
      "command": ["sleep", "3600"],
      "volumeMounts": [
        {"mountPath": "/mnt/old", "name": "oldpvc"},
        {"mountPath": "/mnt/new", "name": "newpvc"}
      ]
    }],
    "volumes": [
      {"name": "oldpvc", "persistentVolumeClaim": {"claimName": "postgres-pvc"}},
      {"name": "newpvc", "persistentVolumeClaim": {"claimName": "postgres-pvc-raid"}}
    ]
  }
}'
