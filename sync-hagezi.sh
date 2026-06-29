#!/usr/bin/env bash
# =============================================================================
# ControlD Hagezi Folder Auto-Sync
# Version: 1.5.0
# Description: Syncs Hagezi DNS blocklist folders to ControlD profiles.
#              Features automatic backup/restore fallback for safe rule
#              replacements. Pure Bash. No Python. TOML-driven configuration.
# Requirements: bash 4.3+, curl, jq
# Platform: Linux, macOS, Termux (Android), GitHub Actions
# =============================================================================

set -o pipefail
shopt -s extglob

VERSION="1.5.0"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

CONFIG_FILE="${CONFIG_FILE:-config.toml}"
API_TOKEN="${CONTROLD_API_TOKEN:-}"
API_BASE="https://api.controld.com"

BATCH_SIZE=500
API_RETRIES=3
API_BACKOFF_BASE=2

# ---------------------------------------------------------------------------
# GLOBALS
# ---------------------------------------------------------------------------

declare -a PROFILE_NAMES
declare -A HAGEZI_FOLDERS PROFILE_FOLDERS _TOML_VALS

DRY_RUN=false
ACTION_LAST_UPDATED=false
SHOW_FRESHNESS=true
TARGET_PROFILE=""
SUCCESS_COUNT=0
FAILED_COUNT=0
TMPDIR=""
SUMMARY_FILE=""

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
    local body_file header_file code body retry_after
    local curl_opts=("--request" "$method" "--url" "$url" "--header" "Authorization: Bearer ${API_TOKEN}")

    [[ -n "$data" ]] && curl_opts+=("--header" "content-type: application/json" "--data" "$data")

    body_file=$(mktemp)
    header_file=$(mktemp)
    trap 'rm -f "$body_file" "$header_file"' RETURN

    while true; do
        code=$(curl -s -o "$body_file" -D "$header_file" -w "%{http_code}" "${curl_opts[@]}")
        body=$(cat "$body_file")

        [[ "$code" =~ ^(200|201|204)$ ]] && { echo "$body"; return 0; }

        if [[ "$code" == "429" ]]; then
            retry_after=$(awk '/^[Rr]etry-[Aa]fter:/ {print $2}' "$header_file" | tr -d '\r\n')
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
            log "  ERROR: API call failed (HTTP $code)"
            return 1
        fi

        ((retries--))
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
                inner="${array_buf#*[}"; inner="${inner%]*}"
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
                inner="${array_buf#*[}"; inner="${inner%]*}"
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

    local IFS="|"
    echo "${items[*]}"
}

toml_get() { echo "${_TOML_VALS["$1|$2"]:-}"; }

toml_get_array() {
    local raw="${_TOML_VALS["$1|$2"]:-}"
    [[ -n "$raw" ]] && tr '|' '\n' <<< "$raw"
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

create_group() {
    local pid="$1" name="$2" action_status="$3" resp_body pk

    [[ "$DRY_RUN" == true ]] && { log "  [DRY-RUN] Would create group '$name'"; echo "DRYRUN"; return 0; }

    local json_body
    json_body=$(jq -n --arg name "$name" --argjson status "$action_status" '{"name":$name,"action":{"status":$status}}') || {
        log "  ERROR: Failed to build create_group JSON"
        return 1
    }

    resp_body=$(api_call_with_retry "POST" "${API_BASE}/profiles/${pid}/groups" "$json_body") || return 1

    pk=$(jq -r '.body.groups[0].PK // .body.groups[0].id // .body.groups[0].pk // empty' 2>/dev/null <<< "$resp_body")
    [[ -n "$pk" && "$pk" != "null" ]] && { echo "$pk"; return 0; }

    pk=$(jq -r '.. | objects? | select(has("PK")) | .PK // empty' 2>/dev/null <<< "$resp_body" | head -n1)
    [[ -n "$pk" && "$pk" != "null" ]] && { echo "$pk"; return 0; }

    log "  WARN: Could not extract PK from create response"; return 1
}

add_all_rules() {
    local pid="$1" group_id="$2" file="$3" total="$4"
    local do_val status_val batch_num=0 added=0

    do_val=$(jq -r '.group.action.do // .rules[0].action.do // 0' "$file") || { log "  ERROR: Failed to read action.do from $file"; return 1; }
    status_val=$(jq -r '.group.action.status // .rules[0].action.status // 1' "$file") || { log "  ERROR: Failed to read action.status from $file"; return 1; }

    [[ "$DRY_RUN" == true ]] && { log "  [DRY-RUN] Would add $total rules"; return 0; }
    log "  Adding $total rules in batches of $BATCH_SIZE..."

    while (( added < total )); do
        ((batch_num++))
        local current_batch_size=$(( total - added < BATCH_SIZE ? total - added : BATCH_SIZE ))

        local hostnames body
        hostnames=$(jq --argjson start "$added" --argjson count "$current_batch_size" '[.rules[$start:$start+$count][].PK]' "$file")

        body=$(jq -n \
            --argjson do_val "$do_val" \
            --argjson status_val "$status_val" \
            --argjson group_id "$group_id" \
            --argjson hostnames "$hostnames" \
            '{"do":$do_val,"status":$status_val,"group":$group_id,"hostnames":$hostnames}')

        api_call_with_retry "POST" "${API_BASE}/profiles/${pid}/rules" "$body" >/dev/null || { log "    ERROR: Batch $batch_num failed"; return 1; }
        ((added += current_batch_size))
        log "    Batch $batch_num: $added/$total rules added"
    done
    log "  OK: All $total rules added"; return 0
}

# ---------------------------------------------------------------------------
# GROUP BACKUP / RESTORE (Fallback)
# ---------------------------------------------------------------------------

backup_group_rules() {
    local pid="$1" group_pk="$2" output_file="$3" fallback_name="$4"
    local resp_body rules_count success_val

    resp_body=$(api_call_with_retry "GET" "${API_BASE}/profiles/${pid}/rules/${group_pk}") || {
        log "  WARN: Backup GET failed for group PK $group_pk"
        return 1
    }

    success_val=$(jq -r '.success // "true"' 2>/dev/null <<< "$resp_body")
    [[ "$success_val" == "false" ]] && { log "  WARN: API success=false"; return 1; }

    rules_count=$(jq -r '
        if .body | type == "array" then (.body | length)
        elif .body.rules | type == "array" then (.body.rules | length // 0)
        else 0 end
    ' 2>/dev/null <<< "$resp_body")

    [[ "$rules_count" =~ ^[0-9]+$ ]] || { log "  WARN: Invalid count"; return 1; }

    jq --arg name "$fallback_name" '
        (.body | type) as $bt |
        (if $bt == "array" then (.body[0] // {}) else ((.body.rules // [])[0] // {}) end) as $first |
        {
            group: {
                group: $name,
                status: ($first.action.status // 1),
                action: {
                    do: ($first.action.do // 0),
                    status: ($first.action.status // 1)
                }
            },
            rules: [
                (if $bt == "array" then .body[] else (.body.rules // [])[] end) |
                select(.PK != null) |
                {PK: .PK, action: .action}
            ]
        }
    ' 2>/dev/null <<< "$resp_body" > "$output_file" || {
        log "  WARN: Backup jq failed"; return 1
    }

    log "  Backup OK: $rules_count rules saved"
    return 0
}

restore_group_from_backup() {
    local pid="$1" backup_file="$2"
    local name status_val total_rules group_id

    [[ ! -f "$backup_file" ]] && { log "  ERROR: Backup file missing"; return 1; }

    name=$(jq -r '.group.group' "$backup_file")
    status_val=$(jq -r '.group.action.status // .group.status // 1' "$backup_file")
    total_rules=$(jq '.rules | length' "$backup_file")

    log "  Restoring group '$name' ($total_rules rules) from backup..."

    group_id=$(create_group "$pid" "$name" "$status_val") || { log "  ERROR: Failed to recreate group"; return 1; }
    [[ -z "$group_id" || "$group_id" == "null" ]] && { log "  ERROR: Got empty group ID during restore"; return 1; }

    if [[ "$total_rules" -gt 0 ]]; then
        add_all_rules "$pid" "$group_id" "$backup_file" "$total_rules" || {
            log "  WARN: Group restored but rule re-injection failed, cleaning up..."
            delete_group_by_pk "$pid" "$group_id" 2>/dev/null || true
            return 1
        }
    fi

    log "  OK: Group restored from backup (PK: $group_id)"
    echo "$group_id"
    return 0
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
    [[ -z "$epoch" ]] && return 1

    echo "${epoch}|${date_str}"
}

# ---------------------------------------------------------------------------
# HAGEZI GITHUB HELPERS
# ---------------------------------------------------------------------------

download_folder() {
    [[ "$(curl -sL -o "$2" -w "%{http_code}" "$1")" == "200" ]] && jq empty "$2" 2>/dev/null && return 0
    rm -f "$2"; return 1
}

list_hagezi() {
    log "Fetching available Hagezi ControlD folders from GitHub..."
    local api_url="https://api.github.com/repos/hagezi/dns-blocklists/contents/controld"
    local resp code body count

    resp=$(curl -s -w "\n%{http_code}" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: controld-hagezi-sync/${VERSION}" "$api_url")
    code=$(tail -n1 <<< "$resp")
    body=$(sed '$d' <<< "$resp")

    if [[ "$code" != "200" ]]; then
        [[ "$code" == "403" ]] && log "ERROR: GitHub API rate limit hit (HTTP 403)."
        [[ "$code" == "404" ]] && log "ERROR: Hagezi repo path not found."
        [[ "$code" != "403" && "$code" != "404" ]] && log "ERROR: GitHub API returned HTTP $code"
        return 1
    fi

    count=$(jq '[.[] | select(.type == "file" and (.name | endswith(".json")))] | length' <<< "$body")
    [[ "$count" -eq 0 ]] && { log "No .json folder definitions found."; return 1; }

    log "Found $count Hagezi folder(s) -- ready to paste into config.toml:"
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
ControlD Hagezi Folder Auto-Sync v${VERSION}

Usage: ./sync-hagezi.sh [OPTIONS]

Options:
  --config FILE      Use a custom configuration file (default: config.toml)
  --dry-run          Preview changes without modifying any ControlD data
  --profile NAME     Sync only the named profile (must match profiles.names)
  --list-hagezi      List available Hagezi folders (ready for config.toml)
  --last-updated     Show the last updated date for configured folders and exit
  --no-freshness     Skip the upstream freshness report at end of sync
  -h, --help         Show this help message and exit

Environment:
  CONTROLD_API_TOKEN   Required if not set in config.toml. Your API Write Token.
  GITHUB_TOKEN         Optional. Authenticates GitHub API calls for freshness
                       reports (raises rate limit from 60 to 5000 req/hr).
                       Automatically available in GitHub Actions.
  CONFIG_FILE          Default configuration file path.

Examples:
  ./sync-hagezi.sh                    # Sync all profiles
  ./sync-hagezi.sh --profile Tesla    # Sync only Tesla
  ./sync-hagezi.sh --dry-run          # Preview all changes
  ./sync-hagezi.sh --list-hagezi      # List available Hagezi sources
  ./sync-hagezi.sh --last-updated     # Check upstream updates for your rules
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
    [[ -n "$SUMMARY_FILE" ]] && echo "| $profile | $folder | $status | $rules |" >> "$SUMMARY_FILE"
}

# ---------------------------------------------------------------------------
# RESTORE HELPER
# ---------------------------------------------------------------------------

attempt_restore() {
    local pid="$1" backup_file="$2"
    local restored_id
    log "  Attempting restore from backup..."
    restored_id=$(restore_group_from_backup "$pid" "$backup_file")
    if [[ $? -eq 0 && -n "$restored_id" && "$restored_id" != "null" ]]; then
        log "  OK: Fallback restore complete (PK: $restored_id)"
        return 0
    else
        log "  ERROR: Fallback restore also failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SYNC WITH BACKUP/RESTORE FALLBACK
# ---------------------------------------------------------------------------

sync_folder() {
    local pname="$1" pid="$2" fname="$3" cachefile="$4" groups_json="$5"
    local existing_pk group_id backup_file name total_rules action_status restored_id
    log "  Folder: $fname"

    [[ ! -f "$cachefile" ]] && {
        log "  ERROR: Cached file missing"
        summary_row "$pname" "$fname" "❌ Cache missing" "-"
        return 1
    }

    name=$(jq -r '.group.group' "$cachefile")
    total_rules=$(jq '.rules | length' "$cachefile")

    existing_pk=$(find_group_pk_by_name "$groups_json" "$name")

    # --- BACKUP EXISTING GROUP BEFORE TOUCHING ANYTHING ---
    if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
        backup_file="$TMPDIR/backup_${existing_pk}.json"
        if backup_group_rules "$pid" "$existing_pk" "$backup_file" "$name"; then
            local backup_count
            backup_count=$(jq '.rules | length' "$backup_file" 2>/dev/null || echo 0)
            if [[ "$backup_count" -eq 0 ]]; then
                log "  WARN: Backup has 0 rules (API read-after-write inconsistency?)"
                summary_row "$pname" "$fname" "⚠️ Backup empty (0 rules)" "-"
            else
                log "  Backup ready: $backup_file"
            fi
        else
            log "  WARN: Backup failed, proceeding without fallback"
            backup_file=""
        fi
    fi
    # -------------------------------------------------------

    # Delete old group
    if [[ -n "$existing_pk" && "$existing_pk" != "null" ]]; then
        log "  Deleting old '$name' (PK: $existing_pk)..."
        delete_group_by_pk "$pid" "$existing_pk" || log "  WARN: Delete returned non-2xx"
    fi

    # Create new group
    action_status=$(jq -r '.group.action.status // .group.status // .rules[0].action.status // 1' "$cachefile")
    group_id=$(create_group "$pid" "$name" "$action_status")
    if [[ $? -ne 0 || -z "$group_id" || "$group_id" == "null" ]]; then
        log "  ERROR: Group creation failed"
        [[ -n "$backup_file" && -f "$backup_file" ]] && attempt_restore "$pid" "$backup_file"
        summary_row "$pname" "$fname" "❌ Create failed" "-"
        return 1
    fi

    log "  Group created (ID: $group_id)"

    # Inject rules
    if add_all_rules "$pid" "$group_id" "$cachefile" "$total_rules"; then
        log "  OK: Folder synced"
        [[ -n "$backup_file" && -f "$backup_file" ]] && rm -f "$backup_file"
        summary_row "$pname" "$fname" "✅ Success" "$total_rules"
        return 0
    else
        log "  WARN: Group created but rules failed, attempting restore..."
        if [[ "$DRY_RUN" != true ]]; then
            delete_group_by_pk "$pid" "$group_id" 2>/dev/null || true
        fi
        [[ -n "$backup_file" && -f "$backup_file" ]] && attempt_restore "$pid" "$backup_file"
        summary_row "$pname" "$fname" "❌ Rules failed" "-"
        return 1
    fi
}

main() {
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

    # Security: Mask the ControlD API token in GitHub Actions logs
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::$API_TOKEN"

        # QoL: Setup GitHub Actions Workflow Summary markdown table
        if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
            SUMMARY_FILE="$GITHUB_STEP_SUMMARY"
            echo "### ControlD Hagezi Sync Report 🚀" >> "$SUMMARY_FILE"
            echo "| Profile | Folder | Status | Rules |" >> "$SUMMARY_FILE"
            echo "|---|---|---|---|" >> "$SUMMARY_FILE"
        fi
    fi

    log "========================================"
    log "ControlD Sync v${VERSION}"
    [[ "$DRY_RUN" == true ]] && log "MODE: DRY-RUN"
    log "========================================"

    local ALL_PROFILES
    ALL_PROFILES=$(get_all_profiles) || exit 1

    TMPDIR=$(mktemp -d)
    trap '[[ -n "${TMPDIR:-}" ]] && rm -rf "$TMPDIR"' EXIT
    mkdir -p "$TMPDIR/cache"

    log "Pre-downloading Hagezi folder data..."
    local fname cachefile
    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        cachefile="$TMPDIR/cache/${fname// /_}.json"
        download_folder "${HAGEZI_FOLDERS[$fname]}" "$cachefile" && log "  Cached: $fname" || log "  FAILED: $fname"
    done

    local pname pid
    for pname in "${PROFILE_NAMES[@]}"; do
        [[ -n "$TARGET_PROFILE" && "$pname" != "$TARGET_PROFILE" ]] && continue
        pid=$(find_profile_id "$ALL_PROFILES" "$pname")

        [[ -z "$pid" || "$pid" == "null" ]] && { log ""; log "--- Profile: $pname ---"; log "  ERROR: Profile not found"; continue; }

        log ""
        log "--- Profile: $pname ($pid) ---"

        local PROFILE_GROUPS
        PROFILE_GROUPS=$(get_profile_groups "$pid") || { log "  ERROR: Failed to fetch profile groups"; continue; }

        local folder_list="${PROFILE_FOLDERS[$pname]}"
        [[ -z "$folder_list" ]] && { log "  WARN: No folders mapped"; continue; }

        local f
        IFS='|' read -ra TO_SYNC <<< "$folder_list"
        for f in "${TO_SYNC[@]}"; do
            sync_folder "$pname" "$pid" "$f" "$TMPDIR/cache/${f// /_}.json" "$PROFILE_GROUPS"
            local status=$?
            if [[ "$status" -eq 0 ]]; then
                ((SUCCESS_COUNT++))
            else
                ((FAILED_COUNT++))
            fi
        done
    done

    log ""
    log "========================================"
    log "Sync Complete: $SUCCESS_COUNT succeeded, $FAILED_COUNT failed"
    log "========================================"

    # Add upstream freshness to GitHub Actions summary
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" && "$SHOW_FRESHNESS" == true ]]; then
        echo "" >> "$GITHUB_STEP_SUMMARY"
        echo "---" >> "$GITHUB_STEP_SUMMARY"
        echo "" >> "$GITHUB_STEP_SUMMARY"
        echo "### Upstream Freshness (Hagezi GitHub) 🕐" >> "$GITHUB_STEP_SUMMARY"
        echo "" >> "$GITHUB_STEP_SUMMARY"
        echo "| Folder | Last Updated |" >> "$GITHUB_STEP_SUMMARY"
        echo "|---|---|" >> "$GITHUB_STEP_SUMMARY"

        local fname result epoch seconds_diff date_str

        for fname in "${!HAGEZI_FOLDERS[@]}"; do
            result=$(hagezi_folder_epoch "$fname")
            if [[ -z "$result" ]]; then
                echo "| $fname | Failed |" >> "$GITHUB_STEP_SUMMARY"
                continue
            fi

            epoch="${result%%|*}"
            date_str="${result#*|}"
            seconds_diff=$(( $(date +%s) - epoch ))
            echo "| $fname | $(format_relative_time "$seconds_diff" true) ($(format_iso_date "$date_str")) |" >> "$GITHUB_STEP_SUMMARY"
        done
    fi

    # Only print to stdout if not in Actions (summary already has it)
    if [[ "$SHOW_FRESHNESS" == true && -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
        log ""
        log "--- Upstream Freshness (GitHub) ---"
        show_last_updated
    fi

    exit $(( FAILED_COUNT > 0 ))
}

main "$@"
