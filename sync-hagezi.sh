#!/usr/bin/env bash
# =============================================================================
# ControlD HaGeZi Folder Auto-Sync
# Version: 2.1.2
# Description: Syncs HaGeZi DNS blocklist folders using atomic server-side swaps.
# Requirements: bash 4.3+, curl, jq
# =============================================================================

set -o pipefail
shopt -s extglob

VERSION="2.1.2"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

CONFIG_FILE="${CONFIG_FILE:-config.toml}"
API_TOKEN="${CONTROLD_API_TOKEN:-}"
API_BASE="https://api.controld.com"

API_RETRIES=3
API_BACKOFF_BASE=2

# Persistent cache for content-based change detection
SYNC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/controld-hagezi-sync"
CACHE_VERSION="3"

# ---------------------------------------------------------------------------
# GLOBALS
# ---------------------------------------------------------------------------

declare -a PROFILE_NAMES
declare -A HAGEZI_FOLDERS PROFILE_FOLDERS _TOML_VALS
declare -A FOLDER_CHANGED

DRY_RUN=false
ACTION_LAST_UPDATED=false
SHOW_FRESHNESS=true
CHECK_UPDATES=false
NO_CACHE=false
TARGET_PROFILE=""
SUCCESS_COUNT=0
FAILED_COUNT=0
WORK_DIR=""
SUMMARY_FILE=""

API_BODY_FILE=""
API_HDR_FILE=""

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }

# ---------------------------------------------------------------------------
# API RETRY HELPER
# ---------------------------------------------------------------------------

api_call_with_retry() {
    local method="$1" url="$2" data="${3:-}"
    local retries=$API_RETRIES delay=$API_BACKOFF_BASE
    local code body retry_after
    local curl_opts=("--request" "$method" "--url" "$url" "--header" "Authorization: Bearer ${API_TOKEN}")

    if [[ -n "$data" ]]; then
        if [[ "$data" == @* ]]; then
            # File pointer payload (bypasses ARG_MAX)
            curl_opts+=("--header" "content-type: application/json" "--data-binary" "$data")
        else
            # Standard string payload
            curl_opts+=("--header" "content-type: application/json" "--data" "$data")
        fi
    fi

    if [[ -z "$API_BODY_FILE" ]]; then
        API_BODY_FILE="$WORK_DIR/api_body_$$"
        API_HDR_FILE="$WORK_DIR/api_hdr_$$"
        touch "$API_BODY_FILE" "$API_HDR_FILE"
    fi

    while true; do
        : > "$API_BODY_FILE"
        : > "$API_HDR_FILE"
        code=$(curl -s -o "$API_BODY_FILE" -D "$API_HDR_FILE" -w "%{http_code}" "${curl_opts[@]}")
        body=$(cat "$API_BODY_FILE")

        [[ "$code" =~ ^(200|201|204)$ ]] && { echo "$body"; return 0; }

        if [[ "$code" == "429" ]]; then
            retry_after=$(awk '/^[Rr]etry-[Aa]fter:/ {print $2}' "$API_HDR_FILE" | tr -d '\r\n')
            if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ ]]; then
                log "  WARN: Rate limited (429), waiting ${retry_after}s..."
                sleep "$retry_after"
            else
                log "  WARN: Rate limited (429), backing off ${delay}s..."
                sleep "$delay"
                delay=$((delay * 2))
            fi
        elif [[ "$code" == 5* ]]; then
            log "  WARN: Server error (HTTP $code), retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        else
            log "  ERROR: API call failed (HTTP $code) on $method $url"
            return 1
        fi

        retries=$(( retries - 1 ))
        [[ "$retries" -le 0 ]] && { log "  ERROR: Max retries exceeded for $method $url"; return 1; }
    done
}

# ---------------------------------------------------------------------------
# TOML PARSER (Pure Bash)
# ---------------------------------------------------------------------------

parse_toml() {
    local file="$1" line section="" key raw_val val array_buf="" inner
    local -i in_array=0
    local open_chars close_chars

    _TOML_VALS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line// /}" ]] && continue

        local out="" ch in_q=0
        local -i j line_len=${#line}
        for ((j=0; j<line_len; j++)); do
            ch="${line:$j:1}"
            [[ "$ch" == '"' ]] && ((in_q ^= 1))
            if [[ "$ch" == '#' && "$in_q" -eq 0 ]]; then
                break
            fi
            out+="$ch"
        done
        line="$out"
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^\[([^\]]+)\][[:space:]]*$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$in_array" -eq 1 ]]; then
            array_buf+="$line"
            open_chars="${array_buf//[^\[]/}"; close_chars="${array_buf//[^\]]/}"
            [[ "${#close_chars}" -ge "${#open_chars}" ]] && {
                in_array=0
                inner="${array_buf#*\[}"; inner="${array_buf%\]*}"
                _TOML_VALS["${section}|${key}"]=$(parse_toml_array "$inner")
                array_buf=""
            }
            continue
        fi

        local quoted_key_re='^[[:space:]]*"([^"]+)"[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$'
        if [[ "$line" =~ $quoted_key_re ]]; then
            key="${BASH_REMATCH[1]}"
            raw_val="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            raw_val="${BASH_REMATCH[2]}"
        else
            continue
        fi

        raw_val="${raw_val%%+([[:space:]])}"

        if [[ "$raw_val" == \[* ]]; then
            array_buf="$raw_val"
            open_chars="${array_buf//[^\[]/}"; close_chars="${array_buf//[^\]]/}"
            if [[ "${#close_chars}" -ge "${#open_chars}" ]]; then
                inner="${array_buf#*\[}"; inner="${array_buf%\]*}"
                _TOML_VALS["${section}|${key}"]=$(parse_toml_array "$inner")
                array_buf=""
            else
                in_array=1
            fi
            continue
        fi

        if [[ "$raw_val" == '"'?*'"' ]]; then
            val="${raw_val#\"}"
            val="${val%\"}"
        else
            val="$raw_val"
        fi
        _TOML_VALS["${section}|${key}"]="$val"
    done < "$file"
}

parse_toml_array() {
    local inner="$1" buf="" ch
    local -a items=()
    local -i in_quotes=0 i len=${#inner}

    for ((i=0; i<len; i++)); do
        ch="${inner:$i:1}"
        if [[ "$ch" == '"' ]]; then
            ((in_quotes ^= 1))
            [[ "$in_quotes" -eq 0 ]] && { items+=("$buf"); buf=""; }
            continue
        fi
        [[ "$in_quotes" -eq 1 ]] && buf+="$ch"
    done

    local IFS=$'\x1F'
    echo "${items[*]}"
}

toml_get() { echo "${_TOML_VALS["$1|$2"]:-}"; }

toml_get_array() {
    local raw="${_TOML_VALS["$1|$2"]:-}"
    [[ -n "$raw" ]] && tr $'\x1F' '\n' <<< "$raw"
}

load_config() {
    local cfg="$1"

    if [[ ! -f "$cfg" ]]; then
        [[ -f "${cfg}.example" ]] && { log "WARN: $cfg not found, falling back to ${cfg}.example"; cfg="${cfg}.example"; } \
        || { log "ERROR: Configuration file not found: $cfg"; exit 1; }
    fi

    parse_toml "$cfg"

    API_TOKEN="${API_TOKEN:-$(toml_get "settings" "api_token")}"
    API_TOKEN="${API_TOKEN#Bearer }"
    [[ "$(toml_get "settings" "dry_run")" == "true" ]] && DRY_RUN=true
    [[ "$(toml_get "settings" "show_freshness")" == "false" ]] && SHOW_FRESHNESS=false

    readarray -t PROFILE_NAMES <<< "$(toml_get_array "profiles" "names")"
    [[ ${#PROFILE_NAMES[@]} -eq 0 || -z "${PROFILE_NAMES[0]}" ]] && { log "ERROR: No profiles configured in $cfg"; exit 1; }

    HAGEZI_FOLDERS=(); PROFILE_FOLDERS=()
    local key
    for key in "${!_TOML_VALS[@]}"; do
        [[ "$key" == folders\|* ]] && HAGEZI_FOLDERS["${key#folders\|}"]="${_TOML_VALS[$key]}"
        [[ "$key" == profile_folders\|* ]] && PROFILE_FOLDERS["${key#profile_folders\|}"]="${_TOML_VALS[$key]}"
    done

    [[ ${#HAGEZI_FOLDERS[@]} -eq 0 ]] && { log "ERROR: No folders configured in $cfg"; exit 1; }
    [[ ${#PROFILE_FOLDERS[@]} -eq 0 ]] && { log "ERROR: No profile_folders mappings in $cfg"; exit 1; }
}

validate_config() {
    local key url has_errors=0 pname p found
    for key in "${!_TOML_VALS[@]}"; do
        [[ "$key" == folders\|* ]] || continue
        url="${_TOML_VALS[$key]}"
        [[ -z "$url" ]] && { log "ERROR: Empty URL for [$key]"; has_errors=1; continue; }
        [[ ! "$url" =~ ^https?:// ]] && { log "ERROR: Invalid URL in [$key]: $url"; has_errors=1; }
    done

    for pname in "${PROFILE_NAMES[@]}"; do
        [[ -z "${PROFILE_FOLDERS[$pname]}" ]] && log "WARN: Profile '$pname' has no [profile_folders] mapping -- will be skipped"
    done

    for key in "${!_TOML_VALS[@]}"; do
        [[ "$key" == profile_folders\|* ]] || continue
        pname="${key#profile_folders\|}"; found=0
        for p in "${PROFILE_NAMES[@]}"; do [[ "$p" == "$pname" ]] && { found=1; break; }; done
        [[ "$found" -eq 0 ]] && log "WARN: [profile_folders] has mapping for '$pname' but it's not in [profiles] names"
    done

    [[ "$has_errors" -ne 0 ]] && { log "FATAL: Configuration validation failed"; exit 1; }
}

check_deps() {
    local missing=()
    command -v curl &>/dev/null || missing+=("curl")
    command -v jq   &>/dev/null || missing+=("jq")
    [[ ${#missing[@]} -gt 0 ]] && { log "ERROR: Missing dependencies: ${missing[*]}"; exit 1; }

    if ! jq -e 'fromdateiso8601' >/dev/null 2>&1 <<< '"1970-01-01T00:00:00Z"'; then
        log "WARN: jq version lacks fromdateiso8601 (requires 1.6+). Using 'date' command fallback."
    fi
}

# ---------------------------------------------------------------------------
# CONTROL D API HELPERS
# ---------------------------------------------------------------------------

get_all_profiles() {
    local body
    body=$(api_call_with_retry "GET" "${API_BASE}/profiles") || return 1
    jq -e '.body.profiles' >/dev/null 2>&1 <<< "$body" || { log "ERROR: No profiles found" >&2; return 1; }
    echo "$body"
}

find_profile_id() { jq -r --arg n "$2" '.body.profiles[] | select(.name == $n) | .PK' 2>/dev/null <<< "$1" | head -n1; }
get_profile_groups() { api_call_with_retry "GET" "${API_BASE}/profiles/$1/groups"; }
find_group_pk_by_name() { jq -r --arg g "$2" '.body.groups[] | select(.group == $g) | .PK' 2>/dev/null <<< "$1" | head -n1; }

delete_group_by_pk() {
    [[ "$DRY_RUN" == true ]] && { log "  [DRY-RUN] Would delete folder (PK: $2)"; return 0; }
    api_call_with_retry "DELETE" "${API_BASE}/profiles/$1/groups/$2" >/dev/null
}

# ---------------------------------------------------------------------------
# TIME FORMATTING HELPERS
# ---------------------------------------------------------------------------

format_relative_time() {
    local seconds="$1" compact="${2:-false}"
    local unit value

    if (( seconds < 60 )); then
        unit="second"; value=$seconds
    elif (( seconds < 3600 )); then
        unit="minute"; value=$(( seconds / 60 ))
    elif (( seconds < 86400 )); then
        unit="hour"; value=$(( seconds / 3600 ))
    else
        unit="day"; value=$(( seconds / 86400 ))
    fi

    if [[ "$compact" == true ]]; then
        echo "${value}${unit:0:1} ago"
    else
        [[ "$value" -eq 1 ]] && echo "1 ${unit} ago" || echo "${value} ${unit}s ago"
    fi
}

format_iso_date() {
    local iso="$1"
    iso="${iso/T/ }"
    echo "${iso/Z/ UTC}"
}

# ---------------------------------------------------------------------------
# HAGEZI COMMIT FETCHER
# ---------------------------------------------------------------------------

hagezi_folder_epoch() {
    local fname="$1"
    local url filepath api_url resp code body date_str epoch
    local gh_headers=(-H "Accept: application/vnd.github.v3+json" -H "User-Agent: controld-hagezi-sync/${VERSION}")
    [[ -n "${GITHUB_TOKEN:-}" ]] && gh_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    url="${HAGEZI_FOLDERS[$fname]}"
    filepath="${url#*main/}"
    api_url="https://api.github.com/repos/hagezi/dns-blocklists/commits?path=${filepath}&per_page=1"

    resp=$(curl -s -w "\n%{http_code}" "${gh_headers[@]}" "$api_url")
    code=$(tail -n1 <<< "$resp")
    body=$(sed '$d' <<< "$resp")

    [[ "$code" != "200" ]] && return 1

    date_str=$(jq -r '.[0].commit.committer.date // empty' <<< "$body")
    [[ -z "$date_str" ]] && return 1

    epoch=$(jq -r --arg date "$date_str" '($date | sub("\\.[0-9]+"; "") | fromdateiso8601)' 2>/dev/null <<< '{}')
    if [[ -z "$epoch" || "$epoch" == "null" ]]; then
        local date_clean="${date_str%%.*}"
        epoch=$(date -d "$date_clean" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$date_clean" +%s 2>/dev/null)
    fi
    [[ -z "$epoch" || "$epoch" == "null" ]] && return 1

    echo "${epoch}|${date_str}"
}

# ---------------------------------------------------------------------------
# HAGEZI GITHUB HELPERS
# ---------------------------------------------------------------------------

download_folder_smart() {
    local url="$1" cachefile="$2" fname="$3"
    local persistent="$SYNC_CACHE/${fname// /_}.json"
    local tmpfile="$WORK_DIR/${fname// /_}_dl.json"
    local code

    code=$(curl -sL -o "$tmpfile" -w "%{http_code}" "$url")

    if [[ "$code" != "200" ]]; then
        log "  ERROR: $fname: HTTP $code"
        rm -f "$tmpfile"
        return 1
    fi

    if ! jq empty "$tmpfile" 2>/dev/null; then
        log "  ERROR: $fname: Invalid JSON received"
        rm -f "$tmpfile"
        return 1
    fi

    if [[ "$NO_CACHE" == true ]]; then
        log "  $fname: Cache disabled (--no-cache), treating as new."
        mv "$tmpfile" "$cachefile"
        return 0
    fi

    if [[ -f "$persistent" ]] && cmp -s "$tmpfile" "$persistent"; then
        log "  $fname: Not modified (cmp), using cached copy."
        cp "$persistent" "$cachefile"
        rm -f "$tmpfile"
        return 2
    fi

    if [[ "$CHECK_UPDATES" == false ]]; then
        cp "$tmpfile" "$persistent"
    fi
    mv "$tmpfile" "$cachefile"
    return 0
}

list_hagezi() {
    log "Fetching available HaGeZi ControlD folders from GitHub..."
    local api_url="https://api.github.com/repos/hagezi/dns-blocklists/contents/controld"
    local resp code body count

    resp=$(curl -s -w "\n%{http_code}" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: controld-hagezi-sync/${VERSION}" "$api_url")
    code=$(tail -n1 <<< "$resp")
    body=$(sed '$d' <<< "$resp")

    if [[ "$code" != "200" ]]; then
        [[ "$code" == "403" ]] && log "ERROR: GitHub API rate limit hit (HTTP 403)."
        [[ "$code" == "404" ]] && log "ERROR: HaGeZi repo path not found."
        [[ "$code" != "403" && "$code" != "404" ]] && log "ERROR: GitHub API returned HTTP $code"
        return 1
    fi

    count=$(jq '[.[] | select(.type == "file" and (.name | endswith(".json")))] | length' <<< "$body")
    [[ "$count" -eq 0 ]] && { log "No .json folder definitions found."; return 1; }

    log "Found $count HaGeZi folder(s) -- ready to paste into config.toml:"
    echo -e "\n[folders]\n"

    jq -r '
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
    ' <<< "$body" | sort
}

show_last_updated() {
    log "Fetching last updated dates from GitHub API..."
    local fname result epoch seconds_diff date_str

    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        result=$(hagezi_folder_epoch "$fname")
        if [[ -z "$result" ]]; then
            log "  $fname: Failed"
            continue
        fi

        epoch="${result%%|*}"
        date_str="${result#*|}"
        seconds_diff=$(( $(date +%s) - epoch ))

        log "  $fname: $(format_relative_time "$seconds_diff") ($(format_iso_date "$date_str"))"
    done
}

# ---------------------------------------------------------------------------
# CLI PARSER & MAIN
# ---------------------------------------------------------------------------

show_help() {
    cat << EOF
ControlD HaGeZi Folder Auto-Sync v${VERSION}

Usage: ./sync-hagezi.sh [OPTIONS]

Options:
  --config FILE      Use a custom configuration file (default: config.toml)
  --dry-run          Preview changes without modifying any ControlD data
  --profile NAME     Sync only the named profile (must match profiles.names)
  --list-hagezi      List available HaGeZi folders (ready for config.toml)
  --last-updated     Show the last updated date for configured folders and exit
  --no-freshness     Skip the upstream freshness report at end of sync
  --check-updates    Check if upstream folders changed, exit 0 if yes, 1 if no
  --no-cache         Ignore persistent cache, always download fresh lists
  -h, --help         Show this help message and exit

Environment:
  CONTROLD_API_TOKEN   Required if not set in config.toml. Your API Write Token.
  GITHUB_TOKEN         Optional. Authenticates GitHub API calls for freshness
                       reports (raises rate limit from 60 to 5000 req/hr).
                       Automatically available in GitHub Actions.
  CONFIG_FILE          Default configuration file path.
  SYNC_CACHE           Persistent cache directory for content comparison.
                       Default: \$HOME/.cache/controld-hagezi-sync

Examples:
  ./sync-hagezi.sh                    # Sync all profiles
  ./sync-hagezi.sh --profile Tesla    # Sync only Tesla
  ./sync-hagezi.sh --dry-run          # Preview all changes
  ./sync-hagezi.sh --list-hagezi      # List available HaGeZi sources
  ./sync-hagezi.sh --last-updated     # Check upstream updates for your rules
  ./sync-hagezi.sh --no-cache         # Force fresh download (debug)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --profile) [[ -z "${2:-}" ]] && { log "ERROR: --profile requires a profile name"; exit 1; }; TARGET_PROFILE="$2"; shift 2 ;;
            --config) [[ -z "${2:-}" ]] && { log "ERROR: --config requires a file path"; exit 1; }; CONFIG_FILE="$2"; shift 2 ;;
            --list-hagezi) check_deps; list_hagezi; exit 0 ;;
            --last-updated) ACTION_LAST_UPDATED=true; shift ;;
            --no-freshness) SHOW_FRESHNESS=false; shift ;;
            --check-updates) CHECK_UPDATES=true; shift ;;
            --no-cache) NO_CACHE=true; shift ;;
            -h|--help|-help) show_help; exit 0 ;;
            *) log "WARN: Unknown argument: $1"; shift ;;
        esac
    done
}

profile_exists() {
    local target="$1" p
    for p in "${PROFILE_NAMES[@]}"; do
        [[ "$p" == "$target" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# SUMMARY HELPER
# ---------------------------------------------------------------------------

summary_row() {
    local profile="$1" folder="$2" status="$3" rules="$4"
    [[ -z "$SUMMARY_FILE" ]] && return

    if [[ ! -f "$WORK_DIR/.summary_header_written" ]]; then
        echo "### ControlD HaGeZi Sync Report 🚀" >> "$SUMMARY_FILE"
        echo "| Profile | Folder | Status | Rules |" >> "$SUMMARY_FILE"
        echo "|---|---|---|---|" >> "$SUMMARY_FILE"
        touch "$WORK_DIR/.summary_header_written"
    fi

    echo "| $profile | $folder | $status | $rules |" >> "$SUMMARY_FILE"
}

# ---------------------------------------------------------------------------
# FRESHNESS REPORT
# ---------------------------------------------------------------------------

print_freshness_report() {
    [[ "$SHOW_FRESHNESS" != true ]] && return

    local epoch seconds_diff date_str fname result
    local -a lines=()

    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        result=$(hagezi_folder_epoch "$fname")
        if [[ -z "$result" ]]; then
            lines+=("| $fname | Failed |")
            continue
        fi
        epoch="${result%%|*}"
        date_str="${result#*|}"
        seconds_diff=$(( $(date +%s) - epoch ))
        lines+=("| $fname | $(format_relative_time "$seconds_diff" true) ($(format_iso_date "$date_str")) |")
    done

    if [[ -n "$SUMMARY_FILE" ]]; then
        {
            echo ""
            echo "---"
            echo ""
            echo "### Upstream Freshness (HaGeZi GitHub) 🕐"
            echo ""
            echo "| Folder | Last Updated |"
            echo "|---|---|"
            printf '%s\n' "${lines[@]}"
        } >> "$SUMMARY_FILE"
        return
    fi

    log ""
    log "--- Upstream Freshness (GitHub) ---"
    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        result=$(hagezi_folder_epoch "$fname")
        if [[ -z "$result" ]]; then
            log "  $fname: Failed"
            continue
        fi
        epoch="${result%%|*}"
        date_str="${result#*|}"
        seconds_diff=$(( $(date +%s) - epoch ))
        log "  $fname: $(format_relative_time "$seconds_diff") ($(format_iso_date "$date_str"))"
    done
}

# ---------------------------------------------------------------------------
# ROLLBACK HELPER
# ---------------------------------------------------------------------------

rollback_group() {
    local pid="$1" existing_pk="$2" name="$3" new_pk="$4"

    if [[ -n "$new_pk" && "$new_pk" != "null" ]]; then
        log "  Deleting partially-imported group..."
        delete_group_by_pk "$pid" "$new_pk" 2>/dev/null || true
    fi

    if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
        local rollback_payload
        rollback_payload=$(jq -n --arg n "$name" '{"name": $n}')
        if api_call_with_retry "PUT" "${API_BASE}/profiles/${pid}/groups/${existing_pk}" "$rollback_payload" >/dev/null; then
            log "  Rollback complete. Restored original group."
            return 0
        else
            log "  CRITICAL ERROR: Rollback failed. Group is stuck as '${name}_OLD'."
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# IMPORT WITH VALIDATION LOOP
# ---------------------------------------------------------------------------

import_with_validation() {
    local pid="$1" name="$2" cachefile="$3" fname="$4"
    local import_payload_file new_pk refreshed_groups
    local total_rules persistent
    local attempt=0 max_attempts=2

    import_payload_file="$WORK_DIR/import_${pid}_$$.json"
    total_rules=$(jq '.rules | length' "$cachefile")
    jq -c --arg n "$name" '{config: (. | .group.group = $n)}' "$cachefile" > "$import_payload_file"

    while (( attempt < max_attempts )); do
        attempt=$(( attempt + 1 ))
        [[ "$attempt" -gt 1 ]] && log "  Retry attempt $attempt/$max_attempts..."

        log "  Importing $total_rules rules as '$name'..."
        if ! api_call_with_retry "POST" "${API_BASE}/profiles/${pid}/groups/import" "@$import_payload_file" >/dev/null; then
            log "  ERROR: Import failed on attempt $attempt"
            break
        fi

        # Poll for group appearance with expected rule count
        log "  Polling for import completion..."
        local -i poll_count=0 max_polls=30
        while (( poll_count < max_polls )); do
            sleep 1
            poll_count=$(( poll_count + 1 ))

            refreshed_groups=$(get_profile_groups "$pid") || { sleep 1; continue; }
            new_pk=$(find_group_pk_by_name "$refreshed_groups" "$name")

            if [[ -n "$new_pk" && "$new_pk" != "null" ]]; then
                local actual_count
                actual_count=$(jq --arg pk "$new_pk" '.body.groups[] | select(.PK == ($pk | tonumber)) | .count' <<< "$refreshed_groups")

                if [[ -n "$actual_count" && "$actual_count" != "null" && "$actual_count" -gt 0 ]]; then
                    if [[ "$actual_count" -eq "$total_rules" ]]; then
                        log "  New group imported with PK: $new_pk"
                        log "  Validation passed: $actual_count/$total_rules rules match (${poll_count}s)"
                        rm -f "$import_payload_file"
                        echo "$new_pk"
                        return 0
                    else
                        log "  Waiting for rules to populate: $actual_count / $total_rules..."
                        # Continue polling — do NOT break
                    fi
                fi
            fi
        done

        # Validation failed (timeout or 0 rules), cleaning up...
        log "  Validation failed (timeout or 0 rules), cleaning up..."
        if [[ -n "$new_pk" && "$new_pk" != "null" ]]; then
            delete_group_by_pk "$pid" "$new_pk" 2>/dev/null || true
        fi

        persistent="$SYNC_CACHE/${fname// /_}.json"
        rm -f "$persistent"

        local dl_status
        download_folder_smart "${HAGEZI_FOLDERS[$fname]}" "$cachefile" "$fname"
        dl_status=$?

        if [[ "$dl_status" -ne 0 && "$dl_status" -ne 2 ]]; then
            log "  ERROR: Re-download failed"
            break
        fi

        total_rules=$(jq '.rules | length' "$cachefile")
        jq -c --arg n "$name" '{config: (. | .group.group = $n)}' "$cachefile" > "$import_payload_file"
    done

    rm -f "$import_payload_file"
    return 1
}

# ---------------------------------------------------------------------------
# SERVER-SIDE ATOMIC SYNC LOGIC
# ---------------------------------------------------------------------------

sync_folder() {
    local pname="$1" pid="$2" fname="$3" cachefile="$4" groups_json="$5"
    local existing_pk name old_name total_rules new_pk

    log "  Folder: $fname"

    [[ ! -f "$cachefile" ]] && {
        log "  ERROR: Cached file missing"
        summary_row "$pname" "$fname" "❌ Cache missing" "-"
        return 1
    }

    name=$(jq -r '.group.group' "$cachefile")
    total_rules=$(jq '.rules | length' "$cachefile")
    old_name="${name}_OLD"

    existing_pk=$(find_group_pk_by_name "$groups_json" "$name")

    # Check for stale _OLD group from a previous aborted run
    local stale_old_pk
    stale_old_pk=$(find_group_pk_by_name "$groups_json" "$old_name")
    if [[ -n "$stale_old_pk" && "$stale_old_pk" != "null" ]]; then
        log "  Found stale '$old_name' from previous run, cleaning up..."
        delete_group_by_pk "$pid" "$stale_old_pk" 2>/dev/null || true
    fi

    # Step 1: Rename existing to _OLD
    if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
        log "  Renaming existing group to '$old_name'..."
        if [[ "$DRY_RUN" == false ]]; then
            local rename_payload
            rename_payload=$(jq -n --arg n "$old_name" '{"name": $n}')
            if ! api_call_with_retry "PUT" "${API_BASE}/profiles/${pid}/groups/${existing_pk}" "$rename_payload" >/dev/null; then
                log "  ERROR: Failed to rename existing group. Aborting."
                summary_row "$pname" "$fname" "❌ Rename Failed" "-"
                return 1
            fi
        fi
    fi

    # Step 2: Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY-RUN] Would import '$name' ($total_rules rules) and delete '$old_name'"
        summary_row "$pname" "$fname" "✅ Success (Dry Run)" "$total_rules"
        return 0
    fi

    # Step 3: Import with validation loop
    new_pk=$(import_with_validation "$pid" "$name" "$cachefile" "$fname")
    if [[ -z "$new_pk" || "$new_pk" == "null" ]]; then
        log "  ERROR: Import/validation failed. Attempting rollback..."
        if rollback_group "$pid" "$existing_pk" "$name" "$new_pk"; then
            summary_row "$pname" "$fname" "❌ Validation failed (rolled back)" "-"
        else
            summary_row "$pname" "$fname" "❌ CRITICAL: Rollback failed" "-"
        fi
        return 1
    fi

    # Step 4: Success — clean up old group
    if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
        log "  Cleaning up old group..."
        delete_group_by_pk "$pid" "$existing_pk"
    fi
    summary_row "$pname" "$fname" "✅ Success" "$total_rules"
    return 0
}

# ---------------------------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------------------------

main() {
    local fname cachefile dl_status
    local skipped=0 downloaded=0 failed=0
    local pname pid PROFILE_GROUPS folder_list f status ALL_PROFILES
    local current_groups_json

    parse_args "$@"
    load_config "$CONFIG_FILE"
    validate_config
    check_deps

    if [[ "$ACTION_LAST_UPDATED" == true ]]; then
        show_last_updated
        exit 0
    fi

    if [[ -n "$TARGET_PROFILE" ]]; then
        if ! profile_exists "$TARGET_PROFILE"; then
            log "ERROR: Profile '$TARGET_PROFILE' not found"
            exit 1
        fi
    fi

    [[ -z "$API_TOKEN" ]] && { log "ERROR: API token required."; exit 1; }

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::$API_TOKEN"
        [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && SUMMARY_FILE="$GITHUB_STEP_SUMMARY"
    fi

    WORK_DIR=$(mktemp -d)
    trap '[[ -n "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"' EXIT
    mkdir -p "$WORK_DIR/cache"

    mkdir -p "$SYNC_CACHE"
    if [[ -f "$SYNC_CACHE/.version" && "$(cat "$SYNC_CACHE/.version")" != "$CACHE_VERSION" ]]; then
        log "Cache format changed (v$(cat "$SYNC_CACHE/.version") -> v$CACHE_VERSION), clearing old cache..."
        rm -rf "$SYNC_CACHE"/*
    fi
    echo "$CACHE_VERSION" > "$SYNC_CACHE/.version"

    log "========================================"
    log "ControlD Sync v${VERSION}"
    [[ "$DRY_RUN" == true ]] && log "MODE: DRY-RUN"
    [[ "$NO_CACHE" == true ]] && log "MODE: NO-CACHE"
    log "========================================"

    log "Pre-downloading HaGeZi folder data..."

    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        cachefile="$WORK_DIR/cache/${fname// /_}.json"
        download_folder_smart "${HAGEZI_FOLDERS[$fname]}" "$cachefile" "$fname"
        dl_status=$?

        if [[ $dl_status -eq 2 ]]; then
            FOLDER_CHANGED["$fname"]=false
            skipped=$(( skipped + 1 ))
        elif [[ $dl_status -eq 0 ]]; then
            log "  Cached: $fname"
            FOLDER_CHANGED["$fname"]=true
            downloaded=$(( downloaded + 1 ))
        else
            log "  FAILED: $fname"
            FOLDER_CHANGED["$fname"]=false
            failed=$(( failed + 1 ))
        fi
    done

    log "Download complete: $downloaded new, $skipped unchanged, $failed failed"

    if [[ "$CHECK_UPDATES" == true ]]; then
        print_freshness_report
        if [[ "$downloaded" -gt 0 ]]; then
            log "UPDATES AVAILABLE: $downloaded folder(s) changed upstream"
            echo "HAGEZI_UPDATES_AVAILABLE=true"
        else
            log "No updates available"
            echo "HAGEZI_UPDATES_AVAILABLE=false"
        fi
        exit 0
    fi

    ALL_PROFILES=$(get_all_profiles) || exit

    for pname in "${PROFILE_NAMES[@]}"; do
        [[ -n "$TARGET_PROFILE" && "$pname" != "$TARGET_PROFILE" ]] && continue

        pid=$(find_profile_id "$ALL_PROFILES" "$pname")
        [[ -z "$pid" || "$pid" == "null" ]] && { log ""; log "--- Profile: $pname ---"; log "  ERROR: Profile not found"; continue; }

        log ""
        log "--- Profile: $pname ($pid) ---"

        folder_list="${PROFILE_FOLDERS[$pname]}"
        [[ -z "$folder_list" ]] && { log "  WARN: No folders mapped"; continue; }

        # Fetch profile groups ONCE per profile
        current_groups_json=$(get_profile_groups "$pid") || { log "  ERROR: Failed to fetch profile groups"; continue; }

        IFS=$'\x1F' read -ra TO_SYNC <<< "$folder_list"
        for f in "${TO_SYNC[@]}"; do
            local cachefile="$WORK_DIR/cache/${f// /_}.json"
            local needs_sync=false

            if [[ "${FOLDER_CHANGED[$f]}" == "false" ]]; then
                # Cache says unchanged — but validate ControlD still has the rules
                local existing_pk
                existing_pk=$(find_group_pk_by_name "$current_groups_json" "$f")

                if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
                    local actual_count expected_count
                    expected_count=$(jq '.rules | length' "$cachefile")
                    actual_count=$(jq --arg pk "$existing_pk" '.body.groups[] | select(.PK == ($pk | tonumber)) | .count' <<< "$current_groups_json")

                    if [[ -n "$actual_count" && "$actual_count" != "null" && "$actual_count" -gt 0 && "$actual_count" -eq "$expected_count" ]]; then
                        log "  Folder: $f — unchanged upstream and validated in ControlD, skipping sync"
                        summary_row "$pname" "$f" "⏭️ Unchanged" "-"
                        continue
                    else
                        log "  Folder: $f — unchanged upstream but ControlD mismatch ($actual_count vs $expected_count), forcing sync"
                        needs_sync=true
                    fi
                else
                    log "  Folder: $f — unchanged upstream but missing in ControlD, forcing sync"
                    needs_sync=true
                fi
            else
                needs_sync=true
            fi

            if [[ "$needs_sync" == true ]]; then
                sync_folder "$pname" "$pid" "$f" "$cachefile" "$current_groups_json"
                status=$?
                if [[ "$status" -eq 0 ]]; then
                    SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
                else
                    FAILED_COUNT=$(( FAILED_COUNT + 1 ))
                fi
                # ALWAYS refresh state — sync_folder may have mutated it even on failure
                current_groups_json=$(get_profile_groups "$pid") || { log "  ERROR: Failed to refresh profile groups"; continue; }
            fi
        done
    done

    log ""
    log "========================================"
    log "Sync Complete: $SUCCESS_COUNT succeeded, $FAILED_COUNT failed"
    log "========================================"

    print_freshness_report

    exit $(( FAILED_COUNT > 0 ))
}

main "$@"
