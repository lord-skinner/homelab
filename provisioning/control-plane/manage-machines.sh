#!/bin/bash
# Machine management script for PXE boot environment
set -euo pipefail

REGISTRY_FILE="/srv/http/machines/registry.json"
STATE_API_URL="http://10.0.0.10:8080"

usage() {
    echo "Usage: $0 {add|remove|list|status|config} [options]"
    echo ""
    echo "Commands:"
    echo "  add MAC HOSTNAME ROLE ARCH FEATURES... - Add a new machine"
    echo "  remove MAC                             - Remove a machine"
    echo "  list                                   - List all machines"
    echo "  status [MAC]                          - Show machine status"
    echo "  config MAC                            - Show machine configuration"
    echo ""
    echo "Examples:"
    echo "  $0 add 00:11:22:33:44:88 worker-3 worker amd64 kubernetes compute"
    echo "  $0 remove 00:11:22:33:44:88"
    echo "  $0 status"
    echo "  $0 config 00:11:22:33:44:55"
}

add_machine() {
    local mac="$1"
    local hostname="$2"
    local role="$3"
    local arch="$4"
    shift 4
    local features=("$@")
    
    # Create feature array JSON
    local features_json="["
    for feature in "${features[@]}"; do
        features_json+='"'$feature'",'
    done
    features_json="${features_json%,}]"
    
    # Generate IP (simple increment from .11)
    local existing_count=$(jq '.machines | length' "$REGISTRY_FILE")
    local ip="10.0.0.$((11 + existing_count))"
    
    # Add machine to registry
    jq --arg mac "$mac" \
       --arg hostname "$hostname" \
       --arg role "$role" \
       --arg arch "$arch" \
       --arg ip "$ip" \
       --argjson features "$features_json" \
       '.machines[$mac] = {
         "hostname": $hostname,
         "role": $role,
         "architecture": $arch,
         "features": $features,
         "ip": $ip,
         "specs": {}
       }' "$REGISTRY_FILE" > /tmp/registry.json && \
    sudo mv /tmp/registry.json "$REGISTRY_FILE"
    
    echo "Added machine $hostname ($mac) with IP $ip"
}

remove_machine() {
    local mac="$1"
    
    jq --arg mac "$mac" 'del(.machines[$mac])' "$REGISTRY_FILE" > /tmp/registry.json && \
    sudo mv /tmp/registry.json "$REGISTRY_FILE"
    
    echo "Removed machine $mac"
}

list_machines() {
    echo "Registered Machines:"
    echo "==================="
    jq -r '.machines | to_entries[] | "\(.key): \(.value.hostname) (\(.value.role)) - \(.value.ip)"' "$REGISTRY_FILE"
}

show_status() {
    local mac="${1:-}"
    
    if [ -n "$mac" ]; then
        curl -s "$STATE_API_URL/api/config/$mac" | jq '.'
    else
        echo "Machine States:"
        echo "==============="
        curl -s "$STATE_API_URL/api/states" | jq -r '.states[] | "\(.mac): \(.hostname) - \(.state) (\(.timestamp))"'
    fi
}

show_config() {
    local mac="$1"
    
    echo "Configuration for $mac:"
    echo "======================"
    jq --arg mac "$mac" '.machines[$mac]' "$REGISTRY_FILE"
}

case "${1:-}" in
    "add")
        if [ $# -lt 5 ]; then
            echo "Error: add requires MAC, hostname, role, architecture, and at least one feature"
            usage
            exit 1
        fi
        add_machine "$2" "$3" "$4" "$5" "${@:6}"
        ;;
    "remove")
        if [ $# -ne 2 ]; then
            echo "Error: remove requires MAC address"
            usage
            exit 1
        fi
        remove_machine "$2"
        ;;
    "list")
        list_machines
        ;;
    "status")
        show_status "${2:-}"
        ;;
    "config")
        if [ $# -ne 2 ]; then
            echo "Error: config requires MAC address"
            usage
            exit 1
        fi
        show_config "$2"
        ;;
    *)
        usage
        exit 1
        ;;
esac
