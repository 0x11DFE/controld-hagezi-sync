# ControlD Hagezi Sync

[![GitHub stars](https://img.shields.io/github/stars/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/stargazers)
[![License](https://img.shields.io/github/license/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/blob/main/LICENSE)
[![Language](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/0x11DFE/controld-hagezi-sync/sync.yml?style=flat-square&label=CI)](https://github.com/0x11DFE/controld-hagezi-sync/actions/workflows/sync.yml)
[![Last Commit](https://img.shields.io/github/last-commit/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/commits/main)
[![Issues](https://img.shields.io/github/issues/0x11DFE/controld-hagezi-sync?style=flat-square)](https://github.com/0x11DFE/controld-hagezi-sync/issues)

> **Zero-dependency Bash with TOML power.** No Python virtualenvs, no Go binaries, no opaque profile IDs. Write human-readable profile names, mix-and-match folders per profile, dry-run before you push, and know exactly how fresh your blocklists are.

Automatically sync Hagezi DNS blocklists to your ControlD profiles via the ControlD API.

---

## Why this one?

| Feature                        | **0x11DFE/controld-hagezi-sync**                  | [keksiqc/ctrld-sync](https://github.com/keksiqc/ctrld-sync) | [italorgama/ctrld-hagezi-sync](https://github.com/italorgama/ctrld-hagezi-sync) | [tupcakes/controld-updater](https://github.com/tupcakes/controld-updater) |
|--------------------------------|---------------------------------------------------|-------------------------------------------------------------|---------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| **Language**                   | Bash (`curl` + `jq` only)                        | Python 3 + uv                                              | Go (single binary)                                                             | Python + Docker/Podman                                                   |
| **Config format**              | TOML (with comments)                              | Python list + `.env`                                       | `lists.txt`                                                                    | CLI args (per-run) + Kubernetes CronJob                                  |
| **Profile targeting**          | By **name** (human-readable)                      | By **ID**                                                  | By **ID**                                                                      | By **ID**                                                                |
| **Per-profile folder sets**    | :white_check_mark: Yes (different per profile)   | :x: Same folders for all                                   | :x: Same folders for all                                                       | :x: One list per run (single folder)                                    |
| **Dry-run**                    | :white_check_mark: Yes (`--dry-run`)             | :x: No                                                     | :x: No                                                                         | :x: No                                                                   |
| **Single-profile sync**        | :white_check_mark: Yes (`--profile`)             | :x: No                                                     | :x: No                                                                         | :white_check_mark: Yes (inherently single-run)                           |
| **Freshness report**           | :white_check_mark: Yes                            | :x: No                                                     | :x: No                                                                         | :x: No                                                                   |
| **List discovery**             | :white_check_mark: `--list-hagezi`               | :x: Manual/hardcoded                                       | :white_check_mark: `make list`                                                 | Manual (specify JSON URL)                                                |
| **Smart triggering**           | Daily + manual                                    | Daily + manual                                             | Every 2h + **change detection**                                                | Daily Kubernetes CronJob (per list)                                      |
| **Local CLI experience**       | Native Bash script (excellent)                    | Python script                                              | Go binary                                                                      | Python script + Docker container                                         |
| **Setup simplicity (Actions)** | Edit TOML + commit + secret                       | Edit Python file + secrets                                 | **Easiest**: Just add secrets (no config commit)                               | CLI args / Kubernetes manifests                                          |
| **Rule batching**              | 500 rules (with retries)                          | 500 rules (with retries)                                   | 500 rules (with retries)                                                       | Deletes + re-imports (batching assumed)                                  |
| **Backup/restore fallback**    | :white_check_mark: Automatic                      | :x: No                                                     | :x: No                                                                         | :x: No                                                                   |
| **GitHub Actions summary**     | :white_check_mark: Markdown table + freshness     | :x: No                                                     | :x: No                                                                         | :x: No                                                                   |

**Bottom line:** If you want a lightweight, transparent script where you can define *different* blocklists for *different* family members or devices using plain profile names -- and preview changes before they go live -- this is the one.

![Star History Chart](https://api.star-history.com/svg?repos=0x11DFE/controld-hagezi-sync,keksiqc/ctrld-sync,italorgama/ctrld-hagezi-sync,tupcakes/controld-updater&type=Date)

---

## What it does

- Downloads the latest Hagezi blocklist folder definitions (JSON)
- Backs up existing folders before deletion (automatic fallback on failure)
- Deletes existing folders in your ControlD profiles (by PK)
- Recreates them with fresh rules, batched in groups of 500
- Supports multiple profiles with **different folder combinations**
- Runs on a schedule or on-demand via GitHub Actions
- **Dry-run mode** to preview changes before they go live
- **Freshness report** showing when each Hagezi list was last updated on GitHub

---

## Quick Start (GitHub Actions)

1. **Fork or use this repo** as a template.
2. **Copy the config:**

```bash
cp config.toml.example config.toml
```

3. **Edit `config.toml`** with your ControlD profile names and desired folder mappings.
4. **Commit `config.toml`** to the repo (do **not** put your API token in it).
5. **Add your API token** as a GitHub secret:
   - Go to **Settings -> Secrets and variables -> Actions -> New repository secret**
   - Name: `CONTROLD_API_TOKEN`
   - Value: your ControlD API Write Token from controld.com/dashboard/api
6. **Run it:**
   - Go to **Actions -> Sync Hagezi to ControlD -> Run workflow**
   - Or wait for the daily 03:00 UTC cron job

After each run, check the **Summary** tab on the workflow run page for a clean markdown table showing exactly what succeeded, what failed, and the rule counts for each profile/folder combination.

---

## Quick Start (Local / Self-hosted)

```bash
# Clone
git clone https://github.com/0x11DFE/controld-hagezi-sync.git
cd controld-hagezi-sync

# Install dependencies
# Debian/Ubuntu: sudo apt install curl jq
# macOS:          brew install curl jq
# Termux:         pkg install curl jq

# Copy and edit config
cp config.toml.example config.toml
vim config.toml   # or nano, etc.

# Set your token (or add it to config.toml [settings])
export CONTROLD_API_TOKEN="your_token_here"

# Run
chmod +x sync-hagezi.sh
./sync-hagezi.sh
```

---

## Discover available folders

Instead of hunting through the Hagezi repo, let the script list everything for you:

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
| `[folders]` | `"Name"` | Maps a friendly folder name to its Hagezi JSON URL. |
| `[profile_folders]` | `<profile>` | Array of folder names to sync to that profile. |

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
  --list-hagezi      List available Hagezi folders (ready for config.toml)
  --last-updated     Show the last updated date for configured folders and exit
  --no-freshness     Skip the upstream freshness report at end of sync
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

# List available Hagezi sources
./sync-hagezi.sh --list-hagezi

# Check upstream freshness without syncing
./sync-hagezi.sh --last-updated

# Skip freshness report (CI-friendly)
./sync-hagezi.sh --no-freshness
```

---

## GitHub Action Inputs

When running manually via **Actions -> Run workflow**, you can specify:

| Input | Description |
|---|---|
| `profile` | Sync only a specific profile (leave empty for all) |
| `dry_run` | Check the box to run in preview mode |

After the run completes, open the **Summary** tab on the workflow run page to see:

1. **Sync Results** — a markdown table with profile, folder, status (✅/❌), and rule count
2. **Upstream Freshness** — when each Hagezi list was last updated on GitHub (relative time + UTC)

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
3. Downloads each Hagezi folder JSON once (cached per run).
4. For each profile, **backs up existing folders** before deletion.
5. Deletes existing folders by PK, then recreates them with fresh rules.
6. Rules are inserted in batches of 500 to stay within API limits.
7. If rule injection fails, **automatically restores the original folder from backup**.
8. In GitHub Actions, generates a **markdown summary** on the workflow run page with sync results and upstream freshness
9. Prints a freshness report showing when each Hagezi list was last updated on GitHub (local CLI only; Actions gets it in the Summary tab)

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

Keep your config simple and these limitations will not affect you.

---

## Known Limitations

- **Destructive sync:** Folders are deleted and recreated. An interrupted sync may leave a profile without that folder's rules until the next run.
- **No rule-level diff:** We don't compare individual rules against the existing folder. If Hagezi's JSON hasn't changed, we still delete and recreate.
- **Bash TOML parser:** See [TOML Parser Limitations](#toml-parser-limitations) above.

---

## Roadmap

- [ ] `--check-update` — skip sync if Hagezi lists haven't changed (high priority)
- [ ] Optional atomic two-phase sync (blocked by ControlD API improvements)

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Missing dependencies` | Install `curl` and `jq`. |
| `Profile not found by name` | Ensure the profile name in `config.toml` matches exactly (case-sensitive) in ControlD. |
| `Failed to fetch profiles (HTTP 401)` | Your API token is invalid or expired. Generate a new one from the ControlD dashboard. |
| `Batch X failed (HTTP 4xx/5xx)` | The script retries automatically with exponential backoff. If persistent, check ControlD API status. |
| `--list-hagezi shows rate limit` | GitHub unauthenticated API limit is 60/hr or 5000/hr w/ GITHUB_TOKEN env var. |
| `Backup OK: 0 rules saved` | ControlD API read-after-write inconsistency on newly created groups. The backup is empty but harmless — the next sync will capture the rules. |

---

## Development Note

This project was built in a single day using heavy AI assistance (primarily Kimi + Gemini) **on a mobile device** (Termux on Android), with full human oversight, testing, and refinement by the maintainer.

I have a strong Bash background (including previous projects like [PixelProps](https://github.com/Pixel-Props)) and understand every line of the script — the AI simply accelerated development dramatically.

---

**⭐ If this tool saves you time, please star the repo!** It really helps with visibility.

---

## License

MIT — see [LICENSE](LICENSE)
