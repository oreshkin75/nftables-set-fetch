#!/bin/sh
STALE_DAYS=3
LIST_DIR="/var/lib/nftables-set-fetch"

log() {
    logger -s -p local1.info "$0: $1"
}

finish() {
    rm -f "$LOCK_FILE"
    exit 0
}

usage() {
    echo "This script fetches a list of IPs from a URL and creates two sets in nftables:"
    echo
    echo "    <set-name>4  # IPv4 addresses"
    echo "    <set-name>6  # IPv6 addresses"
    echo
    echo "Usage:"
    echo "$0 <set-name> <URL>"
}

if [ -z "$1" ] || [ -z "$2" ]; then
    usage
    exit 1
fi

log "Starting update of nftables set"
NAME="$1"
URL="$2"
LOCK_FILE=/var/lock/nftables-set-fetch-${NAME}.lock
LIST_FILE="${LIST_DIR}/nftables-set-list-${NAME}.txt"
SET4="${NAME}4"
SET6="${NAME}6"
UPDATE_LIST=0
UPDATE_SETS=0

if [ -e "$LOCK_FILE" ]; then
    log "Lock file $LOCK_FILE exists. Exiting."
    exit 1
fi
trap finish INT TERM HUP
touch "$LOCK_FILE"
test -d "$LIST_DIR" || mkdir -p "$LIST_DIR"

# Check if we need to fetch the IP list
if ! find "$LIST_FILE" -mtime $STALE_DAYS >/dev/null 2>&1; then
    log "IP list at '$LIST_FILE' is older than $STALE_DAYS days old or non-existing, downloading..."
    UPDATE_LIST=1
    UPDATE_SETS=1
else
    log "IP list at '$LIST_FILE' is fresh, skipping download."
fi

if [ -n "$FORCE_UPDATE" ]; then
    log "Forcing update of IP list"
    UPDATE_LIST=1
    UPDATE_SETS=1
fi

if [ $UPDATE_LIST -ne 0 ]; then
    if ! wget -q -O "$LIST_FILE" "$URL"; then
        log "Error downloading IP list"
        exit 1
    else
        log "Download complete."
    fi
fi

# Check if we need to update the nftables sets
if nft list set inet fw4 "$SET4" >/dev/null 2>&1; then
    if ! nft list set inet fw4 "$SET4" | grep -q element; then
        log "nftables IPv4 set is empty"
        UPDATE_SETS=1
    fi
fi

if nft list set inet fw4 "$SET6" >/dev/null 2>&1; then
    if ! nft list set inet fw4 "$SET6" | grep -q element; then
        log "nftables IPv6 set is empty"
        UPDATE_SETS=1
    fi
fi

# If sets don't exist at all, we need to update
if ! nft list set inet fw4 "$SET4" >/dev/null 2>&1 && ! nft list set inet fw4 "$SET6" >/dev/null 2>&1; then
    log "nftables sets don't exist"
    UPDATE_SETS=1
fi

if [ -n "$FORCE_UPDATE" ]; then
    log "Forcing update of nftables sets"
    UPDATE_SETS=1
fi

if [ $UPDATE_SETS -ne 0 ]; then
    log "Updating nftables sets..."

    # Check if there are IPv4 or IPv6 addresses in the list
    HAS_IPV4=0
    HAS_IPV6=0
    while read line; do
        if [ -n "$line" ]; then
            if [ ${line##*:*} ]; then
                HAS_IPV4=1
            else
                HAS_IPV6=1
            fi
        fi
        # Early exit if both types are found
        if [ $HAS_IPV4 -eq 1 ] && [ $HAS_IPV6 -eq 1 ]; then
            break
        fi
    done < "$LIST_FILE"

    # Create IPv4 set only if there are IPv4 addresses
    if [ $HAS_IPV4 -eq 1 ]; then
        if ! nft list set inet fw4 "$SET4" >/dev/null 2>&1; then
            log "Creating IPv4 set '$SET4'..."
            nft add set inet fw4 "$SET4" { type ipv4_addr \; flags interval \; auto-merge \; comment \"Set "$NAME" - IPv4\" \;} || exit 1
        fi
    else
        log "No IPv4 addresses found in list, skipping IPv4 set creation"
    fi

    # Create IPv6 set only if there are IPv6 addresses
    if [ $HAS_IPV6 -eq 1 ]; then
        if ! nft list set inet fw4 "$SET6" >/dev/null 2>&1; then
            log "Creating IPv6 set '$SET6'..."
            nft add set inet fw4 "$SET6" { type ipv6_addr \; flags interval \; auto-merge \; comment \"Set "$NAME" - IPv6\" \;} || exit 1
        fi
    else
        log "No IPv6 addresses found in list, skipping IPv6 set creation"
    fi

    # Add elements to sets
    while read line; do
        if [ -n "$line" ]; then
            if [ ${line##*:*} ]; then
                nft add element inet fw4 "$SET4" {"$line"}
            else
                nft add element inet fw4 "$SET6" {"$line"}
            fi
        fi
    done < "$LIST_FILE"
else
    log "Skipping update of nftables sets"
fi

# Build log message based on which sets were updated
if [ $UPDATE_SETS -ne 0 ]; then
    if [ $HAS_IPV4 -eq 1 ] && [ $HAS_IPV6 -eq 1 ]; then
        log "Update of nftables sets '$SET4' and '$SET6' finished successfully"
    elif [ $HAS_IPV4 -eq 1 ]; then
        log "Update of nftables set '$SET4' finished successfully"
    elif [ $HAS_IPV6 -eq 1 ]; then
        log "Update of nftables set '$SET6' finished successfully"
    fi
else
    log "No updates performed"
fi

rm -f "$LOCK_FILE"
