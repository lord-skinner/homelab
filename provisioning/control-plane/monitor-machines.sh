#!/bin/bash
# Real-time machine boot monitoring
set -euo pipefail

STATE_API_URL="http://10.0.0.10:8080"
REGISTRY_FILE="/srv/http/machines/registry.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_dashboard() {
    clear
    echo -e "${BLUE}=== Homelab Machine Boot Dashboard ===${NC}"
    echo -e "$(date)"
    echo ""
    
    # Get all machine states
    local states=$(curl -s "$STATE_API_URL/api/states" 2>/dev/null || echo '{"states":[]}')
    local machines=$(jq -r '.machines | keys[]' "$REGISTRY_FILE" 2>/dev/null || echo "")
    
    echo -e "${BLUE}Machine Status:${NC}"
    printf "%-18s %-15s %-12s %-15s %s\n" "MAC Address" "Hostname" "Role" "State" "Last Update"
    echo "--------------------------------------------------------------------"
    
    for mac in $machines; do
        local machine_info=$(jq -r --arg mac "$mac" '.machines[$mac] | "\(.hostname)|\(.role)"' "$REGISTRY_FILE")
        local hostname=$(echo "$machine_info" | cut -d'|' -f1)
        local role=$(echo "$machine_info" | cut -d'|' -f2)
        
        local state_info=$(echo "$states" | jq -r --arg mac "$mac" '.states[] | select(.mac == $mac) | "\(.state)|\(.timestamp)"' 2>/dev/null || echo "unknown|never")
        local state=$(echo "$state_info" | cut -d'|' -f1)
        local timestamp=$(echo "$state_info" | cut -d'|' -f2)
        
        # Format timestamp
        if [ "$timestamp" != "never" ]; then
            timestamp=$(date -d "$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
        fi
        
        # Color code based on state
        case "$state" in
            "ready") state_color="${GREEN}$state${NC}" ;;
            "provisioning") state_color="${YELLOW}$state${NC}" ;;
            "error") state_color="${RED}$state${NC}" ;;
            "unknown") state_color="${RED}$state${NC}" ;;
            *) state_color="$state" ;;
        esac
        
        printf "%-18s %-15s %-12s %-15s %s\n" "$mac" "$hostname" "$role" "$(echo -e "$state_color")" "$timestamp"
    done
    
    echo ""
    echo -e "${BLUE}Recent Activity:${NC}"
    echo "$states" | jq -r '.states[] | select(.timestamp != null) | "\(.timestamp) \(.hostname): \(.state) - \(.message)"' 2>/dev/null | tail -10 || echo "No recent activity"
    
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to exit monitoring${NC}"
}

# Handle Ctrl+C gracefully
trap 'echo -e "\n${GREEN}Monitoring stopped${NC}"; exit 0' INT

if [ "${1:-}" = "--once" ]; then
    show_dashboard
else
    echo -e "${GREEN}Starting machine boot monitoring...${NC}"
    echo -e "${YELLOW}Updates every 5 seconds${NC}"
    echo ""
    
    while true; do
        show_dashboard
        sleep 5
    done
fi
