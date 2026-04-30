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

---

## 6 — Bitbucket Integration (Optional)

> For the full architecture and decisions reference, see [`docs/bitbucket-integration.md`](docs/bitbucket-integration.md).

This section walks the user through enabling the optional Bitbucket Cloud REST integration. SWT works perfectly fine without it — skip this entire section if the user does not use Bitbucket Cloud or does not want SWT to query PRs, comments, or pipelines.

The Bitbucket secrets file (`.swt_secrets`) lives in the same directory as `swt_settings.json` — the user's Windows home directory (`/mnt/c/Users/<you>/` on WSL, `/c/Users/<you>/` on Git Bash). Keeping both files in one place makes them easier to find, easier to back up, and consistent with the rest of SWT's config layout. `deploy.sh` exports `SWT_SECRETS_PATH` on every boot, so once setup is complete the env var is available in every `swt` session.

### Step 1 — Decide if you want it

Ask the user: *"Do you want SWT agents to be able to query Bitbucket Cloud (PR state, comments, pipelines)?"* If they say no, stop here and move on. The integration is fully opt-in — `bitbucket.enabled` defaults to `false` and nothing in SWT depends on it.

### Step 2 — Generate an Atlassian Cloud API token

Bitbucket Cloud now authenticates via Atlassian API tokens with HTTP Basic auth (email + token). The legacy Bitbucket-only app passwords are deprecated — do NOT use them.

Tell the user:

> Open your Atlassian API tokens page: **https://id.atlassian.com/manage-profile/security/api-tokens**
>
> Create a new API token with these scopes (Bitbucket account, pull request, and pipeline read scopes):
> - `read:bitbucket-account`
> - `read:bitbucket-pull-request`
> - `read:bitbucket-pipeline`
> - `write:bitbucket-pull-request` *(optional — only needed if you want agents to post or reply to PR comments)*
>
> If the scope slugs differ in Atlassian's UI, refer to Atlassian's API token docs and select the equivalent Bitbucket account / pull request / pipeline read scopes.
>
> Copy the generated token immediately — Atlassian only shows it once. You will also need your Atlassian login email (the email you sign in to Atlassian with) — both pieces are required for HTTP Basic auth.

Do NOT ask the user to paste the token to you. The token never enters your context. The user pastes it (and their email) into a local file in a later step.

### Step 3 — Run interactive setup

Have the user run:

```bash
bash deploy.sh --setup-bitbucket
```

The script will prompt for:
- **Workspace slug** — the Bitbucket workspace (e.g., `herzog`).
- **Flavor** — defaults to `cloud`. Press Enter to accept.

What it does — **the script handles all file creation and permissions for you**:
- Updates `swt_settings.json` (at `/mnt/c/Users/<you>/swt_settings.json` on WSL, or `/c/Users/<you>/swt_settings.json` on Git Bash) — flips `bitbucket.enabled` to `true` and writes `flavor`. Workspace, email, and token are user-specific account data and live in `.swt_secrets` (never in the settings file); the settings file holds only project-level config.
- Creates `.swt_secrets` in the user's Windows home directory (resolves to `/mnt/c/Users/<you>/.swt_secrets` on WSL, `/c/Users/<you>/.swt_secrets` on Git Bash — the same directory as `swt_settings.json`) with `chmod 600` already applied, pre-populated with this template:

  ```
  # SWT secrets — never commit this file.
  # === Bitbucket Cloud ===
  # Atlassian API token + email + workspace for Bitbucket Cloud (HTTP Basic auth).
  # Generate token at: https://id.atlassian.com/manage-profile/security/api-tokens
  # Required (read) scopes: read:bitbucket-account, read:bitbucket-pull-request, read:bitbucket-pipeline.
  # Optional (write) scope for posting/replying to PR comments: write:bitbucket-pull-request.
  BITBUCKET_EMAIL=
  BITBUCKET_TOKEN=
  BITBUCKET_WORKSPACE=your-workspace-slug
  ```

  `BITBUCKET_WORKSPACE` is pre-populated by the script with the workspace slug you typed at the prompt — you do NOT need to fill it in manually.

**Your only manual step** — once the script finishes — is filling in `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN`, each after the `=`. The workspace line is already populated. No `touch`, no `chmod 600`; the script already did them. See Step 4 below.

**TPM-driven alternative:** if you'd rather not run the script, you can ask TPM to do this in an `swt` session. TPM creates the same `.swt_secrets` template at `${SWT_SECRETS_PATH}` with the same chmod-600 permissions and updates `swt_settings.json` for you. TPM will ask for your workspace slug and pre-populate the `BITBUCKET_WORKSPACE` line for you. Either way, your only manual step is filling in `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN`.

**Note:** the interactive script must be run from an interactive terminal. The workspace and flavor prompts read from `/dev/tty` and cannot be piped in from another command or driven by an agent. If the interactive prompts will not work in your environment, ask TPM to do it in-session, or use the manual fallback in the subsection below.

### Step 4 — Paste your email and token into `.swt_secrets`

Step 3 already created the file with the right permissions, the workspace line pre-populated, and template placeholders for the rest. **Your only manual step is filling in `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN`.** Bitbucket Cloud uses HTTP Basic auth — neither value alone is sufficient; both are required. The workspace line is already populated by the script. The file lives at `${SWT_SECRETS_PATH}` — which resolves to `/mnt/c/Users/<you>/.swt_secrets` on WSL or `/c/Users/<you>/.swt_secrets` on Git Bash. Open it in the editor of your choice — using the env var is the most portable form:

```bash
nano "$SWT_SECRETS_PATH"
# or: code "$SWT_SECRETS_PATH"
# or: vim "$SWT_SECRETS_PATH"
```

If `SWT_SECRETS_PATH` isn't yet exported in your current shell (e.g., you haven't run `swt` yet since setup), use the concrete path:

```bash
nano /mnt/c/Users/<you>/.swt_secrets   # WSL
nano /c/Users/<you>/.swt_secrets       # Git Bash
```

Fill in `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN` so the file reads:

```
# === Bitbucket Cloud ===
BITBUCKET_EMAIL=your-atlassian-login-email@example.com
BITBUCKET_TOKEN=your-api-token
BITBUCKET_WORKSPACE=your-workspace-slug
```

The `BITBUCKET_WORKSPACE` line is already populated by the script — leave it as-is unless you typed the wrong slug at the prompt. Use your real Atlassian login email (the address you sign in to Atlassian with — not just a username). No quotes, no spaces around the `=`, no `export` keyword. Save and close.

You (the agent) MUST NOT read `.swt_secrets` to verify it. The hard rule against reading secrets applies to you too. Confirm with the user verbally: *"Did you save the file with `BITBUCKET_EMAIL=<your-atlassian-email>` and `BITBUCKET_TOKEN=<your-token>` filled in, and is the pre-populated `BITBUCKET_WORKSPACE` line correct?"*

### Step 5 — Verify

Tell the user to open a fresh terminal (or re-source their shell rc so the secrets file is sourced into scope), then run `bb-curl` against `/user`. The script lives at `${SWT_DIR}/scripts/bb-curl.sh` and is not on `$PATH` by default, so the canonical form is the absolute path:

```bash
${SWT_DIR}/scripts/bb-curl.sh GET /user
```

For convenience, the user can alias it in their shell rc:

```bash
alias bb-curl='${SWT_DIR}/scripts/bb-curl.sh'
```

After which `bb-curl GET /user` works directly.

A successful response is a JSON object with their Bitbucket account info (`username`, `display_name`, `account_id`, etc.). If they see that, Bitbucket integration is working. The workspace slug used by `bb-curl` is sourced from the secrets file (`BITBUCKET_WORKSPACE`), paired with the email and token.

If the `/user` endpoint returns a permission/scope error (some token configurations restrict it), use this fallback to confirm the credentials and workspace are working together:

```bash
${SWT_DIR}/scripts/bb-curl.sh GET "/repositories/<your-workspace>?pagelen=3"
```

This hits a workspace-scoped endpoint that exercises the same email + token + workspace combo. A 200 with a paginated list of repositories means the integration is working.

If the verification fails with a **401**, double-check that you used your **Atlassian login email** (not just a username) and that the token has the required read scopes (`read:bitbucket-account`, `read:bitbucket-pull-request`, `read:bitbucket-pipeline`), plus `write:bitbucket-pull-request` if you want agents to post or reply to PR comments. Bitbucket Cloud uses HTTP Basic auth — both the email and the token must be correct.

### Manual Setup (if interactive prompts don't work)

For users who cannot drive `--setup-bitbucket` interactively (e.g., running from a tooling pipeline, a constrained shell, or any environment where `/dev/tty` is not attached), use these steps instead of Step 3. **You can also ask TPM to do this for you in an `swt` session** — TPM will create the same template file with chmod 600 and update `swt_settings.json`, so your only manual step remains pasting the token.

1. **Edit `swt_settings.json` directly.** The file lives at the user's Windows home — `/mnt/c/Users/<you>/swt_settings.json` on WSL, or `/c/Users/<you>/swt_settings.json` on Git Bash. Find the `bitbucket` block and set:

   ```json
   "bitbucket": {
     "enabled": true,
     "flavor": "cloud",
     "auth": {
       "token_source": "env:BITBUCKET_TOKEN"
     }
   }
   ```

   Note: workspace is no longer stored in `swt_settings.json` — it lives in `.swt_secrets` alongside the email and token (it's user-specific account data, not project config).

2. **Create the secrets file** (only needed if you're going fully manual — TPM and `--setup-bitbucket` both handle this for you). The file lives in your Windows home directory, alongside `swt_settings.json`:

   ```bash
   # WSL
   touch /mnt/c/Users/<you>/.swt_secrets && chmod 600 /mnt/c/Users/<you>/.swt_secrets

   # Git Bash
   touch /c/Users/<you>/.swt_secrets && chmod 600 /c/Users/<you>/.swt_secrets
   ```

   Once `swt` has been run at least once, `deploy.sh` exports `SWT_SECRETS_PATH` on every boot, so subsequent edits can use the portable form: `nano "$SWT_SECRETS_PATH"`.

   Then open it in your editor and paste all three lines (Bitbucket Cloud uses HTTP Basic auth — email and token are both required, and workspace is paired with them as user-specific account data):

   ```
   # SWT secrets — never commit this file.
   # === Bitbucket Cloud ===
   # Atlassian API token + email + workspace for Bitbucket Cloud (HTTP Basic auth).
   # Generate token at: https://id.atlassian.com/manage-profile/security/api-tokens
   # Required (read) scopes: read:bitbucket-account, read:bitbucket-pull-request, read:bitbucket-pipeline.
   # Optional (write) scope for posting/replying to PR comments: write:bitbucket-pull-request.
   BITBUCKET_EMAIL=your-atlassian-login-email@example.com
   BITBUCKET_TOKEN=your-token-here
   BITBUCKET_WORKSPACE=your-workspace-slug
   ```

3. **Verify** with `${SWT_DIR}/scripts/bb-curl.sh GET /user` exactly as in Step 5 above.

**Backward compat note:** earlier SWT versions placed `.swt_secrets` in your WSL home (`~/.swt_secrets`). If you have a vestige there, you can `rm` it after confirming the new location works — `bb-curl.sh` now reads exclusively from `${SWT_SECRETS_PATH}` in your Windows home.

### Step 6 — Troubleshooting

- **`BITBUCKET_TOKEN not set`** — the secrets file may be missing or malformed. Tell the user to verify the file exists at `${SWT_SECRETS_PATH}` (their Windows home — `/mnt/c/Users/<you>/.swt_secrets` on WSL, `/c/Users/<you>/.swt_secrets` on Git Bash) and has the right format. **Do NOT** suggest `cat "$SWT_SECRETS_PATH"` casually — that command prints the token to the terminal and risks landing it in shell history or scrollback. If the user really needs to inspect it, tell them to use a private terminal session and clear scrollback after.
- **`BITBUCKET_EMAIL not set`** — the secrets file is missing the email line. Bitbucket Cloud requires HTTP Basic auth (email + token); the token alone is not sufficient. Tell the user to add `BITBUCKET_EMAIL=your-atlassian-login-email@example.com` to the secrets file alongside their token, using the email they sign in to Atlassian with.
- **`BITBUCKET_WORKSPACE not set`** — the secrets file is missing the workspace line. Workspace now lives in `.swt_secrets` alongside the email and token (it's user-specific account data, not project config). Tell the user to add `BITBUCKET_WORKSPACE=your-workspace-slug` to the secrets file. If they used `deploy.sh --setup-bitbucket`, the line should have been pre-populated automatically — they may have edited it out by accident.
- **Setup script hangs at the workspace prompt** — `--setup-bitbucket` reads from `/dev/tty` and cannot be piped or driven by an agent. Run it from a real interactive terminal, or use the Manual Setup subsection above.
- **HTTP 401 / 403** — the token is expired, revoked, or lacks the required scopes; OR the paired email is wrong; OR the workspace slug doesn't match the credentials. Bitbucket Cloud uses HTTP Basic auth, so all three secrets file values (`BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, `BITBUCKET_WORKSPACE`) must be correct. Have the user verify their Atlassian login email is exactly right, confirm the workspace slug in `.swt_secrets` matches the workspace they actually have access to, then regenerate the token at https://id.atlassian.com/manage-profile/security/api-tokens (with read scopes `read:bitbucket-account`, `read:bitbucket-pull-request`, `read:bitbucket-pipeline`, plus `write:bitbucket-pull-request` if they want agents to post or reply to PR comments) and update the secrets file at `${SWT_SECRETS_PATH}` with the new value.
- **HTTP 404 on a known-good repo path** — double-check the workspace slug; a wrong workspace yields 404 rather than 401.

### Step 7 — Security notes

- The token never leaves the user's machine. `scripts/bb-curl.sh` sources the secrets file at `${SWT_SECRETS_PATH}` locally on each call.
- The token is never written to `swt_settings.json`, the repo, any logged file, or any agent transcript.
- The Atlassian email is paired with the token to form HTTP Basic auth credentials — neither alone is enough. `BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, and `BITBUCKET_WORKSPACE` all live in the same chmod-600 secrets file. Email is part of the credential pair; workspace lives there too because it's user-specific account data tied to the credentials, not project config.
- Agents (TPM, SWE, QA) have a hard rule against reading the secrets file directly and against echoing any `*_TOKEN`, `*_SECRET`, `*_KEY`, or `*_PASSWORD` environment variable.
