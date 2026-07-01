# ControlD HaGeZi Sync

[![GitHub stars](https://img.shields.io/github/stars/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/stargazers)
[![License](https://img.shields.io/github/license/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/blob/main/LICENSE)
[![Language](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/0x11DFE/controld-hagezi-sync/sync.yml?style=flat-square&label=CI)](https://github.com/0x11DFE/controld-hagezi-sync/actions/workflows/sync.yml)
[![Last Commit](https://img.shields.io/github/last-commit/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/commits/main)
[![Issues](https://img.shields.io/github/issues/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/issues)

> **Zero-dependency Bash with TOML power.** Atomic server-side swaps, human-readable profile names, robust rollbacks, and post-import validation.

Automatically sync HaGeZi DNS blocklists to your ControlD profiles via the ControlD API.

---

## Why this one?

| Feature | [0x11DFE/controld-hagezi-sync](https://github.com/0x11DFE/controld-hagezi-sync) | [keksiqc/ctrld-sync](https://github.com/keksiqc/ctrld-sync) | [italorgama/ctrld-hagezi-sync](https://github.com/italorgama/ctrld-hagezi-sync) | [tupcakes/controld-updater](https://github.com/tupcakes/controld-updater) |
|:---|:---|:---|:---|:---|
| **Language** | Bash (`curl` + `jq`) | Python 3 | Go (single binary) | Python + Docker |
| **Config format** | TOML (human-friendly + comments) | Hardcoded `FOLDER_URLS` in `main.py` + `.env` | `lists.txt` (one URL per line, `#` comments) | CLI args (per-run) / container env |
| **Profile targeting** | By **name** (human-readable, resolves via API) | By **ID** (supports multiple comma-separated) | By **ID** (comma-separated) | By **ID** (single per run) |
| **Per-profile folder sets** | ✅ Yes (highly flexible, different combos per profile) | ❌ No (same lists for all profiles) | ❌ No (same lists for all profiles) | ❌ No (one group per run) |
| **Dry-run** | ✅ Yes (`--dry-run`) | ❌ No | ❌ No | ❌ No |
| **Single-profile sync** | ✅ Yes (`--profile`) | ✅ Yes (via env) | ✅ Yes | ✅ Yes (CLI) |
| **Freshness report** | ✅ Yes (detailed + GitHub Actions summary) | ❌ No | ⚠️ Basic (in workflow summary) | ❌ No |
| **List discovery** | ✅ Yes (`--list-hagezi`) | ❌ No | ✅ Yes (`make list`) | ❌ No |
| **Smart change detection** | ✅ Strong (persistent content `cmp` cache + hourly checker) | ⚠️ Partial (in-memory cache per run) | ✅ Strong (workflow cache + release check) | ⚠️ Basic (always re-imports) |
| **Atomic swaps + Rollback** | ✅ **Yes (v2.0.0+)** (rename → import → cleanup or rollback) | ❌ No (delete then recreate) | ❌ No (delete then recreate) | ❌ No (delete then recreate) |
| **Post-import validation** | ✅ **Yes (v2.1.0+)** (polls rule count, retries) | ❌ No | ❌ No (basic success logging) | ❌ No |
| **Self-healing sync** | ✅ **Yes (v2.1.1+)** (validates even unchanged folders, stale cleanup) | ❌ No | ❌ No | ❌ No |
| **Large list support** | ✅ **Yes (v2.1.2+)** (file-based upload bypasses ARG_MAX) | ❌ N/A | ❌ N/A | ❌ N/A |
| **Rule handling** | ✅ Full folder import (atomic via API) | ❌ Rule-by-rule (batched, with duplicate skipping) | ✅ Folder import (batched) | ❌ Batched (after delete/recreate) |
| **Backup/restore fallback** | ✅ Yes (automatic rename-based rollback) | ❌ No | ❌ No (manual `remove.yml`) | ❌ No |
| **Zero-cost no-op runs** | ✅ Yes (early exit on unchanged content) | ❌ No (always processes) | ✅ Yes (via release/cache check) | ❌ No |
| **Hourly update checker** | ✅ Yes (`--check-updates` + cron) | ❌ No (daily workflow) | ✅ Yes (every 2h release check) | ❌ No (manual/cron per container) |
| **GitHub Actions summary** | ✅ Rich markdown + freshness + rule counts | ⚠️ Basic logs | ⚠️ Good (summary with counts) | ❌ None (workflow exists but minimal) |
| **Local CLI experience** | ✅ Excellent (many flags, help, discovery) | ⚠️ Good (Python script) | ⚠️ Good (binary + Makefile) | ⚠️ Container/CLI-focused |

**Bottom line:** If you want a lightweight, transparent script where you can define *different* blocklists for *different* family members or devices using plain profile names -- and preview changes before they go live -- this is the one.

![Star History Chart](https://api.star-history.com/svg?repos=0x11DFE/controld-hagezi-sync,keksiqc/ctrld-sync,italorgama/ctrld-hagezi-sync,tupcakes/controld-updater&type=Date)

---

## What it does

- Downloads the latest HaGeZi blocklist folder definitions (JSON)
- **Content-aware caching:** Compares downloaded JSON against a persistent cache. If unchanged, skips all ControlD API calls entirely -- zero-cost no-op syncs
- **Hourly change detection:** A separate scheduled workflow checks for upstream changes every hour and auto-triggers the sync only when needed
- **Atomic server-side swaps:** Renames the existing group to `_OLD`, imports the new definition in one shot, then deletes the old group. If import fails, deletes any partially-created new group, then rolls back by renaming `_OLD` back to the original name. Zero downtime, zero rule loss.
- **Post-import validation:** After every import, polls ControlD until the rule count matches the source. If validation fails, automatically invalidates the cache, re-downloads, and retries. If still failing, rolls back cleanly.
- **Self-healing on every run:** Even folders marked "unchanged upstream" are validated against ControlD. If a previous import silently failed (leaving 0 rules), the folder is re-synced automatically.
- **Stale group cleanup:** If a previous run was interrupted (network drop, runner kill), leftover `_OLD` groups are detected and removed before attempting renames, preventing permanent deadlock.
- **Large list support:** Imports are sent via file-based upload (`@payload.json`) instead of inline arguments, bypassing `ARG_MAX` limits for blocklists with hundreds of thousands of rules.
- Supports multiple profiles with **different folder combinations**
- Runs on a schedule or on-demand via GitHub Actions
- **Dry-run mode** to preview changes before they go live
- **Freshness report** showing when each HaGeZi list was last updated on GitHub

---

## Quick Start (GitHub Actions)

1. **Fork or use this repo** as a template.
2. **Copy the config:**

```bash
cp config.toml.example config.toml
```

3. **Edit `config.toml`** with your ControlD profile names and desired folder mappings.

> ⚠️ **TOML Parser Note:** The built-in parser is intentionally minimal. Keep configs simple: use quoted keys, single-line or multi-line arrays, and basic strings. Avoid escaped quotes inside strings, multi-line literal strings, inline tables, or date/time types. See [TOML Parser Limitations](#toml-parser-limitations) for details.

4. **Commit `config.toml`** to the repo (do **not** put your API token in it).
5. **Add your API token** as a GitHub secret:
   - Go to **Settings -> Secrets and variables -> Actions -> New repository secret**
   - Name: `CONTROLD_API_TOKEN`
   - Value: your ControlD API Write Token from controld.com/dashboard/api
6. **Run it:**
   - Go to **Actions -> Check and Sync HaGeZi to ControlD -> Run workflow**
   - Or wait for the hourly cron job

After each run, check the **Summary** tab on the workflow run page for a clean markdown table showing exactly what succeeded, what failed, and the rule counts for each profile/folder combination.

---

## Quick Start (Local / Self-hosted)

```bash
# Clone
git clone https://github.com/0x11DFE/controld-hagezi-sync.git
cd controld-hagezi-sync

# Install dependencies
# Debian/Ubuntu: sudo apt install curl jq
# macOS: brew install curl jq
# Termux: pkg install curl jq

# Copy and edit config
cp config.toml.example config.toml
vim config.toml # or nano, etc.

# Set your token (or add it to config.toml [settings])
export CONTROLD_API_TOKEN="your_token_here"

# Run
chmod +x sync-hagezi.sh
./sync-hagezi.sh
```

---

## Discover available folders

Instead of hunting through the HaGeZi repo, let the script list everything for you:

```bash
./sync-hagezi.sh --list-hagezi
```

This prints a ready-to-paste `[folders]` block for your `config.toml`, with human-readable names and raw URLs already filled in.

---

## Configuration Reference

All behavior is driven by `config.toml`.

| Section | Key | Description |
|---|---|---|
| `[settings]` | `api_token` | ControlD API Write Token. Prefer `CONTROLD_API_TOKEN` env var. |
| `[settings]` | `dry_run` | Set to `true` to preview without changes. |
| `[settings]` | `show_freshness` | Set to `false` to skip the upstream freshness report after sync. Useful in CI to avoid GitHub's unauthenticated rate limit (60 req/hr). |
| `[profiles]` | `names` | Array of exact ControlD profile names to sync. |
| `[folders]` | `"Name"` | Maps a friendly folder name to its HaGeZi JSON URL. |
| `[profile_folders]` | `` | Array of folder names to sync to that profile. |

### Example: Adding a new profile

```toml
[profiles]
names = ["Tesla", "Kids", "Friends", "Adults", "Work"]

[profile_folders]
Work = ["Badware Hoster", "Most Abused TLDs"]
```

### Example: Adding a custom folder

```toml
[folders]
"My Custom List" = "https://example.com/my-folder.json"

[profile_folders]
Tesla = ["Badware Hoster", "My Custom List"]
```

### Example: Disabling freshness report for CI

```toml
[settings]
# Uncomment to skip the upstream freshness report at the end of each sync run.
# This avoids unauthenticated GitHub API calls (60 req/hr limit) — useful for CI.
# show_freshness = false
```

---

## CLI Options

```text
./sync-hagezi.sh [OPTIONS]
 --config FILE      Use a custom configuration file (default: config.toml)
 --dry-run          Preview changes without modifying ControlD
 --profile NAME     Sync only one profile
 --list-hagezi      List available HaGeZi folders (ready for config.toml)
 --last-updated     Show the last updated date for configured folders and exit
 --check-updates    Check if upstream folders changed. Prints HAGEZI_UPDATES_AVAILABLE=true/false.
 --no-freshness     Skip the upstream freshness report at end of sync
 --no-cache         Ignore persistent cache, always download fresh lists
 -h, --help         Show help
```

### Examples

```bash
# Sync everything
./sync-hagezi.sh

# Preview changes for the "Tesla" profile
./sync-hagezi.sh --profile Tesla --dry-run

# Use a different config file
CONFIG_FILE=prod.toml ./sync-hagezi.sh

# List available HaGeZi sources
./sync-hagezi.sh --list-hagezi

# Check upstream freshness without syncing
./sync-hagezi.sh --last-updated

# Check if updates are available (parse stdout for automation)
./sync-hagezi.sh --check-updates

# Skip freshness report (CI-friendly)
./sync-hagezi.sh --no-freshness

# Force fresh download, bypass cache (debugging)
./sync-hagezi.sh --no-cache
```

---

## GitHub Action Inputs

When running manually via **Actions -> Run workflow**, you can specify:

| Input | Description |
|---|---|
| `profile` | Sync only a specific profile (leave empty for all) |
| `dry_run` | Check the box to run in preview mode |
| `no_cache` | Check the box to force fresh download and ignore cache |
| `skip_check` | Check the box to skip the update check and sync unconditionally |

After the run completes, open the **Summary** tab on the workflow run page to see:

1. **Sync Results** — a markdown table with profile, folder, status (✅/❌), and rule count
2. **Upstream Freshness** — when each HaGeZi list was last updated on GitHub (relative time + UTC)

### How the workflow works

The CI uses a two-job architecture:

1. **`check` job** — Runs `--check-updates` every hour. If upstream changed, it saves the downloaded content to cache and triggers the `sync` job.
2. **`sync` job** — Restores the cache from the `check` job (avoiding redundant downloads), then performs the actual ControlD imports.

Cache is passed between jobs using distinct keys (`hagezi-content-check-*` → `hagezi-content-sync-*`) to avoid write collisions while ensuring the `sync` job always has fresh data.

---

## Security Notes

- **Never commit `config.toml` if it contains your API token.**
- **Use GitHub Secrets** for the token in CI/CD.
- The script strips a leading `Bearer ` prefix from the token automatically if present.
- In GitHub Actions, the token is automatically masked via `::add-mask::` to prevent accidental exposure in logs.

---

## Requirements

- `bash` 4.3+
- `curl`
- `jq`

---

## How it works

1. Reads `config.toml` to know which profiles and folders to manage.
2. Fetches your ControlD profile list to resolve names to IDs.
3. Downloads each HaGeZi folder JSON once (cached per run).
4. **Content-aware change detection:** Compares freshly downloaded JSON against a persistent cache using `cmp -s` (POSIX byte comparison). If identical, the folder is marked unchanged -- but still validated against ControlD before skipping.
5. **Hourly update checker:** A cron workflow runs `--check-updates` every hour. If upstream changed, it auto-triggers the sync workflow. No wasted API calls on quiet days.
6. **Atomic server-side swap (v2.0.0):**
   - Renames the existing group to `{name}_OLD` via `PUT /groups/{pk}`
   - Imports the new group + all rules atomically via `POST /groups/import`
   - On success: deletes the `_OLD` group
   - On failure: finds and deletes any partially-created new group, then rolls back by renaming `_OLD` back to the original name
   - This eliminates the downtime window where rules were previously missing between delete and recreate.
7. **Stale group cleanup (v2.1.1):**
   - Before renaming, checks if a stale `{name}_OLD` group exists from a previous interrupted run
   - Deletes it to prevent name-collision deadlock on resumed runs
8. **Post-import validation (v2.1.0):**
   - After import, polls ControlD every second until the group appears with the expected rule count
   - If the count doesn't match after 30 seconds, the import is considered failed
   - Automatically invalidates the persistent cache, re-downloads, and retries once
   - If retry also fails, rolls back to the original group cleanly
9. **Self-healing validation (v2.1.1):**
   - Even folders marked "unchanged upstream" are validated on every sync run
   - If ControlD reports 0 rules (or a mismatch), the folder is force-synced regardless of cache state
   - This catches silent import failures from previous runs or external modifications
10. **Large list support (v2.1.2):**
    - Import payloads are written to a temp file and passed to curl as `@file.json`
    - Bypasses `ARG_MAX` (2MB Linux, 256KB macOS) for blocklists with hundreds of thousands of rules
11. **State consistency (v2.1.2):**
    - After every `sync_folder` call (success or failure), the profile's group state is refreshed
    - Prevents cascade desync when a folder sync mutates state but ultimately fails
12. Freshness timestamps are parsed with **pure jq** (`fromdateiso8601`) — identical behavior on Linux, macOS, and Termux without platform-specific `date` binaries.
13. **I/O-friendly API calls:** Reusable temp files in the retry loop eliminate `mktemp` churn on SD cards and slow storage.
14. In GitHub Actions, generates a **markdown summary** on the workflow run page with sync results and upstream freshness.
15. Prints a freshness report showing when each HaGeZi list was last updated on GitHub (local CLI only; Actions gets it in the Summary tab).

> **Note on caching:** GitHub raw URLs (`raw.githubusercontent.com`) do not support HTTP conditional requests (If-Modified-Since / ETag). The full payload is always downloaded. The cache saves ControlD API work, not bandwidth. For GitHub Actions, `actions/cache` persists the cache directory between runs.

---

## TOML Parser Limitations

The built-in parser is intentionally minimal. It handles:
- `[section]` headers
- `key = "value"` and `"Quoted Key" = "value"`
- Single-line arrays: `key = ["a", "b"]`
- Multi-line arrays
- Booleans: `true` / `false`

It does **not** support:
- Escaped quotes inside strings
- Multi-line literal strings
- Inline tables
- Date/time types

**Troubleshooting tip:** If your config parses incorrectly, simplify it. Use plain quoted strings, avoid nested quotes, and stick to single-line or simple multi-line arrays. When in doubt, run `./sync-hagezi.sh --dry-run` to validate parsing without making API calls.

---

## Known Limitations

- **No rule-level diff:** We don't compare individual rules against the existing folder. If HaGeZi's JSON hasn't changed, we still perform the atomic swap (the rename/import is fast and safe).
- **Bash TOML parser:** See [TOML Parser Limitations](#toml-parser-limitations) above.

---

## Roadmap

- [x] `--check-updates` — skip sync if HaGeZi lists haven't changed ✅ *Implemented in v1.6.4*
- [x] **Atomic server-side swaps with automatic rollback** ✅ *Implemented in v2.0.0*
- [x] **Post-import validation with auto-retry** ✅ *Implemented in v2.1.0*
- [x] **Self-healing sync for empty groups** ✅ *Implemented in v2.1.1*
- [x] **Stale group cleanup** ✅ *Implemented in v2.1.1*
- [x] **Large list support (ARG_MAX-safe)** ✅ *Implemented in v2.1.2*
- [x] **State consistency after failed syncs** ✅ *Implemented in v2.1.2*
- [ ] Rule-level diff to skip swaps when only metadata changed

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Missing dependencies` | Install `curl` and `jq`. |
| `Profile not found by name` | Ensure the profile name in `config.toml` matches exactly (case-sensitive) in ControlD. |
| `Failed to fetch profiles (HTTP 401)` | Your API token is invalid or expired. Generate a new one from the ControlD dashboard. |
| `Import failed (HTTP 4xx/5xx)` | The script retries automatically with exponential backoff. If persistent, check ControlD API status. The rollback will restore your original group. |
| `--list-hagezi shows rate limit` | GitHub unauthenticated API limit is 60/hr or 5000/hr w/ `GITHUB_TOKEN` env var. |
| `Cache format changed, clearing old cache` | The script auto-invalidates cache when the format changes. This is normal on first run after upgrade. |
| `CRITICAL ERROR: Rollback failed` | The group is stuck as `{name}_OLD`. Manually rename it back in the ControlD dashboard, or run the sync again. |
| `Validation failed — expected X rules, ControlD has 0` | ControlD processed the import asynchronously and rules weren't ready yet. The script retries automatically. If persistent, the folder may contain rules ControlD rejects (e.g. malformed wildcards). |
| `Folder unchanged upstream but ControlD mismatch` | A previous import silently failed or the group was modified externally. The script detected this and is force-syncing to heal the state. |
| `Argument list too long` | Fixed in v2.1.2+. The script now uses file-based uploads for large payloads. Upgrade if you're on an older version. |

---

## Development Note

This project was built in a single day using heavy AI assistance (primarily Kimi + Gemini) **on a mobile device** (Termux on Android), with full human oversight, testing, and refinement by the maintainer.

I have a strong Bash background (including previous projects like [PixelProps](https://github.com/Pixel-Props)) and understand every line of the script — the AI simply accelerated development dramatically.

---

**⭐ If this tool saves you time, please star the repo!** It really helps with visibility.

---

## License

MIT — see [LICENSE](LICENSE)
