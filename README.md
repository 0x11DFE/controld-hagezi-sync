#  ControlD HaGeZi Sync

[![GitHub stars](https://img.shields.io/github/stars/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/stargazers)
[![License](https://img.shields.io/github/license/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/blob/main/LICENSE)
[![Language](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/0x11DFE/controld-hagezi-sync/sync.yml?style=flat-square&label=CI)](https://github.com/0x11DFE/controld-hagezi-sync/actions/workflows/sync.yml)
[![Last Commit](https://img.shields.io/github/last-commit/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/commits/main)
[![Issues](https://img.shields.io/github/issues/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/issues)

> **Zero-dependency Bash with TOML power.** Atomic server-side swaps, human-readable profile names, robust rollbacks, post-import validation, and **ControlD drift detection**.

Automatically sync HaGeZi DNS blocklists to your ControlD profiles via the ControlD API.

---

## Why this one?

| Feature | [0x11DFE/controld-hagezi-sync](https://github.com/0x11DFE/controld-hagezi-sync) | [keksiqc/ctrld-sync](https://github.com/keksiqc/ctrld-sync) | [italorgama/ctrld-hagezi-sync](https://github.com/italorgama/ctrld-hagezi-sync) | [tupcakes/controld-updater](https://github.com/tupcakes/controld-updater) |
|:---|:---|:---|:---|:---|
| **Language** | Bash (`curl` + `jq`) | Python 3 | Go (single binary) | Python + Docker |
| **Config format** | TOML (human-friendly + comments) | Hardcoded `FOLDER_URLS` in `main.py` + `.env` | `lists.txt` (one URL/line, `#` comments) | CLI args / container env |
| **Profile targeting** | By **name** (resolves via API) | By **ID** (comma-separated) | By **ID** (comma-separated) | By **ID** (single per run) |
| **Per-profile folder sets** | ✅ Yes (flexible, different combos per profile) | ❌ No (same lists for all) | ❌ No (same lists for all) | ❌ No (one group per run) |
| **Dry-run / CLI** | ✅ Yes (`--dry-run`, `--profile`, many flags) | ❌ No | ❌ No (binary + Makefile) | ✅ Yes (CLI-focused) |
| **Smart change detection + Atomic swaps + Rollback** | ✅ **Strong** (persistent content `cmp` cache, 2-hour checker, rename/import/cleanup or full rollback; ControlD drift detection; self-healing validation on every run) | ⚠️ Partial (in-memory cache per run; delete-then-recreate) | ✅ Strong (workflow cache + release check; delete-then-recreate) | ⚠️ Basic (always re-imports; delete-then-recreate) |
| **Mirror fallback (GitHub outage)** | ✅ **Yes** (auto-fallback to `dnsbunker.org` mirror on 404; `Last-Modified` or `cmp`-based freshness; HTML directory listing for `--list-hagezi`) | ❌ No | ❌ No | ❌ No |
| **Post-import validation + Large list support** | ✅ **Yes** (polls rule counts + retries; file-based upload bypasses ARG_MAX) | ❌ No | ⚠️ Basic (success logging) | ❌ No |
| **List discovery + Freshness report** | ✅ Yes (`--list-hagezi`; detailed + GA summary) | ❌ No | ✅ Yes (`make list`; basic GA summary) | ❌ No |
| **Zero-cost no-op + 2-hour checker** | ✅ Yes (early exit on unchanged; `--check-updates` + cron) | ❌ No (always processes; daily GA) | ✅ Yes (release/cache check; every 2h) | ❌ No (manual/cron per container) |
| **GitHub Actions summary + Local experience** | ✅ Rich markdown (freshness, rule counts) + Excellent CLI | ⚠️ Basic logs + Good Python script | ⚠️ Good (counts) + Good (binary/Makefile) | ❌ Minimal + Container/CLI-focused |

**Bottom line:** If you want a lightweight, transparent script where you can define *different* blocklists for *different* family members or devices using plain profile names -- and preview changes before they go live -- with automatic resilience against GitHub outages -- this is the one.

## Star History

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="star-history-dark.svg">
  <img alt="Star history" src="star-history.svg">
</picture>

---

## What it does

- **Downloads** the latest HaGeZi blocklist folder definitions (JSON)
- **Content-aware caching** — compares downloaded JSON against a persistent cache. If unchanged, skips all ControlD API calls entirely (zero-cost no-op syncs)
- **2-hour change detection + drift detection** — checks upstream HaGeZi changes *and* ControlD group existence. Catches manual deletions even when upstream hasn't changed
- **Atomic server-side swaps** — renames existing group to `_OLD`, imports new definition in one shot, then deletes the old. If import fails, rolls back by restoring `_OLD`. Zero downtime, zero rule loss
- **Post-import validation** — polls ControlD until rule count matches the source. Retries once on mismatch; rolls back cleanly if still failing
- **Self-healing on every run** — even "unchanged" folders are validated against ControlD. If a previous import silently failed or a group was manually deleted, it is force-synced automatically
- **Stale group cleanup** — detects and removes leftover `_OLD` groups from interrupted runs before attempting renames
- **Large list support** — file-based upload bypasses `ARG_MAX` for blocklists with hundreds of thousands of rules
- **Automated cleanup** — scheduled workflow-run cleanup keeps your Actions history tidy (retains the latest run, deletes old logs/runs after 30 days or 100 runs)

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
   - Or wait for the 2-hour cron job

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

# Optional: override the fallback mirror base URL
# export HAGEZI_MIRROR_BASE="https://hagezi-mirror.dnsbunker.org/controld"

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
| `[settings]` | `hagezi_mirror_base` | Override the fallback mirror base URL. Default: `https://hagezi-mirror.dnsbunker.org/controld`. Only needed if you host your own mirror. |
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
 --check-updates    Check if upstream folders changed or ControlD state drifted.
                    Exits 0 if updates available, 1 if not.
 --no-freshness     Skip the upstream freshness report at end of sync
 --no-cache         Ignore persistent cache, always download fresh lists.
                    Also forces sync in --check-updates mode.
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

# Check if updates are available (exit 0 = yes, exit 1 = no)
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
| `no_cache` | Check the box to force fresh download and ignore cache. Also bypasses the update check. |
| `skip_check` | Check the box to skip the update check and sync unconditionally |

After the run completes, open the **Summary** tab on the workflow run page to see:

1. **Sync Results** — a markdown table with profile, folder, status (✅/❌), and rule count
2. **Upstream Freshness** — when each HaGeZi list was last updated on GitHub (relative time + UTC)

### How the workflow works

The CI uses a two-job architecture:

1. **`check` job** — Runs `--check-updates` every 2 hours. It checks two things:
   - **Upstream changes:** Has HaGeZi updated any folder JSON?
   - **ControlD drift:** Are all configured groups still present in ControlD? (Catches manual deletions.)
   If either is true, it saves the downloaded content to cache and triggers the `sync` job.
2. **`sync` job** — Restores the cache from the `check` job (avoiding redundant downloads), then performs the actual ControlD imports.

Cache is passed between jobs using distinct keys (`hagezi-content-check-*` → `hagezi-content-sync-*`) to avoid write collisions while ensuring the `sync` job always has fresh data.

> **Note:** The `check` job requires `CONTROLD_API_TOKEN` for drift detection. It is masked automatically in GitHub Actions logs.

### Automated cleanup

A separate **`Cleanup workflow runs`** workflow runs on a monthly schedule and after every completed sync (regardless of success or failure). It:

- Deletes logs from the completed sync run (successful runs only)
- Removes successful workflow runs if they exceed **100 per workflow** (keeps the latest)
- Removes runs older than **30 days** (applies to both successful and failed runs)
- Failed runs are **preserved** unless they're older than 30 days
- Always preserves the **latest run** of each workflow as a sentinel
- Supports a manual `force_delete_all` option via `workflow_dispatch`
- Includes retry logic for transient GitHub API errors during pagination

---

## Security Notes

- **Never commit `config.toml` if it contains your API token.**
- **Use GitHub Secrets** for the token in CI/CD.
- The script strips a leading `Bearer ` prefix from the token automatically if present.
- In GitHub Actions, the token is automatically masked via `::add-mask::` to prevent accidental exposure in logs.
- **v2.3.0+:** Mirror fallback — if GitHub returns 404, automatically falls back to `hagezi-mirror.dnsbunker.org`. Your GitHub token is never sent to the mirror.
- **v2.2.0+:** The token is passed to `curl` via a temporary header file instead of the command line, so it no longer appears in `ps` / `proc/*/cmdline` output on shared systems.

---

## Requirements

- `bash` 4.0+
- `curl`
- `jq`
- `cmp` (usually provided by `diffutils` or `busybox`)

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Missing dependencies` | Install `curl`, `jq`, and `cmp`. |
| `bash 4.0+ required` | Upgrade bash. macOS ships 3.2 by default — install via Homebrew (`brew install bash`). |
| `Profile not found by name` | Ensure the profile name in `config.toml` matches exactly (case-sensitive) in ControlD. |
| `Failed to fetch profiles (HTTP 401)` | Your API token is invalid or expired. Generate a new one from the ControlD dashboard. |
| `Import failed (HTTP 4xx/5xx)` | The script retries automatically with exponential backoff. If persistent, check ControlD API status. The rollback will restore your original group. |
| `--list-hagezi shows rate limit` | GitHub unauthenticated API limit is 60/hr or 5000/hr w/ `GITHUB_TOKEN` env var. |
| `Cache format changed, clearing old cache` | The script auto-invalidates cache when the format changes. This is normal on first run after upgrade. |
| `CRITICAL ERROR: Rollback failed` | The group is stuck as `{name}_OLD`. Manually rename it back in the ControlD dashboard, or run the sync again. |
| `Validation failed — expected X rules, ControlD has Y` | ControlD may dedupe or reject some rules. The script accepts a stable count after extended polling. If stable but lower, sync succeeds with a warning. If it stays at 0, the folder may contain rules ControlD rejects (e.g. malformed wildcards). |
| `Folder unchanged upstream but ControlD mismatch` | Expected when folders share rules: ControlD dedupes across folders at import, which can drain a folder (e.g. a subset list). The forced re-import repopulates it by design. Also fires if a previous import silently failed or the group was modified externally. |
| Duplicate folders after upgrading from v2.1.x or older | Older versions named groups after the JSON-internal name; v2.2.0+ uses your config key. Groups created under the old names are never touched again, so delete them once manually in the ControlD dashboard. |
| `Argument list too long` | Fixed in v2.1.2+. Uses file-based uploads for large payloads. Upgrade if on an older version. |
| `Timeout during import` | v2.2.0+: curl and job timeouts prevent indefinite hangs. Poll window scales with list size. |
| `Duplicate groups created` | Fixed in v2.2.0: breaks the profile loop when group refresh fails; CI concurrency groups prevent interleaved runs. |
| `--check-updates returns true but nothing changed upstream` | A group was manually deleted or a previous import failed silently. Drift detection (v2.2.4+) triggers sync to recreate the missing group. Check logs for `DRIFT:` messages. |
| `--no-cache still runs the check job` | v2.2.4+: `--no-cache` forces `HAGEZI_UPDATES_AVAILABLE=true` in `--check-updates` mode, and the CI workflow bypasses the check when `no_cache` is set. |
| `Most Abused TLDs: HTTP 429` | v2.2.6+: raw GitHub downloads now use `GITHUB_TOKEN` authentication (5000 req/hr instead of 60). Ensure `GITHUB_TOKEN` is available in your Actions environment. |
| `Primary returned 404, trying mirror...` | Normal during GitHub outages. The script automatically falls back to `hagezi-mirror.dnsbunker.org`. Your GitHub token is **never** sent to the mirror. |
| `--last-updated shows "now" for all folders` | The GitHub API is unavailable and the mirror doesn't send `Last-Modified`. The script falls back to `cmp`-based detection: if content changed vs cache, timestamp is "now"; if unchanged, timestamp is the cache file's mtime. |

---

## Under the Hood

<details>
<summary><b>How it works (click to expand)</b></summary>

1. Reads `config.toml` to know which profiles and folders to manage.
2. Fetches your ControlD profile list to resolve names to IDs.
3. Downloads each HaGeZi folder JSON once (cached per run).
4. **Content-aware change detection** — compares freshly downloaded JSON against a persistent cache using `cmp -s`. If identical, the folder is marked unchanged — but still validated against ControlD before skipping.
5. **2-hour update checker + drift detection** — `--check-updates` checks both upstream HaGeZi changes and ControlD group existence. If a group was manually deleted but the cache says unchanged, drift is detected and sync is triggered to recreate it.
6. **Atomic server-side swaps** — renames existing group to `{name}_OLD`, imports new definition in one shot, then deletes the old. If import fails, rolls back by restoring `{name}_OLD`. Zero downtime, zero rule loss
7. **Stale group cleanup** — before renaming, checks for leftover `{name}_OLD` from interrupted runs and deletes it to prevent name-collision deadlock.
8. **Post-import validation** — polls ControlD until rule count matches the source. If mismatch persists after scaled timeout, invalidates cache, re-downloads, and retries once. If retry fails, rolls back cleanly.
9. **Self-healing validation** — even "unchanged" folders are validated on every sync run. If the rule count doesn't exactly match the source, the folder is force-synced. This is intentional: ControlD dedupes rules shared across folders at import time, which can drain or empty a folder (e.g. a subset list vs a combined one), and the re-import pulls its rules back. A leftover `_OLD` group (interrupted swap) also forces a sync.
10. **Large list support** — import payloads are written to a temp file and passed to curl as `@file.json`, bypassing `ARG_MAX`.
11. **State consistency** — after every `sync_folder` call, the profile's group state is refreshed to prevent cascade desync.
12. **Name canonicalization** — the config key (friendly name) is used as the canonical ControlD group name, ensuring skip logic, validation lookups, and `_OLD` cleanup all reference the same name.
13. **Cache commit timing** — the persistent cache (the change-detection baseline) advances only during real sync runs, never during `--check-updates`. If any import fails, the folder's cache entry is invalidated at the end of the run so the next check re-detects the change.
14. **Schema validation** — every downloaded JSON is checked for expected schema (`group.group` string + `rules` array). Invalid payloads fail early.
15. **Stable-count validation** — for large lists or server-side deduplication, the script accepts a stable rule count (unchanged across multiple polls) even if it doesn't exactly match the source. This prevents infinite delete/import loops.
16. **Concurrency protection** — CI uses a `concurrency` group to prevent interleaved runs from deleting each other's `_OLD` backup groups.
17. **ControlD drift detection (v2.2.4)** — `--check-updates` now queries live ControlD state to verify group existence. Missing groups and leftover `_OLD` groups (interrupted swaps, v2.2.5+) are flagged as drift. Rule-count mismatch is intentionally **not** checked here because ControlD deduplicates across folders, causing expected count drops that must not trigger re-sync loops.
18. **Mirror fallback** — if GitHub returns 404 or the API is unreachable, the script transparently falls back to `hagezi-mirror.dnsbunker.org` for downloads, freshness checks (`Last-Modified` header), and `--list-hagezi` (HTML directory listing parsing). Your GitHub token is never sent to the mirror.
19. **Triple-tier freshness detection** — (1) GitHub commit API → (2) mirror `Last-Modified` header → (3) `cmp`-based detection (cache mtime if unchanged, "now" if changed or no cache). Works even when both GitHub and mirror headers are down.
20. Freshness timestamps are parsed with **pure jq** (`fromdateiso8601`) — identical behavior on Linux, macOS, and Termux without platform-specific `date` binaries.
21. **I/O-friendly API calls** — reusable temp files in the retry loop eliminate `mktemp` churn on SD cards and slow storage.
22. In GitHub Actions, generates a **markdown summary** on the workflow run page with sync results and upstream freshness.

> **Note on caching:** GitHub raw URLs do not support HTTP conditional requests (If-Modified-Since / ETag). The full payload is always downloaded. The cache saves ControlD API work, not bandwidth. For GitHub Actions, `actions/cache` persists the cache directory between runs.
> **Note on rate limits:** As of v2.2.6, raw GitHub downloads use `Authorization: token $GITHUB_TOKEN` when available, raising the limit from 60 req/hr (unauthenticated) to 5000 req/hr. This prevents HTTP 429 failures on busy runners.

</details>

<details>
<summary><b>Version history (click to expand)</b></summary>

| Version | Highlights |
|---|---|
| **v2.3.0** | Mirror fallback — automatic fallback to `hagezi-mirror.dnsbunker.org` on GitHub 404; `Last-Modified` header + `cmp`-based freshness detection; HTML directory listing parser for `--list-hagezi` during outages; `HAGEZI_MIRROR_BASE` env/config override |
| **v2.2.6** | Authenticated raw GitHub downloads using `GITHUB_TOKEN` to avoid rate limits (HTTP 429); automated workflow-run cleanup |
| **v2.2.5** | `--check-updates` no longer advances the change-detection baseline (same-count upstream updates were skipped by the sync job); interrupted swaps detected via leftover `_OLD` groups in both skip-validation and drift detection; signal traps exit cleanly |
| **v2.2.4** | ControlD drift detection in `--check-updates`; `--no-cache` forces sync in check mode; `CONTROLD_API_TOKEN` required in check job |
| **v2.2.0** | Name canonicalization; cache commit timing; schema validation; stable-count polling; concurrency protection; auth header file (token no longer in cmdline); I/O-friendly temp files |
| **v2.1.2** | Large list support (file-based upload bypasses ARG_MAX); state consistency refresh after every sync_folder |
| **v2.1.1** | Self-healing sync (validates unchanged folders); stale group cleanup |
| **v2.1.0** | Post-import validation with auto-retry and rollback |
| **v2.0.0** | Atomic server-side swaps with automatic rollback |
| **v1.6.4** | `--check-updates` for scheduled upstream change detection |

</details>

<details id="toml-parser-limitations">
<summary><b>TOML Parser Limitations (click to expand)</b></summary>

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

</details>

<details>
<summary><b>Known Limitations (click to expand)</b></summary>

- **No rule-level diff:** We don't compare individual rules against the existing folder. If HaGeZi's JSON hasn't changed, we still perform the atomic swap (the rename/import is fast and safe).
- **Bash TOML parser:** See TOML Parser Limitations above.

</details>

<details>
<summary><b>Development Note (click to expand)</b></summary>

This project was built in a single day using heavy AI assistance (primarily Kimi + Gemini) **on a mobile device** (Termux on Android), with full human oversight, testing, and refinement by the maintainer.

I have a strong Bash background (including previous projects like [PixelProps](https://github.com/Pixel-Props)) and understand every line of the script — the AI simply accelerated development dramatically.

</details>

---

**⭐ If this tool saves you time, please star the repo!** It really helps with visibility.

Found a bug or have a feature request? [Open an issue](https://github.com/0x11DFE/controld-hagezi-sync/issues/new) — contributions welcome.

---

## License

MIT — see [LICENSE](LICENSE)
