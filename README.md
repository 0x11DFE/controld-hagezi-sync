
# ControlD Hagezi Sync

![GitHub stars](https://img.shields.io/github/stars/0x11DFE/controld-hagezi-sync?style=flat-square)
![License](https://img.shields.io/github/license/0x11DFE/controld-hagezi-sync?style=flat-square)
![Language](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square&logo=gnu-bash)
![GitHub Actions](https://img.shields.io/github/actions/workflow/status/0x11DFE/controld-hagezi-sync/sync.yml?style=flat-square&label=CI)
![Last Commit](https://img.shields.io/github/last-commit/0x11DFE/controld-hagezi-sync?style=flat-square)
![Issues](https://img.shields.io/github/issues/0x11DFE/controld-hagezi-sync?style=flat-square)

> **Zero-dependency Bash with TOML power.** No Python virtualenvs, no Go binaries, no opaque profile IDs. Write human-readable profile names, mix-and-match folders per profile, dry-run before you push, and know exactly how fresh your blocklists are.

Automatically sync Hagezi DNS blocklists to your ControlD profiles via the ControlD API.

---

## Why this one?

## Why this one?

| Feature                        | **0x11DFE/controld-hagezi-sync**                  | [keksiqc/ctrld-sync](https://github.com/keksiqc/ctrld-sync) | [italorgama/ctrld-hagezi-sync](https://github.com/italorgama/ctrld-hagezi-sync) |
|--------------------------------|---------------------------------------------------|-------------------------------------------------------------|---------------------------------------------------------------------------------|
| **Language**                   | Bash (`curl` + `jq` only)                        | Python 3 + uv                                              | Go (single binary)                                                             |
| **Config format**              | TOML (with comments)                              | Python list + `.env`                                       | `lists.txt`                                                                    |
| **Profile targeting**          | By **name** (human-readable)                      | By **ID**                                                  | By **ID**                                                                      |
| **Per-profile folder sets**    | :white_check_mark: Yes (different per profile)   | :x: Same folders for all                                   | :x: Same folders for all                                                       |
| **Dry-run**                    | :white_check_mark: Yes (`--dry-run`)             | :x: No                                                     | :x: No                                                                         |
| **Single-profile sync**        | :white_check_mark: Yes (`--profile`)             | :x: No                                                     | :x: No                                                                         |
| **Freshness report**           | :white_check_mark: Yes                            | :x: No                                                     | :x: No                                                                         |
| **List discovery**             | :white_check_mark: `--list-hagezi`               | :x: Manual/hardcoded                                       | :white_check_mark: `make list`                                                 |
| **Smart triggering**           | Daily + manual                                    | Daily + manual                                             | Every 2h + **change detection**                                                |
| **Local CLI experience**       | Native Bash script (excellent)                    | Python script                                              | Go binary                                                                      |
| **Setup simplicity (Actions)** | Edit TOML + commit + secret                       | Edit Python file + secrets                                 | **Easiest**: Just add secrets (no config commit)                               |
| **Rule batching**              | 500 rules (with retries)                          | 500 rules (with retries)                                   | 500 rules (with retries)                                                       |

**Bottom line:** If you want a lightweight, transparent script where you can define *different* blocklists for *different* family members or devices using plain profile names -- and preview changes before they go live -- this is the one.

![Star History Chart](https://api.star-history.com/svg?repos=0x11DFE/controld-hagezi-sync,keksiqc/ctrld-sync,italorgama/ctrld-hagezi-sync&type=Date)

---

## What it does

- Downloads the latest Hagezi blocklist folder definitions (JSON)
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

---

## CLI Options

```text
./sync-hagezi.sh [OPTIONS]

  --config FILE      Use a custom configuration file (default: config.toml)
  --dry-run          Preview changes without modifying ControlD
  --profile NAME     Sync only one profile
  --list-hagezi      List available Hagezi folders (ready for config.toml)
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
```

---

## GitHub Action Inputs

When running manually via **Actions -> Run workflow**, you can specify:

| Input | Description |
|---|---|
| `profile` | Sync only a specific profile (leave empty for all) |
| `dry_run` | Check the box to run in preview mode |

---

## Security Notes

- **Never commit `config.toml` if it contains your API token.**
- **Use GitHub Secrets** for the token in CI/CD.
- The script strips a leading `Bearer ` prefix from the token automatically if present.

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
4. For each profile, deletes existing folders by PK, then recreates them with fresh rules.
5. Rules are inserted in batches of 500 to stay within API limits.
6. Prints a freshness report showing when each Hagezi list was last updated on GitHub.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Missing dependencies` | Install `curl` and `jq`. |
| `Profile not found by name` | Ensure the profile name in `config.toml` matches exactly (case-sensitive) in ControlD. |
| `Failed to fetch profiles (HTTP 401)` | Your API token is invalid or expired. Generate a new one from the ControlD dashboard. |
| `Batch X failed (HTTP 4xx/5xx)` | Usually transient. Re-run the workflow. If persistent, check ControlD API status. |
| `--list-hagezi shows rate limit` | GitHub unauthenticated API limit is 60/hr. Set `GITHUB_TOKEN` or wait. |

---

## License

MIT -- see [LICENSE](LICENSE)
