#!/usr/bin/env bash
# =============================================================================
# ControlD HaGeZi Folder Auto-Sync
# Version: 1.6.4
# Description: Syncs HaGeZi DNS blocklist folders to ControlD profiles.
#              Features automatic backup/restore fallback for safe rule
#              replacements. Pure Bash. No Python. TOML-driven configuration.
# Requirements: bash 4.3+, curl, jq
# Platform: Linux, macOS, Termux (Android), GitHub Actions
# =============================================================================

set -o pipefail
shopt -s extglob

VERSION="1.6.4"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

CONFIG_FILE="${CONFIG_FILE:-config.toml}"
API_TOKEN="${CONTROLD_API_TOKEN:-}"
API_BASE="https://api.controld.com"

BATCH_SIZE=500
API_RETRIES=3
API_BACKOFF_BASE=2

# Persistent cache for content-based change detection
SYNC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/controld-hagezi-sync"
CACHE_VERSION="1"

# ---------------------------------------------------------------------------
# GLOBALS
# ---------------------------------------------------------------------------

declare -a PROFILE_NAMES
declare -A HAGEZI_FOLDERS PROFILE_FOLDERS _TOML_VALS
declare -A FOLDER_CHANGED  # Tracks changed vs unchanged per folder

DRY_RUN=false
ACTION_LAST_UPDATED=false
SHOW_FRESHNESS=true
CHECK_UPDATES=false
NO_CACHE=false
TARGET_PROFILE=""
SUCCESS_COUNT=0
FAILED_COUNT=0
TMPDIR=""
SUMMARY_FILE=""

# Reusable temp files for API calls (populated after TMPDIR is set)
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

    [[ -n "$data" ]] && curl_opts+=("--header" "content-type: application/json" "--data" "$data")

    # Initialize reusable temp files on first use (TMPDIR must be set)
    if [[ -z "$API_BODY_FILE" ]]; then
        API_BODY_FILE="$TMPDIR/api_body_$$"
        API_HDR_FILE="$TMPDIR/api_hdr_$$"
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
                inner="${array_buf#*\[}"; inner="${inner%\]*}"
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
                inner="${array_buf#*\[}"; inner="${inner%\]*}"
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
    local pid="$1" name="$2" action_status="$3" action_do="${4:-0}"
    local resp_body pk

    [[ "$DRY_RUN" == true ]] && { log "  [DRY-RUN] Would create group '$name' (do=$action_do)"; echo "DRYRUN"; return 0; }

    local json_body
    json_body=$(jq -n \
        --arg name "$name" \
        --argjson status "$action_status" \
        --argjson do_val "$action_do" \
        '{"name":$name,"action":{"do":$do_val,"status":$status}}') || {
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
    local batch_num=0 added=0

    [[ "$DRY_RUN" == true ]] && { log "  [DRY-RUN] Would add $total rules"; return 0; }
    log "  Adding $total rules in batches of $BATCH_SIZE..."

    local batches_file="$TMPDIR/batches_$$.jsonl"
    jq -c --argjson bs "$BATCH_SIZE" --argjson gid "$group_id" '
        .rules | group_by(.action.do, .action.status)[] |
        {
            do: .[0].action.do,
            status: .[0].action.status,
            hostnames: [.[].PK]
        } | . as $g |
        range(0; ($g.hostnames | length); $bs) |
        {
            do: $g.do,
            status: $g.status,
            group: $gid,
            hostnames: $g.hostnames[.:.+$bs]
        }
    ' "$file" > "$batches_file"

    local body
    while IFS= read -r body; do
        ((batch_num++))
        local count do_val status_val
        count=$(jq -r '.hostnames | length' <<< "$body")
        do_val=$(jq -r '.do' <<< "$body")
        status_val=$(jq -r '.status' <<< "$body")

        api_call_with_retry "POST" "${API_BASE}/profiles/${pid}/rules" "$body" >/dev/null || {
            log "    ERROR: Batch $batch_num failed ($count rules, do=$do_val, status=$status_val)"
            rm -f "$batches_file"
            return 1
        }
        ((added += count))
        log "    Batch $batch_num: $added/$total rules added (do=$do_val, status=$status_val, $count in this batch)"
    done < "$batches_file"

    rm -f "$batches_file"

    log "  OK: All $total rules added in $batch_num batch(es)"
    return 0
}

# ---------------------------------------------------------------------------
# GROUP BACKUP / RESTORE (Fallback)
# ---------------------------------------------------------------------------

backup_group_rules() {
    local pid="$1" group_pk="$2" output_file="$3" fallback_name="$4" source_file="$5"
    local resp_body rules_count expected_count rules_json_file

    expected_count=$(jq '.rules | length' "$source_file" 2>/dev/null || echo 0)

    # Try API backup first
    resp_body=$(api_call_with_retry "GET" "${API_BASE}/profiles/${pid}/rules/${group_pk}") || {
        log "  WARN: Backup GET failed, using source fallback"
        cp "$source_file" "$output_file"
        log "  Backup OK (source fallback): $expected_count rules saved"
        return 0
    }

    # Extract API rules to temp file
    rules_json_file="$TMPDIR/backup_rules_$$.json"
    jq '
        if .body | type == "array" then .body
        elif .body.rules | type == "array" then .body.rules
        elif .data | type == "array" then .data
        elif .data.rules | type == "array" then .data.rules
        elif .rules | type == "array" then .rules
        elif type == "array" then .
        else empty end
    ' <<< "$resp_body" > "$rules_json_file"

    rules_count=$(jq 'length' "$rules_json_file" 2>/dev/null || echo 0)

    # Try alternative endpoint if empty
    if [[ "$rules_count" -eq 0 ]]; then
        resp_body=$(api_call_with_retry "GET" "${API_BASE}/profiles/${pid}/rules?group=${group_pk}") || true
        jq '
            if .body | type == "array" then .body
            elif .body.rules | type == "array" then .body.rules
            elif .data | type == "array" then .data
            elif .data.rules | type == "array" then .data.rules
            elif .rules | type == "array" then .rules
            elif type == "array" then .
            else empty end
        ' <<< "$resp_body" > "$rules_json_file"
        rules_count=$(jq 'length' "$rules_json_file" 2>/dev/null || echo 0)
    fi

    # If API returned empty or fewer rules, merge with source JSON
    if [[ "$rules_count" -eq 0 || "$rules_count" -lt "$expected_count" ]]; then
        log "  WARN: API backup returned $rules_count/$expected_count rules, merging with source JSON"

        # Build merged backup: API rules as base, source rules filling gaps
        # Uses streaming input to avoid --slurpfile memory spike
        jq -n --arg name "$fallback_name" '
            (input // []) as $api_rules |
            (input // {}) as $src |
            ($src.rules // []) as $src_rules |
            # Create a lookup of API rules by PK
            ($api_rules | map({(.PK): .}) | add) as $api_lookup |
            # Merge: prefer API rules (preserve actual ControlD state), fill missing from source
            [
                ($src_rules[] | $api_lookup[.PK] // .)
            ] as $merged |
            ($merged[0] // {}) as $first |
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
                    $merged[] | select(.PK != null) | {PK: .PK, action: .action}
                ]
            }
        ' "$rules_json_file" "$source_file" > "$output_file" || {
            log "  WARN: Merge jq failed, using pure source fallback"
            rm -f "$rules_json_file"
            cp "$source_file" "$output_file"
            log "  Backup OK (source fallback): $expected_count rules saved"
            return 0
        }

        local merged_count
        merged_count=$(jq '.rules | length' "$output_file")
        rm -f "$rules_json_file"
        log "  Backup OK (merged): $merged_count rules saved ($rules_count from API + $(($merged_count - rules_count)) from source)"
        return 0
    fi

    # API returned complete data, use it directly
    jq --arg name "$fallback_name" '
        (.[0] // {}) as $first |
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
                .[] | select(.PK != null) | {PK: .PK, action: .action}
            ]
        }
    ' "$rules_json_file" > "$output_file" || {
        log "  WARN: Backup jq failed, using source fallback"
        rm -f "$rules_json_file"
        cp "$source_file" "$output_file"
        return 0
    }

    rm -f "$rules_json_file"
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

# --- Smart download with cmp-based change detection ---
# GitHub raw URLs (raw.githubusercontent.com) do NOT support If-Modified-Since
# or ETag conditional requests. We download to temp and byte-compare against
# persistent cache using cmp -s (POSIX, stops at first difference).
download_folder_smart() {
    local url="$1" cachefile="$2" fname="$3"
    local persistent="$SYNC_CACHE/${fname// /_}.json"
    local tmpfile="$TMPDIR/${fname// /_}_dl.json"
    local code

    # Download to temp first (GitHub raw doesn't support 304)
    code=$(curl -sL -o "$tmpfile" -w "%{http_code}" "$url")

    if [[ "$code" != "200" ]]; then
        log "  ERROR: $fname: HTTP $code"
        rm -f "$tmpfile"
        return 1
    fi

    # Validate JSON before we trust it
    if ! jq empty "$tmpfile" 2>/dev/null; then
        log "  ERROR: $fname: Invalid JSON received"
        rm -f "$tmpfile"
        return 1
    fi

    # --no-cache: always treat as changed
    if [[ "$NO_CACHE" == true ]]; then
        log "  $fname: Cache disabled (--no-cache), treating as new."
        mv "$tmpfile" "$cachefile"
        return 0
    fi

    # Compare with persistent cache from previous run
    if [[ -f "$persistent" ]] && cmp -s "$tmpfile" "$persistent"; then
        log "  $fname: Not modified (cmp), using cached copy."
        cp "$persistent" "$cachefile"
        rm -f "$tmpfile"
        return 2  # Unchanged
    fi

    # New or changed content: update both persistent and temp caches
    cp "$tmpfile" "$persistent"
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

    # Lazy header: write only when first row is about to be emitted
    if [[ ! -f "$TMPDIR/.summary_header_written" ]]; then
        echo "### ControlD HaGeZi Sync Report 🚀" >> "$SUMMARY_FILE"
        echo "| Profile | Folder | Status | Rules |" >> "$SUMMARY_FILE"
        echo "|---|---|---|---|" >> "$SUMMARY_FILE"
        touch "$TMPDIR/.summary_header_written"
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

    # GitHub Actions summary
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

    # Terminal output
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
    local existing_pk group_id backup_file name total_rules action_status restored_id action_do
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
        if backup_group_rules "$pid" "$existing_pk" "$backup_file" "$name" "$cachefile"; then
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
    action_do=$(jq -r '.group.action.do // .rules[0].action.do // 0' "$cachefile")
    group_id=$(create_group "$pid" "$name" "$action_status" "$action_do")
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

    # --- GitHub Actions setup (single place) ---
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::$API_TOKEN"
        [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && SUMMARY_FILE="$GITHUB_STEP_SUMMARY"
    fi

    # Initialize temp directory
    TMPDIR=$(mktemp -d)
    trap '[[ -n "${TMPDIR:-}" ]] && rm -rf "$TMPDIR"' EXIT
    mkdir -p "$TMPDIR/cache"

    # Cache setup
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

    # --- Download phase ---
    log "Pre-downloading HaGeZi folder data..."
    local fname cachefile dl_status
    local -i skipped=0 downloaded=0 failed=0

    for fname in "${!HAGEZI_FOLDERS[@]}"; do
        cachefile="$TMPDIR/cache/${fname// /_}.json"
        download_folder_smart "${HAGEZI_FOLDERS[$fname]}" "$cachefile" "$fname"
        dl_status=$?

        if [[ $dl_status -eq 2 ]]; then
            FOLDER_CHANGED["$fname"]=false
            ((skipped++))
        elif [[ $dl_status -eq 0 ]]; then
            log "  Cached: $fname"
            FOLDER_CHANGED["$fname"]=true
            ((downloaded++))
        else
            log "  FAILED: $fname"
            FOLDER_CHANGED["$fname"]=false
            ((failed++))
        fi
    done

    log "Download complete: $downloaded new, $skipped unchanged, $failed failed"

    # --- Check-updates mode: exit early, no ControlD API calls ---
    if [[ "$CHECK_UPDATES" == true ]]; then
        if [[ "$downloaded" -gt 0 ]]; then
            log "UPDATES AVAILABLE: $downloaded folder(s) changed upstream"
            exit 0
        else
            log "No updates available"
            exit 1
        fi
    fi

    local ALL_PROFILES
    ALL_PROFILES=$(get_all_profiles) || exit

    # --- Early exit if nothing changed ---
    if [[ "$downloaded" -eq 0 && "$failed" -eq 0 ]]; then
        log "All folders unchanged upstream. Nothing to sync."
        log "========================================"
        log "Sync Complete: 0 changes needed"
        log "========================================"
        print_freshness_report
        exit 0
    fi

    # --- Sync phase ---
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
            [[ "${FOLDER_CHANGED[$f]}" == "false" ]] && {
                log "  Folder: $f — unchanged upstream, skipping sync"
                summary_row "$pname" "$f" "⏭️ Unchanged" "-"
                continue
            }

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

    print_freshness_report

    exit $(( FAILED_COUNT > 0 ))
}

main "$@"
