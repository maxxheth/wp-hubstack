#!/bin/bash
# --- CrowdSec Helper Variables ---
# Adjust these to your actual Docker container names/IDs
export CROWDSEC_LAPI_CONTAINER="crowdsec"
export CROWDSEC_TRAEFIK_BOUNCER_CONTAINER="crowdsec-bouncer" # For your Traefik bouncer
export TRAEFIK_CONTAINER="traefik" # Your Traefik container
# For other bouncers (e.g., firewall), you might add:
# export CROWDSEC_FIREWALL_BOUNCER_SERVICE_NAME="crowdsec-firewall-bouncer"

# --- CrowdSec LAPI cscli Wrapper (for Docker) ---
cscli_lapi() {
    if [ -z "$CROWDSEC_LAPI_CONTAINER" ]; then
        echo "Error: CROWDSEC_LAPI_CONTAINER environment variable is not set." >&2
        echo "Please set it to your CrowdSec LAPI container name or ID." >&2
        return 1
    fi
    docker exec "$CROWDSEC_LAPI_CONTAINER" cscli "$@"
}

# --- Decision Management ---
# List decisions (pass any extra cscli decisions list flags)
cs_decisions_list() { cscli_lapi decisions list "$@"; }
# List all decisions (including old/expired for some period)
cs_decisions_list_all() { cs_decisions_list -a; }
# List decisions for a specific IP
cs_decisions_list_ip() {
    if [ -z "$1" ]; then echo "Usage: cs_decisions_list_ip <IP_ADDRESS>" >&2; return 1; fi
    cs_decisions_list --ip "$1";
}
# Ban an IP
cs_ban_ip() {
    if [ $# -lt 3 ]; then echo "Usage: cs_ban_ip <IP_ADDRESS> \"<REASON>\" \"<DURATION>\" (e.g., 1.2.3.4 \"Manual Ban\" \"24h\")" >&2; return 1; fi
    cscli_lapi decisions add --ip "$1" --reason "$2" --duration "$3";
}
# Unban an IP
cs_unban_ip() {
    if [ -z "$1" ]; then echo "Usage: cs_unban_ip <IP_ADDRESS>" >&2; return 1; fi
    cscli_lapi decisions delete --ip "$1";
}
# Unban by decision ID
cs_unban_id() {
    if [ -z "$1" ]; then echo "Usage: cs_unban_id <DECISION_ID>" >&2; return 1; fi
    cscli_lapi decisions delete --id "$1";
}

# --- Collections Management ---
cs_collections_list() { cscli_lapi collections list "$@"; }
cs_collections_install() {
    if [ -z "$1" ]; then echo "Usage: cs_collections_install <COLLECTION_NAME>" >&2; return 1; fi
    cscli_lapi collections install "$1";
}
# You might also want: cs_collections_remove(), cs_collections_upgrade()

# --- Hub Management ---
cs_hub_update() { cscli_lapi hub update; }
cs_hub_upgrade() { cscli_lapi hub upgrade "$@"; } # Pass collection name to upgrade specific, or all

# --- Status Checks ---
cs_capi_status() { cscli_lapi capi status; }
cs_bouncers_list_lapi() { cscli_lapi bouncers list; } # Bouncers registered with LAPI
cs_bouncer_add_lapi() { # For generating API key for a new bouncer
    if [ -z "$1" ]; then echo "Usage: cs_bouncer_add_lapi <BOUNCER_NAME_FOR_KEY>" >&2; return 1; fi
    cscli_lapi bouncers add "$1";
}
cs_bouncer_delete_lapi() {
    if [ -z "$1" ]; then echo "Usage: cs_bouncer_delete_lapi <BOUNCER_NAME_OR_ID>" >&2; return 1; fi
    cscli_lapi bouncers delete "$1";
}

# --- Log Viewing (Docker) ---
cs_logs_lapi() {
    if [ -z "$CROWDSEC_LAPI_CONTAINER" ]; then echo "Error: CROWDSEC_LAPI_CONTAINER not set." >&2; return 1; fi
    docker logs "$CROWDSEC_LAPI_CONTAINER" "$@";
}
cs_logs_lapi_follow() { cs_logs_lapi -f --tail 50; }

cs_logs_bouncer_traefik() {
    if [ -z "$CROWDSEC_TRAEFIK_BOUNCER_CONTAINER" ]; then echo "Error: CROWDSEC_TRAEFIK_BOUNCER_CONTAINER not set." >&2; return 1; fi
    docker logs "$CROWDSEC_TRAEFIK_BOUNCER_CONTAINER" "$@";
}
cs_logs_bouncer_traefik_follow() { cs_logs_bouncer_traefik -f --tail 50; }

# --- Restarting Services (Docker) ---
cs_lapi_restart() {
    if [ -z "$CROWDSEC_LAPI_CONTAINER" ]; then echo "Error: CROWDSEC_LAPI_CONTAINER not set." >&2; return 1; fi
    docker restart "$CROWDSEC_LAPI_CONTAINER";
}
cs_bouncer_traefik_restart() {
    if [ -z "$CROWDSEC_TRAEFIK_BOUNCER_CONTAINER" ]; then echo "Error: CROWDSEC_TRAEFIK_BOUNCER_CONTAINER not set." >&2; return 1; fi
    docker restart "$CROWDSEC_TRAEFIK_BOUNCER_CONTAINER";
}

# --- Traefik & Bouncer Interaction (Docker) ---
traefik_test_bouncer_auth() {
    if [ -z "$TRAEFIK_CONTAINER" ]; then echo "Error: TRAEFIK_CONTAINER not set." >&2; return 1; fi
    echo "Attempting to reach bouncer's forwardAuth (http://bouncer-traefik:8080/api/v1/forwardAuth) from Traefik container ($TRAEFIK_CONTAINER)..."
    # Check if wget or curl is available in Traefik container
    if docker exec "$TRAEFIK_CONTAINER" command -v wget > /dev/null; then
        docker exec "$TRAEFIK_CONTAINER" wget --spider -S http://bouncer-traefik:8080/api/v1/forwardAuth
    elif docker exec "$TRAEFIK_CONTAINER" command -v curl > /dev/null; then
        docker exec "$TRAEFIK_CONTAINER" curl -I --connect-timeout 5 http://bouncer-traefik:8080/api/v1/forwardAuth
    else
        echo "Error: Neither wget nor curl found in $TRAEFIK_CONTAINER container." >&2
        return 1
    fi
}

# --- General Docker ---
alias dps='docker ps'
alias dlogs='docker logs'
alias dexec='docker exec -it' # For interactive shells into containers
alias drestart='docker restart'