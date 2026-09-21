#!/usr/bin/env bash
# =====================================================================
# Pushes the manually-maintained dashboard JSONs (the big v10 investigation
# dashboard + the 8 standalone quick-view ones) straight into Grafana via
# its HTTP API, into the correct folders, creating those folders first if
# they don't exist yet. Replaces doing this by hand through Import each time.
#
# These are separate from the 10 generic starter dashboards in
# 11-grafana-dashboards.yaml, which are auto-provisioned from a ConfigMap
# and never need this script.
#
# Requires: curl, jq (`sudo apt install jq` / `sudo yum install jq` if missing)
#
# Usage:
#   GRAFANA_URL=http://<node-ip>:30300 GRAFANA_PASSWORD='...' ./apply-dashboards.sh
#
# GRAFANA_URL: use the NodePort form (http://<node-ip>:30300) unless you've
# confirmed the certbot/TLS stage on the external nginx has landed — per
# ARCHITECTURE.md, https://apm.devopslabs.tech was still Stage 1 (plain
# HTTP only) as of the last check.
# =====================================================================
set -euo pipefail

: "${GRAFANA_URL:?Set GRAFANA_URL, e.g. http://<node-ip>:30300}"
: "${GRAFANA_PASSWORD:?Set GRAFANA_PASSWORD (the password stored in the grafana-admin Secret)}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
AUTH="${GRAFANA_USER}:${GRAFANA_PASSWORD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed. Try: sudo apt install jq" >&2
  exit 1
fi

# file -> destination folder title
FILES=(
  "Exora_G360_SRE_API_Dashboard_v10.json:APM"
  "standalone-dashboards/DevopsLabs_APM_API-Performance.json:APM"
  "standalone-dashboards/DevopsLabs_APM_JVM-Memory.json:APM"
  "standalone-dashboards/DevopsLabs_APM_Request-Investigation.json:APM"
  "standalone-dashboards/DevopsLabs_APM_Service-Dependencies.json:APM"
  "standalone-dashboards/DevopsLabs_Database_Connection-Pool.json:Database"
  "standalone-dashboards/DevopsLabs_Infrastructure_Kubernetes-Workload.json:Infrastructure"
  "standalone-dashboards/DevopsLabs_Infrastructure_Node-Health.json:Infrastructure"
  "standalone-dashboards/DevopsLabs_Platform_Telemetry-Pipeline-Health.json:Platform"
)

declare -A FOLDER_UID_CACHE=()

get_or_create_folder_uid() {
  local title="$1"
  if [[ -n "${FOLDER_UID_CACHE[$title]:-}" ]]; then
    echo "${FOLDER_UID_CACHE[$title]}"
    return
  fi
  local uid
  uid=$(curl -sf -u "$AUTH" "$GRAFANA_URL/api/folders" \
    | jq -r --arg t "$title" '.[] | select(.title==$t) | .uid' | head -n1)
  if [[ -z "$uid" || "$uid" == "null" ]]; then
    uid=$(curl -sf -u "$AUTH" -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$title" '{title:$t}')" \
      "$GRAFANA_URL/api/folders" | jq -r '.uid')
    echo "  (created folder '$title')" >&2
  fi
  FOLDER_UID_CACHE[$title]="$uid"
  echo "$uid"
}

for entry in "${FILES[@]}"; do
  file="${entry%%:*}"
  folder_title="${entry##*:}"

  if [[ ! -f "$file" ]]; then
    echo "SKIP: $file not found"
    continue
  fi

  echo "-> $file  (folder: $folder_title)"
  folder_uid=$(get_or_create_folder_uid "$folder_title")

  payload=$(jq --slurpfile dash "$file" --arg fuid "$folder_uid" \
    '{dashboard: $dash[0], folderUid: $fuid, overwrite: true}')

  response=$(curl -sf -u "$AUTH" -H "Content-Type: application/json" \
    -d "$payload" "$GRAFANA_URL/api/dashboards/db")

  status=$(echo "$response" | jq -r '.status // "error"')
  if [[ "$status" == "success" ]]; then
    echo "   OK: ${GRAFANA_URL}$(echo "$response" | jq -r '.url')"
  else
    echo "   FAILED: $response"
  fi
done
