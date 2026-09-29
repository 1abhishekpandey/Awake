#!/bin/bash
# Saves the smart plug's device ID, local key and LAN address to the login Keychain,
# where Awake reads them. Nothing is written to the repo.
#
#   Scripts/set-plug-credentials.sh                  prompt for each value
#   Scripts/set-plug-credentials.sh --from-env FILE  read TUYA_DEVICE_ID, TUYA_LOCAL_KEY,
#                                                   TUYA_DEVICE_IP, TUYA_SWITCH_DP from a .env file
#
# The item is readable by any app of this user without a prompt (-A). Awake is
# ad-hoc signed, so a per-app access list would re-prompt after every rebuild.
set -euo pipefail

SERVICE="com.abhishek.awake.smart-plug"
ACCOUNT="plug"

device_id="" local_key="" host="" switch_dp="1"

if [[ "${1:-}" == "--from-env" ]]; then
    file="${2:?usage: --from-env FILE}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == \#* || "$line" != *=* ]] && continue
        name="${line%%=*}" value="${line#*=}"
        case "$name" in
            TUYA_DEVICE_ID) device_id="$value" ;;
            TUYA_LOCAL_KEY) local_key="$value" ;;
            TUYA_DEVICE_IP) host="$value" ;;
            TUYA_SWITCH_DP) switch_dp="$value" ;;
        esac
    done < "$file"
else
    read -r -p "Device ID: " device_id
    read -r -s -p "Local key (hidden): " local_key; echo
    read -r -p "Plug IP address: " host
    read -r -p "Switch DP [1]: " dp; switch_dp="${dp:-1}"
fi

[[ -n "$device_id" && -n "$host" ]] || { echo "device ID and IP are required" >&2; exit 1; }
[[ ${#local_key} -eq 16 ]] || { echo "the local key must be 16 characters" >&2; exit 1; }
[[ "$switch_dp" =~ ^[0-9]+$ ]] || { echo "switch DP must be a number" >&2; exit 1; }

json_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
json="{\"deviceId\":\"$(json_escape "$device_id")\",\"localKey\":\"$(json_escape "$local_key")\",\"host\":\"$(json_escape "$host")\",\"switchDP\":$switch_dp}"

security add-generic-password -U -A -s "$SERVICE" -a "$ACCOUNT" -l "Awake smart plug" -w "$json"
echo "Saved to the login Keychain ($SERVICE). Restart Awake to pick it up, or toggle Auto-charge."
