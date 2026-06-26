#!/usr/bin/env bash
# =============================================================================
# ControlD Hagezi Folder Auto-Sync
# Version: 1.1.0
# Description: Syncs Hagezi DNS blocklist folders to ControlD profiles.
#              Pure Bash. No Python. TOML-driven configuration.
# Requirements: bash 4.3+, curl, jq
# Platform: Linux, macOS, Termux (Android), GitHub Actions
# =============================================================================

set -o pipefail

VERSION="1.1.0"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

CONFIG_FILE="${CONFIG_FILE:-config.toml}"

# API token priority: env var > config file
API_TOKEN="${CONTROLD_API_TOKEN:-}"

# ControlD API base URL
API_BASE="https://api.controld.com"

# GitHub API for checking last commit date of Hagezi files
HAGEZI_API="https://api.github.com/repos/hagezi/dns-blocklists/commits"

# Batch size for rule insertion (ControlD API limit)
BATCH_SIZE=500

# ---------------------------------------------------------------------------
# GLOBALS (populated by load_config)
# ---------------------------------------------------------------------------

declare -a PROFILE_NAMES
declare -A HAGEZI_FOLDERS
declare -A PROFILE_FOLDERS

# CLI flags
DRY_RUN=false
TARGET_PROFILE=""

# Counters
SUCCESS_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# Temp directory
TMPDIR=""

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# ---------------------------------------------------------------------------
# TOML PARSER (Pure Bash)
# ---------------------------------------------------------------------------

# Internal associative array for parsed TOML values.
# Keys are formatted as "section|key".
# Arrays are stored as pipe-delimited strings.
declare -A _TOML_VALS

# Parse a TOML file into _TOML_VALS.
# Supports: [section], key = "val", key = ["a", "b"], key = true/false
#           quoted keys: "Key Name" = "value"
parse_toml() {
    local file="$1"
    local line section="" key raw_val val
    local -i in_array=0
    local array_buf=""

    # Clear previous state
    _TOML_VALS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip pure comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Detect section header: [section] or [section.sub]
        if [[ "$line" =~ ^\[([^\]]+)\][[:space:]]*$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        # Skip inline comments (naive: everything after unquoted #)
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue

        # Are we inside a multi-line array?
        if [[ "$in_array" -eq 1 ]]; then
            array_buf="${array_buf}${line}"
            local open close
            open=$(tr -cd '[' <<< "$array_buf" | wc -c)
            close=$(tr -cd ']' <<< "$array_buf" | wc -c)
            if [[ "$close" -ge "$open" ]]; then
                in_array=0
                local inner="${array_buf#*[}"
                inner="${inner%]*}"
                val=$(parse_toml_array "$inner")
                _TOML_VALS["${section}|${key}"]="$val"
                array_buf=""
            fi
            continue
        fi

        # Key = value (quoted key or unquoted key)
        # Try quoted key first: "Key Name" = "value"
        if [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            raw_val="${BASH_REMATCH[2]}"
        # Unquoted key: key = value
        elif [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            raw_val="${BASH_REMATCH[2]}"
        else
            continue
        fi

        # Trim trailing whitespace from raw_val
        raw_val="${raw_val%% }"
        raw_val="${raw_val%%	}"

        # Is it the start of a multi-line array?
        if [[ "$raw_val" == \[* ]]; then
            array_buf="$raw_val"
            local open close
            open=$(tr -cd '[' <<< "$array_buf" | wc -c)
            close=$(tr -cd ']' <<< "$array_buf" | wc -c)
            if [[ "$close" -ge "$open" ]]; then
                # Single-line array
                local inner="${array_buf#*[}"
                inner="${inner%]*}"
                val=$(parse_toml_array "$inner")
                _TOML_VALS["${section}|${key}"]="$val"
                array_buf=""
            else
                in_array=1
            fi
            continue
        fi

        # String value (quoted)
        if [[ "$raw_val" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
            _TOML_VALS["${section}|${key}"]="$val"
            continue
        fi

        # Boolean / bare words
        if [[ "$raw_val" == "true" || "$raw_val" == "false" ]]; then
            _TOML_VALS["${section}|${key}"]="$raw_val"
            continue
        fi

        # Number or other bare value
        _TOML_VALS["${section}|${key}"]="$raw_val"
    done < "$file"
}

# Parse a TOML array body like: "a", "b", "c"
# Returns pipe-delimited string: a|b|c
parse_toml_array() {
    local inner="$1"
    local -a items=()
    local item buf="" in_quotes=0
    local -i i len
    len=${#inner}

    for ((i=0; i<len; i++)); do
        local ch="${inner:$i:1}"
        if [[ "$ch" == '"' ]]; then
            if [[ "$in_quotes" -eq 0 ]]; then
                in_quotes=1
            else
                items+=("$buf")
                buf=""
                in_quotes=0
            fi
            continue
        fi
        if [[ "$in_quotes" -eq 1 ]]; then
            buf="${buf}${ch}"
        fi
    done

    # Join with pipe
    local result=""
    local first=1
    for item in "${items[@]}"; do
        if [[ "$first" -eq 1 ]]; then
            result="$item"
            first=0
        else
            result="${result}|${item}"
        fi
    done
    echo "$result"
}

# Get a TOML value by section and key.
# Echoes the value, or empty string if not found.
toml_get() {
    local section="$1"
    local key="$2"
    echo "${_TOML_VALS["${section}|${key}"]:-}"
}

# Get a TOML array by section and key as a newline-separated list.
toml_get_array() {
    local section="$1"
    local key="$2"
    local raw
    raw="${_TOML_VALS["${section}|${key}"]:-}"
    [[ -z "$raw" ]] && return
    IFS='|' read -ra items <<< "$raw"
    local item
    for item in "${items[@]}"; do
        echo "$item"
    done
}

# Load configuration from TOML into global arrays
load_config() {
    local cfg="$1"

    if [[ ! -f "$cfg" ]]; then
        if [[ -f "${cfg}.example" ]]; then
            log "WARN: $cfg not found, falling back to ${cfg}.example"
            cfg="${cfg}.example"
        else
            log "ERROR: Configuration file not found: $cfg"
            log "       Copy config.toml.example to config.toml and customize it."
            exit 1
        fi
    fi

    parse_toml "$cfg"

    # --- API token ---
    local cfg_token
    cfg_token=$(toml_get "settings" "api_token")
    if [[ -z "$API_TOKEN" && -n "$cfg_token" ]]; then
        API_TOKEN="$cfg_token"
    fi

    # --- Dry run from config (CLI can override) ---
    local cfg_dry
    cfg_dry=$(toml_get "settings" "dry_run")
    [[ "$cfg_dry" == "true" ]] && DRY_RUN=true

    # --- Profile names ---
    local names_raw
    names_raw=$(toml_get_array "profiles" "names")
    if [[ -z "$names_raw" ]]; then
        log "ERROR: No profiles configured in $cfg"
        exit 1
    fi
    readarray -t PROFILE_NAMES <<< "$names_raw"

    # --- Folders: read all keys in [folders] section ---
    HAGEZI_FOLDERS=()
    local key
    for key in "${!_TOML_VALS[@]}"; do
        [[ "$key" == folders\|* ]] || continue
        local fname="${key#folders\|}"
        local furl="${_TOML_VALS[$key]}"
        HAGEZI_FOLDERS["$fname"]="$furl"
    done

    if [[ ${#HAGEZI_FOLDERS[@]} -eq 0 ]]; then
        log "ERROR: No folders configured in $cfg"
        exit 1
    fi

    # --- Profile -> Folder mappings ---
    PROFILE_FOLDERS=()
    for key in "${!_TOML_VALS[@]}"; do
        [[ "$key" == profile_folders\|* ]] || continue
        local pname="${key#profile_folders\|}"
        local folders_pipe="${_TOML_VALS[$key]}"
        PROFILE_FOLDERS["$pname"]="$folders_pipe"
    done

    if [[ ${#PROFILE_FOLDERS[@]} -eq 0 ]]; then
        log "ERROR: No profile_folders mappings in $cfg"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# DEPENDENCY CHECKS
# ---------------------------------------------------------------------------

check_deps() {
    local missing=()
    command -v curl &>/dev/null || missing+=("curl")
    command -v jq   &>/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: Missing dependencies: ${missing[*]}"
        log "Install with:"
        log "  Debian/Ubuntu: sudo apt install ${missing[*]}"
        log "  macOS:         brew install ${missing[*]}"
        log "  Termux:        pkg install ${missing[*]}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# CONTROL D API HELPERS
# ---------------------------------------------------------------------------

get_all_profiles() {
    local resp code body
    resp=$(curl -s --request GET \
        --url "${API_BASE}/profiles" \
        --header "${AUTH_HEADER}" \
        --header "accept: application/json" \
        -w "\n%{http_code}")

    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" != "200" ]]; then
        log "ERROR: Failed to fetch profiles (HTTP $code)" >&2
        return 1
    fi

    if ! echo "$body" | jq -e '.body.profiles' >/dev/null 2>&1; then
        log "ERROR: No profiles found in account" >&2
        return 1
    fi

    echo "$body"
    return 0
}

find_profile_id() {
    local json="$1"
    local name="$2"
    echo "$json" | jq -r --arg n "$name" \
        '.body.profiles[] | select(.name == $n) | .PK' 2>/dev/null | head -n1
}

get_profile_groups() {
    local pid="$1"
    curl -s --request GET \
        --url "${API_BASE}/profiles/${pid}/groups" \
        --header "${AUTH_HEADER}" \
        --header "accept: application/json"
}

find_group_pk_by_name() {
    local groups_json="$1"
    local group_name="$2"
    echo "$groups_json" | jq -r --arg g "$group_name" \
        '.body.groups[] | select(.group == $g) | .PK' 2>/dev/null | head -n1
}

delete_group_by_pk() {
    local pid="$1"
    local pk="$2"
    local code

    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY-RUN] Would delete folder (PK: $pk)"
        return 0
    fi

    code=$(curl -s -o /dev/null -w "%{http_code}" --request DELETE \
        --url "${API_BASE}/profiles/${pid}/groups/${pk}" \
        --header "${AUTH_HEADER}")

    [[ "$code" == "200" || "$code" == "204" ]]
}

create_group() {
    local pid="$1"
    local name="$2"
    local action="$3"
    local resp code resp_body pk

    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY-RUN] Would create group '$name'"
        echo "DRYRUN"
        return 0
    fi

    resp=$(curl -s --request POST \
        --url "${API_BASE}/profiles/${pid}/groups" \
        --header "${AUTH_HEADER}" \
        --header "content-type: application/json" \
        --data "{\"name\":\"${name}\",\"action\":${action}}" \
        -w "\n%{http_code}")

    code=$(echo "$resp" | tail -n1)
    resp_body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "200" || "$code" == "201" ]]; then
        pk=$(echo "$resp_body" | jq -r '.body.groups[0].PK // .body.groups[0].id // .body.groups[0].pk // empty' 2>/dev/null)
        [[ -n "$pk" && "$pk" != "null" ]] && { echo "$pk"; return 0; }

        pk=$(echo "$resp_body" | jq -r '.. | objects? | select(has("PK")) | .PK // empty' 2>/dev/null | head -n1)
        [[ -n "$pk" && "$pk" != "null" ]] && { echo "$pk"; return 0; }

        log "  WARN: Could not extract PK from create response" >&2
        return 1
    fi

    if echo "$resp_body" | grep -qi "already exists"; then
        return 2
    fi

    log "  ERROR: Create group failed (HTTP $code)" >&2
    return 1
}

add_all_rules() {
    local pid="$1"
    local group_id="$2"
    local file="$3"
    local total do_val status_val
    local batch_size="$BATCH_SIZE"
    local added=0 batch_num=0 remaining current_batch_size
    local hostnames body resp code resp_body

    total=$(jq '.rules | length' "$file")
    do_val=$(jq -r '.group.action.do // .rules[0].action.do // 0' "$file")
    status_val=$(jq -r '.group.action.status // .rules[0].action.status // 1' "$file")

    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY-RUN] Would add $total rules in batches of $batch_size"
        return 0
    fi

    log "  Adding $total rules in batches of $batch_size..."

    while [[ "$added" -lt "$total" ]]; do
        batch_num=$((batch_num + 1))
        remaining=$((total - added))
        current_batch_size=$batch_size
        [[ "$remaining" -lt "$batch_size" ]] && current_batch_size=$remaining

        hostnames=$(jq --argjson start "$added" --argjson count "$current_batch_size" \
            '[.rules[$start:$start+$count][].PK]' "$file")

        body="{\"do\":${do_val},\"status\":${status_val},\"group\":${group_id},\"hostnames\":${hostnames}}"

        resp=$(curl -s --request POST \
            --url "${API_BASE}/profiles/${pid}/rules" \
            --header "${AUTH_HEADER}" \
            --header "content-type: application/json" \
            --data "$body" \
            -w "\n%{http_code}")

        code=$(echo "$resp" | tail -n1)
        resp_body=$(echo "$resp" | sed '$d')

        if [[ "$code" == "200" || "$code" == "201" ]]; then
            added=$((added + current_batch_size))
            log "    Batch $batch_num: $added/$total rules added"
        else
            log "    ERROR: Batch $batch_num failed (HTTP $code)" >&2
            return 1
        fi
    done

    log "  OK: All $total rules added"
    return 0
}

# ---------------------------------------------------------------------------
# HAGEZI DOWNLOAD HELPERS
# ---------------------------------------------------------------------------

download_folder() {
    local url="$1"
    local out="$2"
    local code

    code=$(curl -sL -o "$out" -w "%{http_code}" "$url")

    if [[ "$code" == "200" ]] && jq empty "$out" 2>/dev/null; then
        return 0
    fi

    rm -f "$out"
    return 1
}

get_github_last_updated() {
    local filename="$1"
    local api_url resp date_str formatted_date target_epoch current_epoch diff

    api_url="${HAGEZI_API}?path=controld/${filename}&page=1&per_page=1"
    resp=$(curl -sL --header "Accept: application/vnd.github.v3+json" "$api_url")
    date_str=$(echo "$resp" | jq -r '.[0].commit.committer.date // .[0].commit.author.date // "unknown"' 2>/dev/null)

    if [[ "$date_str" == "null" || -z "$date_str" || "$date_str" == "unknown" ]]; then
        echo "unknown"
        return 0
    fi

    formatted_date=$(echo "$date_str" | sed 's/T/ /; s/Z//')
    target_epoch=$(date -d "$formatted_date" +%s 2>/dev/null)

    if [[ -z "$target_epoch" ]]; then
        echo "unknown"
        return 0
    fi

    current_epoch=$(date +%s)
    diff=$((current_epoch - target_epoch))

    if [[ $diff -lt 60 ]]; then
        echo "$diff seconds ago"
    elif [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60)) minutes ago"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600)) hours ago"
    else
        echo "$((diff / 86400)) days ago"
    fi
}

# Extract filename from URL path (e.g. https://.../badware-hoster-folder.json)
get_filename_from_url() {
    local url="$1"
    echo "${url##*/}"
}

# ---------------------------------------------------------------------------
# LIST HAGEZI FOLDERS (standalone helper)
# ---------------------------------------------------------------------------

list_hagezi() {
    log "Fetching available Hagezi ControlD folders from GitHub..."

    local api_url="https://api.github.com/repos/hagezi/dns-blocklists/contents/controld"
    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: controld-hagezi-sync/${VERSION}" \
        -o "$tmpfile" \
        "$api_url")

    if [[ "$http_code" != "200" ]]; then
        rm -f "$tmpfile"
        if [[ "$http_code" == "403" ]]; then
            log "ERROR: GitHub API rate limit hit (HTTP 403)."
            log "       Set a GITHUB_TOKEN env var or wait ~1 hour."
        elif [[ "$http_code" == "404" ]]; then
            log "ERROR: Hagezi repo path not found. The directory structure may have changed."
        else
            log "ERROR: GitHub API returned HTTP $http_code"
        fi
        return 1
    fi

    local resp
    resp=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [[ -z "$resp" || "$resp" == "null" || "$resp" == *'"message"'* ]]; then
        local msg
        msg=$(echo "$resp" | jq -r '.message // "Unknown API error"' 2>/dev/null || echo "Unknown API error")
        log "ERROR: $msg"
        return 1
    fi

    local count
    count=$(echo "$resp" | jq '[.[] | select(.type == "file" and (.name | endswith(".json")))] | length')

    if [[ "$count" -eq 0 ]]; then
        log "No .json folder definitions found in hagezi/dns-blocklists/controld/"
        return 1
    fi

    echo ""
    log "Found $count Hagezi folder(s) — ready to paste into config.toml:"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "[folders]"
    echo ""

    echo "$resp" | jq -r '
        .[] | select(.type == "file" and (.name | endswith(".json"))) |
        (.name |
            if endswith("-folder.json") then rtrimstr("-folder.json")
            elif endswith(".json") then rtrimstr(".json")
            else . end |
            gsub("_"; " ") |
            gsub("-"; " ") |
            . as $raw |
            ($raw | ascii_upcase[0:1]) + ($raw[1:] | ascii_downcase)
        ) as $title |
        "\"\($title)\" = \"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/controld/\(.name)\""
    ' | sort

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    log "Tip: Copy the lines above into your config.toml under [folders]."
    log "Then map them per profile in [profile_folders], e.g.:"
    echo ""
    echo '  [profile_folders]'
    echo '  Tesla = ["Badware Hoster", "Spam Tlds"]'
    echo '  Kids  = ["Badware Hoster", "Spam Idns", "Referral Allow"]'
}

# ---------------------------------------------------------------------------
# CORE SYNC LOGIC
# ---------------------------------------------------------------------------

sync_folder() {
    local pname="$1"
    local pid="$2"
    local fname="$3"
    local cachefile="$4"
    local groups_json="$5"
    local name action existing_pk group_id status

    log "  Folder: $fname"

    if [[ -z "$cachefile" || ! -f "$cachefile" ]]; then
        log "  ERROR: Cached file missing for '$fname'"
        return 1
    fi

    name=$(jq -r '.group.group' "$cachefile")
    action=$(jq -c '.group.action' "$cachefile")

    log "  Checking for existing folder '$name'..."
    existing_pk=$(find_group_pk_by_name "$groups_json" "$name")

    if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
        log "  Found existing (PK: $existing_pk), deleting..."
        if delete_group_by_pk "$pid" "$existing_pk"; then
            log "  Deleted old folder"
        else
            log "  WARN: Delete returned non-2xx, continuing anyway..."
        fi
    else
        log "  No existing folder found"
    fi

    group_id=$(create_group "$pid" "$name" "$action")
    status=$?

    if [[ "$status" -eq 0 ]]; then
        if [[ -z "$group_id" || "$group_id" == "null" ]]; then
            log "  ERROR: Got empty group ID after creation"
            return 1
        fi
        log "  Group created (ID: $group_id)"

        if add_all_rules "$pid" "$group_id" "$cachefile"; then
            log "  OK: Folder synced with rules"
            return 0
        else
            log "  WARN: Group created but rule insertion failed"
            return 0
        fi
    elif [[ "$status" -eq 2 ]]; then
        log "  SKIPPED: Group already exists (delete may have failed)"
        return 2
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# CLI PARSER
# ---------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --profile)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR: --profile requires a profile name"
                    exit 1
                fi
                TARGET_PROFILE="$2"
                shift 2
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR: --config requires a file path"
                    exit 1
                fi
                CONFIG_FILE="$2"
                shift 2
                ;;
            --list-hagezi)
                check_deps
                list_hagezi
                exit 0
                ;;
            -h|--help)
                cat << EOF
ControlD Hagezi Folder Auto-Sync v${VERSION}

Usage: ./sync-hagezi.sh [OPTIONS]

Options:
  --config FILE    Use a custom configuration file (default: config.toml)
  --dry-run        Preview changes without modifying any ControlD data
  --profile NAME   Sync only the named profile (must match profiles.names)
  --list-hagezi    List available Hagezi folders (ready for config.toml)
  -h, --help       Show this help message and exit

Environment:
  CONTROLD_API_TOKEN   Required if not set in config.toml. Your ControlD API
                       Write Token from https://controld.com/dashboard/api
  CONFIG_FILE          Default configuration file path.

Examples:
  ./sync-hagezi.sh                    # Sync all profiles
  ./sync-hagezi.sh --profile Tesla    # Sync only Tesla
  ./sync-hagezi.sh --dry-run          # Preview all changes
  ./sync-hagezi.sh --config my.toml   # Use custom config
  ./sync-hagezi.sh --list-hagezi      # List available Hagezi sources
EOF
                exit 0
                ;;
            *)
                log "WARN: Unknown argument: $1"
                shift
                ;;
        esac
    done
}

# Validate that TARGET_PROFILE exists in PROFILE_NAMES.
# Must be called AFTER load_config.
validate_target_profile() {
    [[ -z "$TARGET_PROFILE" ]] && return 0

    local found=false
    local p
    for p in "${PROFILE_NAMES[@]}"; do
        if [[ "$p" == "$TARGET_PROFILE" ]]; then
            found=true
            break
        fi
    done

    if [[ "$found" != true ]]; then
        log "ERROR: Profile '$TARGET_PROFILE' not found in config"
        log "Available: ${PROFILE_NAMES[*]}"
        exit 1
    fi
}

# Validate that the API token is set.
validate_token() {
    if [[ -z "$API_TOKEN" ]]; then
        log "ERROR: ControlD API token is required."
        log "       Set the CONTROLD_API_TOKEN environment variable, or"
        log "       add api_token to the [settings] section of $CONFIG_FILE"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    local ALL_PROFILES pid pname cachefile status

    # --- Parse CLI flags (only flags, no config-dependent validation yet) ---
    parse_args "$@"

    # --- Load TOML configuration ---
    load_config "$CONFIG_FILE"

    # --- Now validate things that depend on loaded config ---
    validate_target_profile
    validate_token

    # Clean up token formatting
    API_TOKEN="${API_TOKEN#Bearer }"
    AUTH_HEADER="Authorization: Bearer ${API_TOKEN}"

    # --- Validate deps ---
    check_deps

    log "========================================"
    log "ControlD Hagezi Folder Sync v${VERSION}"
    [[ "$DRY_RUN" == true ]] && log "MODE: DRY-RUN (no changes will be made)"
    log "Config: $CONFIG_FILE"
    log "Profiles: ${PROFILE_NAMES[*]}"
    log "========================================"

    # --- Fetch profiles ---
    ALL_PROFILES=$(get_all_profiles)
    if [[ $? -ne 0 ]]; then
        log "FATAL: Cannot fetch profile list"
        exit 1
    fi

    # --- Setup temp workspace ---
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT
    mkdir -p "$TMPDIR/cache"

    # --- Pre-download all unique Hagezi folders ---
    log "Pre-downloading Hagezi folder data..."
    local fname
    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        cachefile="$TMPDIR/cache/${fname// /_}.json"
        if download_folder "${HAGEZI_FOLDERS[$fname]}" "$cachefile"; then
            log "  Cached: $fname"
        else
            log "  FAILED: $fname (will be skipped for all profiles)"
        fi
    done

    # --- Process each profile ---
    for pname in "${PROFILE_NAMES[@]}"; do
        if [[ -n "$TARGET_PROFILE" && "$pname" != "$TARGET_PROFILE" ]]; then
            continue
        fi

        pid=$(find_profile_id "$ALL_PROFILES" "$pname")

        if [[ -z "$pid" || "$pid" == "null" ]]; then
            log ""
            log "--- Profile: $pname ---"
            log "  ERROR: Profile not found by name"
            continue
        fi

        log ""
        log "--- Profile: $pname ($pid) ---"

        local PROFILE_GROUPS
        PROFILE_GROUPS=$(get_profile_groups "$pid")

        local folder_list
        folder_list="${PROFILE_FOLDERS[$pname]}"
        if [[ -z "$folder_list" ]]; then
            log "  WARN: No folders mapped for this profile"
            continue
        fi

        IFS='|' read -ra TO_SYNC <<< "$folder_list"
        local f
        for f in "${TO_SYNC[@]}"; do
            sync_folder "$pname" "$pid" "$f" "$TMPDIR/cache/${f// /_}.json" "$PROFILE_GROUPS"
            status=$?

            case $status in
                0) SUCCESS_COUNT=$((SUCCESS_COUNT + 1)) ;;
                2) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
                *) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
            esac
        done
    done

    # --- Summary ---
    log ""
    log "========================================"
    log "Sync Complete: $SUCCESS_COUNT created, $SKIPPED_COUNT skipped, $FAILED_COUNT failed"
    log "========================================"

    # --- Hagezi freshness report ---
    log ""
    log "--- Hagezi Folder Last Updated (GitHub) ---"
    for folder_name in "${!HAGEZI_FOLDERS[@]}"; do
        local filename
        filename=$(get_filename_from_url "${HAGEZI_FOLDERS[$folder_name]}")
        if [[ -n "$filename" ]]; then
            log "$folder_name: $(get_github_last_updated "$filename")"
        fi
    done
    log "========================================"

    if [[ $FAILED_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
