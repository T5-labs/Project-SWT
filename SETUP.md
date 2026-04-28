# SWT Setup Playbook (for the agent)

> **Platform support:** SWT is officially supported on **Windows only** (Git Bash and WSL). macOS and Linux are not officially supported. The playbook below includes macOS/Linux detection branches for community experimentation, but they are untested and may not work without additional configuration (e.g. Edge browser availability, LINQPad, Windows path handling).

## 1 — Purpose

If you (Claude) are reading this, someone asked you to set up SWT on their machine. The repo's `.claude/config/swt.yml` is a **seed template** checked in with another user's personal values. Your job is to walk the user through replacing exactly those personal fields in `swt.yml` with their own values, editing the file in place. On the user's first `swt` boot, `deploy.sh` will read `swt.yml` and create `swt_settings.json` in their Windows home directory — that JSON file becomes the permanent, living config going forward. You do not create `swt_settings.json` yourself; deploy.sh handles that on first boot.

Auto-detect what you can. Ask only for inputs you cannot determine yourself. Do NOT run destructive commands. Do NOT delete anything. Do NOT create any files or directories.

Your log prefix for this playbook is `[SETUP]`.

---

## 2 — When and how you're invoked

The user runs you by saying something like "set up SWT for me" in a standard Claude Code session opened in the Project-SWT directory. You are NOT launched via `swt` or TPM — this is a fresh Claude Code shell. Confirm your working directory is the Project-SWT root before starting.

---

## 3 — Prerequisites

Run these checks before doing anything else. If anything fails, stop and tell the user.

**3a — Working directory**

```bash
test -f ./CLAUDE.md && test -f ./.claude/config/swt.yml && echo OK
```

If this does not print `OK`, tell the user to `cd` into the Project-SWT repo and re-run you.

**3b — Atlassian MCP connectivity**

Call `mcp__claude_ai_Atlassian__getAccessibleAtlassianResources`. If it errors or returns empty, tell the user to connect via `/mcp` → sign in to Atlassian, then restart the Claude Code session (exit and re-open Claude so the MCP connection is picked up).

---

## 4 — Step-by-step procedure

### Step 1 — Detect the platform

```bash
if grep -qi microsoft /proc/version 2>/dev/null; then
  PLATFORM=wsl
elif [ -n "$MSYSTEM" ]; then
  PLATFORM=gitbash
elif [ "$(uname -s)" = "Darwin" ]; then
  PLATFORM=macos
else
  PLATFORM=linux
fi
echo "$PLATFORM"
```

- `wsl` / `gitbash`: YAML path values use Windows form with doubled backslashes (`C:\\Users\\...`). Officially supported.
- `macos` / `linux`: POSIX paths (`/Users/...` or `/home/...`). **Untested / community-supported only** — Edge browser, LINQPad, and Windows clipboard features will not work as-is.

Tell the user which platform you detected.

Also set `$MOUNT` now — later steps use it to probe Windows filesystems from a POSIX shell:

```bash
if [ "$PLATFORM" = "wsl" ]; then MOUNT="/mnt/c"; fi
if [ "$PLATFORM" = "gitbash" ]; then MOUNT="/c"; fi
```

### Step 2 — Detect Windows username (Windows-family platforms only)

If `PLATFORM` is `wsl` or `gitbash`:

```bash
WIN_USER="${USERPROFILE##*\\}"
if [ -z "$WIN_USER" ] && [ -d "${MOUNT}/Users" ]; then
  echo "Candidate Windows usernames under ${MOUNT}/Users:"
  ls "${MOUNT}/Users" | grep -vE '^(Public|Default|All Users|Default User|desktop\.ini)$'
fi
echo "$WIN_USER"
```

If `WIN_USER` is still empty, ask the user: *"What's your Windows username?"*

Skip this step on macOS / Linux.

### Step 3 — Ask the user for the Obsidian vault path

Prompt:

> What's the absolute path to your Obsidian vault? Example on Windows: `C:\Users\you\Documents\Obsidian\vault`. On macOS: `/Users/you/Documents/Obsidian/vault`.

On WSL or Git Bash, translate Windows-style input to the native probe path and validate. The mount prefix differs by platform: `/mnt/c/...` on WSL, `/c/...` on Git Bash.

Example — user pastes `C:\Users\foo\Documents\Obsidian\vault`:

```bash
OBSIDIAN_PATH_POSIX="${MOUNT}/Users/foo/Documents/Obsidian/vault"
test -d "$OBSIDIAN_PATH_POSIX" && echo OK || echo MISSING
```

You can transform the input in-place: strip `C:\`, replace `\` with `/`, prepend `$MOUNT`.

If the directory is missing, tell the user and ask whether to retry or proceed — the vault may not exist yet. Do NOT create it yourself.

Store the value in Windows form (doubled backslashes) for `wsl` / `gitbash`, or POSIX form for `macos` / `linux`.

### Step 4 — Atlassian cloud id and site

Call:

```
mcp__claude_ai_Atlassian__getAccessibleAtlassianResources
```

- Exactly one resource returned → use its `id` as `atlassian_cloud_id`. For `atlassian_site`, take the resource's `url` and strip the `https://` prefix (and any trailing slash) so you end up with just the host, e.g. `yoursite.atlassian.net`.
- Multiple resources → list them and ask the user which to use.
- Zero resources → abort. Tell the user to connect Atlassian MCP first.

### Step 5 — Jira board URL and id

Prompt:

> Paste the URL of your Jira board. It looks like: `https://yoursite.atlassian.net/jira/software/c/projects/XYZ/boards/393`

Parse the board id:

```bash
BOARD_ID="${BOARD_URL##*/boards/}"
BOARD_ID="${BOARD_ID%%/*}"
BOARD_ID="${BOARD_ID%%[?#]*}"
echo "$BOARD_ID"
```

If `BOARD_ID` is not a positive integer, ask the user to re-paste.

When you write this to the YAML in Step 9, use the bare integer form (`board_id: 393`), not a quoted string.

### Step 6 — Edge profile path

**Windows-family:** Default path is `C:\Users\<WIN_USER>\AppData\Local\Microsoft\Edge\User Data`.

On WSL or Git Bash, probe the default path:

```bash
test -d "${MOUNT}/Users/$WIN_USER/AppData/Local/Microsoft/Edge/User Data" && echo OK || echo MISSING
```

Show the default to the user and ask: *"Use this path, or override?"* Store the Windows-form path (doubled backslashes) in the YAML.

**macOS / Linux:** Ask the user if they use Playwright with Edge. If not, `playwright_headless: true` and the path field can remain as-is.

### Step 7 — LINQPad

`LPRun8.exe` is LINQPad 8's command-line runner — SWT agents use it to run read-only SELECT queries against allowlisted databases. If the user doesn't work with .NET / SQL Server databases through LINQPad, they can skip this step entirely and set `database_enabled: false`.

**Probe for LPRun8.exe**

Check the two standard install locations. The mount prefix differs by platform: `/mnt/c/...` on WSL, `/c/...` on Git Bash.

```bash
# Resolve mount prefix
if [ "$PLATFORM" = "wsl" ]; then
  MOUNT="/mnt/c"
elif [ "$PLATFORM" = "gitbash" ]; then
  MOUNT="/c"
fi

CANDIDATES_WIN=(
  "C:\\Program Files\\LINQPad8\\LPRun8.exe"
  "C:\\Users\\${WIN_USER}\\AppData\\Local\\Programs\\LINQPad8\\LPRun8.exe"
)

LPRUN_FOUND=""
for WIN_PATH in "${CANDIDATES_WIN[@]}"; do
  # Convert Windows path to POSIX probe path
  POSIX_PATH="${MOUNT}/$(echo "$WIN_PATH" | sed 's|C:\\\\||; s|\\\\|/|g')"
  if test -f "$POSIX_PATH"; then
    LPRUN_FOUND="$WIN_PATH"
    break
  fi
done
echo "${LPRUN_FOUND:-NOT_FOUND}"
```

Store the first match as `lprun_path` (Windows form with doubled backslashes). Then branch:

**Found at a standard path** → set `lprun_path` to the matched path, proceed to Step 8.

**Not found** → ask the user:

> I couldn't find LPRun8.exe in the standard locations. Do you work with .NET / SQL Server databases through LINQPad? If yes, I can point you at how to install it; if no, we'll skip DB features.

- **No** → set `database_enabled: false`, skip Step 8, continue to Step 9.

- **Yes, but installed at a non-default path** → ask for the absolute Windows path to `LPRun8.exe` (e.g. `C:\Tools\LINQPad8\LPRun8.exe`). Store it as `lprun_path` with doubled backslashes, then proceed to Step 8.

- **Yes, but not installed yet** → tell the user:
  - Download LINQPad 8 from **https://www.linqpad.net/Download.aspx** (official site).
  - **LPRun requires a paid edition of LINQPad** — the free edition does not include the CLI runner. Check https://www.linqpad.net/Purchase.aspx for the current paid edition name (historically "LINQPad Developer" but edition names may change). Use WebFetch on that URL if you need up-to-date edition info.
  - After a standard install, LPRun8.exe will be at `C:\Program Files\LINQPad8\LPRun8.exe`. For a per-user install it will be at `C:\Users\<you>\AppData\Local\Programs\LINQPad8\LPRun8.exe` (i.e., `%LOCALAPPDATA%\Programs\LINQPad8\LPRun8.exe`).
  - After installing, **restart the SETUP playbook from the beginning** — re-running is safe (see Step 12).

**Connection setup — bridge to Step 8**

Step 8 will ask for "LINQPad saved connection names." These are connections the user created in LINQPad's GUI (right-click the connection pane on the left → Add connection → configure → OK). The name SWT expects is the exact display name LINQPad shows for each connection (usually `<server>.<database>`, e.g. `localhost, 1433.cmms`). If the user hasn't set up any connections yet, tell them to open LINQPad, add the connections they want SWT to query, and then restart the playbook.

### Step 8 — Database allowlist

Only if `database_enabled: true`. Ask:

> For each database SWT agents may query, give me: (1) the Jira project key (e.g. `CMMS`), (2) the exact LINQPad saved connection name. Enter `done` when finished — can be empty.

Collect into a list. If the user enters nothing, set `databases: []`. These values will be seeded into the `database.allowlist` map in `swt_settings.json` on first boot.

### Step 9 — Update `swt.yml` in place (seed template)

**Why edit `swt.yml`?** On first `swt` boot, `deploy.sh` reads `swt.yml` and seeds `swt_settings.json` (the permanent JSON config) from its values. Editing `swt.yml` now means the user's first boot will produce a correctly populated `swt_settings.json` automatically, with no manual JSON editing required.

**First, read `.claude/config/swt.yml` end to end.** You need the exact current values (the author's paths, cloud id, board id, database entries, etc.) so your Edit calls have the right `old_string` to match. Do NOT guess — use the Read tool.

Use the **Edit tool** to make targeted replacements on these fields only. Do NOT rewrite the file wholesale with the Write tool — use surgical edits so comments, structure, and all non-personal defaults (`swe_agent_count`, `swe_efficiency_cores`, `swe_performance_cores`, `qa_agent_count`, `playwright_headless`) are preserved exactly.

Fields to replace:

| Field | Source |
|---|---|
| `obsidian_base_path:` | Step 3 |
| `atlassian_cloud_id:` | Step 4 |
| `atlassian_site:` | Step 4 |
| `board_id:` | Step 5 |
| `board_url:` | Step 5 |
| `edge_profile_path:` | Step 6 |
| `playwright_headless:` | Step 6 (only if user does NOT use Playwright with Edge — set to `true`) |
| `database_enabled:` | Step 7 (only if changing from `true` to `false`) |
| `lprun_path:` | Step 7 (only if overriding the default) |
| `databases:` block | Step 8 (only if changed) |

**The `databases:` block is a multi-line replacement.** The committed file has entries under `databases:`. Your Edit's `old_string` must include `databases:` AND all child entries through the last line of the block. Your `new_string` is either `databases: []` (empty) or a fresh YAML list with the colleague's entries. Do NOT leave orphaned child lines behind.

Example `new_string` (empty):

```yaml
databases: []
```

Example `new_string` (two entries — note each list item is 2 spaces indented, and the value keys `project` and `connection` are 4 spaces indented):

```yaml
databases:
  - project: CMMS
    connection: "localhost, 1433.cmms"
  - project: MCP
    connection: "mcpdevsql.MCP_Dev"
```

Do NOT touch any other lines.

### Step 10 — Validate

Read the file back and confirm the new values are present. If `python3` is available, run a YAML parse check on the seed file:

```bash
python3 -c "import yaml; yaml.safe_load(open('.claude/config/swt.yml'))" && echo "OK: YAML parses"
```

If the parse fails, read the file, identify the malformed line, and fix it with another Edit call.

**Post-first-boot JSON validation (after Step 11 completes):**

After `deploy.sh --setup` runs (Step 11), `swt_settings.json` will have been created in the user's Windows home directory. Validate it:

```bash
# Resolve the settings file path for the current platform
if [ "$PLATFORM" = "wsl" ]; then
  SETTINGS_PATH="${MOUNT}/Users/${WIN_USER}/swt_settings.json"
elif [ "$PLATFORM" = "gitbash" ]; then
  SETTINGS_PATH="/c/Users/${WIN_USER}/swt_settings.json"
fi

python3 -c "import json; json.load(open('${SETTINGS_PATH}'))" && echo "OK: JSON parses"
```

If the file does not exist yet (first boot hasn't run), skip this check — it will be created when the user runs `swt` for the first time. If the JSON is malformed, read the file, identify the broken line, and fix it with an Edit call targeting `${SETTINGS_PATH}`.

### Step 11 — Install the `swt` launcher

Check if `swt` is already on PATH:

```bash
command -v swt && echo "OK: swt on PATH" || echo "NEEDS_INSTALL"
```

If `NEEDS_INSTALL`, run:

```bash
bash ./deploy.sh --setup
```

(Use `bash ./deploy.sh --setup` rather than `./deploy.sh --setup` — when the repo lives under `/mnt/c/...` on WSL, exec bits on Windows filesystems aren't preserved, so `./deploy.sh` may fail with "Permission denied." Invoking via `bash` sidesteps that.)

This creates `~/bin/swt` and appends `export PATH="$HOME/bin:$PATH"` to their shell rc file (`.bashrc` or `.zshrc`). Tell the user to open a new terminal (or `source` their rc) for `swt` to be available.

### Step 12 — Post-setup message

Tell the user:

- Setup is complete. Their `swt.yml` seed has their values.
- On first `swt` boot, deploy.sh will automatically create `swt_settings.json` in their Windows home directory (`C:\Users\<them>\swt_settings.json`). That JSON file is the permanent living config going forward — they edit it directly or ask TPM to update values conversationally.
- They can now run `swt` (unconstrained) or `swt --branch` (constrained — auto-detects the ticket from the branch name).
- **Old files:** If they previously used SWT and have `swt_feedback.md` or `swt_support.md` files, those will be automatically migrated into `swt_settings.json` on first boot. After migration, they can delete the old MD files manually — SWT no longer reads from them.
- Caveat: if they ever `git pull` updates that modify `swt.yml`, they may need to re-merge their personal values into it (so the next fresh-machine setup seeds correctly). Their live config in `swt_settings.json` is unaffected by git pulls.
- Re-running SETUP is safe. Each Edit call replaces the current value with the new one — you won't end up with duplicates or stale sentinels as long as you follow Step 9's "read first" rule.

---

## 5 — Rules for you (the agent)

- **No destructive git.** No `add`, `commit`, `push`, `pull`, `reset`, `stash`, `checkout`, `branch`, `merge`, `rebase`, or any other write git command.
- **No deletions.** Do not delete files, directories, or anything else.
- **Do not create directories.** If the Obsidian vault path doesn't exist, tell the user — do not create it.
- **Only touch `.claude/config/swt.yml` and (post-first-boot) `swt_settings.json`.** Do not modify any other file in the repo or on the filesystem.
- **Stay in scope.** If the user asks you to do something beyond this playbook (e.g., "also set up shell aliases", "configure my terminal"), tell them that's out of scope for setup.
