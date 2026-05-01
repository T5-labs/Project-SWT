# Project SWT

A multi-agent development team you deploy from any repo to collaboratively work on Jira tickets. Spring 2026.

## Features

- **Multi-agent orchestration** — TPM coordinates SWE and QA subagents with model selection by task difficulty (Opus / Sonnet / Haiku)
- **Jira integration** — Pull tickets, query active sprints, search by status/assignee/priority via JQL
- **Sprint & board queries** — Ask natural language questions about your sprint ("what's in progress?", "what's assigned to me?")
- **Obsidian knowledge base** — Living project notes and per-ticket working docs that persist across sessions
- **Multi-session continuity** — Handoff summaries let you pick up exactly where you left off
- **Feedback Log** — Persistent idea log. Say "log this for later" to append entries; surfaced on each boot.
- **Preview mode** — Dry-run code changes for review before any files are touched
- **Review mode** — Auto-detects colleague branches at startup and deploys 3 SWEs in parallel (security, logic, quality lenses) to hunt for vulnerabilities with ranked findings; type `post <ordinals>` to share selected findings as Bitbucket PR comments with a confirmation gate
- **Fresh Branch Planning** — Auto-detects zero-commit branches on `swt --branch` and deploys 3 SWEs in parallel (architecture, implementation, test-strategy lenses) to plan the ticket from its Jira AC, with the plan logged to Obsidian notes
- **Support Mode** — Multi-app support sessions via `swt --support`. Auto-discovers configured app repos, dispatches 3 SWEs in parallel (Reproduction/Code path/Regression lenses) to investigate.
- **Monitor Mode** — Watches a Bitbucket PR for incoming comments (`swt --branch --monitor`). Classifies each comment, auto-resolves or surfaces per policy, and posts counter-responses after you push. The ticket is auto-detected from the current git branch name. Requires Bitbucket integration.
- **QA verification** — Automated code review of SWE changes plus Playwright test generation
- **Pre-PR checklist** — CodeRabbit-aware checks (secrets, dead code, null checks, unused imports)
- **Clipboard image reading** — Screenshot your screen, say "check my clipboard", and the agent sees it via Claude Vision
- **Database access** — Read-only SQL queries via LINQPad for schema exploration and data inspection
- **Statusline display** — Claude Code statusline shows your SWT version and (when available) cumulative session tokens + current context-window usage when enabled
- **Bitbucket integration** — Optional opt-in REST access for PR / pipeline / comment queries via secure local secrets file. See [`docs/bitbucket-integration.md`](docs/bitbucket-integration.md) for the architecture and decisions reference.
- **Cross-platform** — Works in both Git Bash and WSL with automatic path translation and a single shared launcher
- **One-command setup** — `deploy.sh --setup` configures everything (launcher, PATH, platform detection)

## Quick Start

```bash
# cd into your work repo first, then:
swt                    # Unconstrained — general team, no ticket context
swt --branch           # Constrained — auto-detects ticket from git branch name
```

## Setup

### Prerequisites

- [Claude Code CLI](https://claude.ai/code) installed and authenticated
- Git Bash (comes with [Git for Windows](https://git-scm.com/download/win)) or WSL
- Set Git Bash path for Claude Code in `~/.bashrc` (Git Bash only — not needed for WSL):
  ```bash
  export CLAUDE_CODE_GIT_BASH_PATH="C:\Users\aarbuckle\AppData\Local\Programs\Git\bin\bash.exe"
  ```

### Install

1. Clone the repo:
   ```bash
   git clone https://github.com/T5-labs/Project-SWT.git ~/Project-SWT
   ```

2. Run setup to install the `swt` launcher:

   ```bash
   ~/Project-SWT/deploy.sh --setup
   ```

   This creates `~/bin/swt`, makes it executable, and adds `~/bin` to your PATH in `~/.bashrc` if it isn't already there. Reload your shell after (`source ~/.bashrc`).

   Alternatively, create the launcher manually:
   ```bash
   mkdir -p ~/bin
   echo '#!/bin/bash
   exec ~/Project-SWT/deploy.sh "$@"' > ~/bin/swt
   chmod +x ~/bin/swt
   ```

3. On first boot, `deploy.sh` automatically creates `swt_settings.json` in your Windows home directory, seeded from `.claude/config/swt.yml` defaults. You can either pre-fill `swt.yml` with your personal values before the first boot, or boot with defaults and edit `swt_settings.json` directly afterward. See [Configuration](#configuration) for the full schema.

### WSL Setup

If you prefer running SWT from WSL instead of Git Bash:

1. **Ensure you have a proper WSL distro** (Ubuntu recommended). If you have Docker Desktop installed, your default WSL distro may be `docker-desktop`, which is a minimal distro without bash or Node.js. Check and fix:
   ```bash
   wsl --list --verbose          # See installed distros — * marks the default
   wsl --install -d Ubuntu       # Install Ubuntu if not listed
   wsl --set-default Ubuntu      # Set Ubuntu as default
   ```

2. **Fix git safe.directory.** Windows-side repos appear as `root`-owned in WSL, so Git blocks them. Allow all repos (safe on a dev machine):
   ```bash
   git config --global --add safe.directory '*'
   ```

3. **Install Node.js and Claude Code CLI** in WSL:
   ```bash
   curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
   sudo apt-get install -y nodejs
   npm install -g @anthropic-ai/claude-code
   ```

4. **Authenticate Claude Code.** The OAuth login flow hangs in WSL because the browser callback can't reach the WSL environment. Instead of `claude auth login`, symlink your existing Windows credentials:
   ```bash
   mkdir -p ~/.claude
   ln -sf /mnt/c/Users/aarbuckle/.claude/.credentials.json ~/.claude/.credentials.json
   ```
   Verify it worked:
   ```bash
   claude --version
   ```
   This shares auth between Git Bash and WSL — no separate login needed. If you don't have Claude Code authenticated on Windows yet, run `claude auth login` from Git Bash first, then create the symlink.

5. **Run setup** to install the `swt` launcher:

   Find where your C: drive is mounted and run setup:
   ```bash
   # Standard mount point (most WSL distros):
   /mnt/c/Users/aarbuckle/Project-SWT/deploy.sh --setup
   # OR if your drives are at /mnt/host/c/:
   /mnt/host/c/Users/aarbuckle/Project-SWT/deploy.sh --setup
   ```

   This creates `~/bin/swt` (a cross-platform launcher that works in both Git Bash and WSL), makes it executable, and adds `~/bin` to your PATH in `~/.bashrc` if needed.

6. **Reload your shell and verify:**
   ```bash
   source ~/.bashrc
   swt --help
   ```

**Notes:**
- **Auth in WSL:** `claude auth login` hangs in WSL because the OAuth browser callback can't reach the WSL environment. The workaround is to symlink the Windows-side credentials file (step 4 above). If the credentials expire, re-authenticate from Git Bash and the symlink picks up the new token automatically.
- WSL does **not** need the `CLAUDE_CODE_GIT_BASH_PATH` env var — that's Git Bash only
- `deploy.sh` auto-detects WSL and translates Windows paths from `swt_settings.json` to the correct Linux path format. It detects your actual C: drive mount point automatically (handles both `/mnt/c` and `/mnt/host/c` and other non-standard mount points).
- The `--setup` launcher is cross-platform — if you run `--setup` from Git Bash, the same `~/bin/swt` file works in WSL too (and vice versa), since WSL inherits the Windows PATH.
- WSL mount points vary by distro and configuration — `/mnt/c` is standard, but some setups (e.g., custom `/etc/wsl.conf`) mount drives at `/mnt/host/c` or elsewhere. Run `ls /mnt/` to see what's available.
- `swt_settings.json` is shared between Git Bash and WSL — no separate config needed
- LINQPad (Windows binary) works from WSL via Windows interop
- Playwright in WSL may need additional setup to locate the Edge browser — test when writing specs

### Verify

```bash
swt --help
```

## Commands

| Command | Description |
|---------|-------------|
| `swt` | Unconstrained mode — general team, no ticket context |
| `swt --branch` | Constrained mode — auto-detect ticket from git branch name |
| `swt --branch --monitor` | Monitor mode — watch PR for new comments and coordinate responses (ticket auto-detected from branch name) |
| `swt --remote` | Enable Claude Code remote control (can combine with other flags) |
| `swt --setup` | Install the `swt` launcher into `~/bin` and add it to PATH |
| `swt --support` | Support mode — multi-app investigation sessions |
| `swt --help` | Show usage help |

**Examples:**

```bash
swt --branch                          # Detect ticket from branch, e.g. bugfix/CMMS-2576-fix → CMMS-2576
swt --branch --monitor                # Constrained + PR comment watch loop (ticket auto-detected from branch)
swt --branch --remote                 # Constrained + remote control
swt --remote                          # Unconstrained + remote control
swt --support                         # Support mode — multi-app investigation session
```

### Global Flags

`--engine=<binary>` selects which Claude Code-compatible binary `swt` exec's. Defaults to `claude`. Combines with any mode (not a mode itself) — accepts a name on PATH or an absolute path.

```bash
swt --engine=claude-rc           # Use a release-candidate engine
swt --branch --engine=/path/to/custom-build
```

## Configuration

Configuration is stored in `swt_settings.json` in your Windows home directory (`C:\Users\<you>\swt_settings.json`). This is the single source of truth for all user-tunable values — created automatically on first boot by seeding from `.claude/config/swt.yml`.

**`swt.yml` is now a deprecated seed template.** It is used only once — on the very first `swt` boot — to create `swt_settings.json`. After that, you edit `swt_settings.json` directly, or ask TPM to update values conversationally. You do not need to touch `swt.yml` again.

### swt_settings.json schema

Top-level keys and what they contain:

| Key | Description |
|-----|-------------|
| `_schema` | Schema version for future migrations (currently 5) |
| `team` | Agent core counts and limits (`swe_count`, `swe_performance_cores`, `swe_efficiency_cores`, `qa_count`) |
| `atlassian` | Jira cloud ID, site URL, board ID and URL |
| `paths` | Obsidian vault path, Edge browser profile path, LINQPad runner path |
| `playwright` | Playwright settings (`headless` toggle) |
| `database` | Database toggle and `allowlist` map of project keys to LINQPad connection names |
| `feedback` | Feedback log toggle and entries |
| `support` | Support mode `enabled` flag and `apps{}` map of app name → repo path or `null` (auto-discovered on boot) |
| `monitor` | Monitor mode settings — polling interval, file threshold, per-category policies, counter-response prompt |
| `review` | Review mode posting settings — `enabled` toggle, `comment_posting_prompt`, `min_rating_to_post` threshold |
| `statusline` | Statusline display config (`enabled` flag — shows SWT version + cumulative session tokens + context-window % in Claude Code) |
| `bitbucket` | Bitbucket Cloud integration toggle and flavor (`enabled`, `flavor`). Off by default. Workspace/email/token live in the user's secrets file (`${SWT_SECRETS_PATH}`). |

To edit a value: open `swt_settings.json` directly in any text editor, or ask TPM *"update my Obsidian path to X"* and TPM will make the edit for you.

### Obsidian

| Setting | Description | Default |
|---------|-------------|---------|
| `paths.obsidian_base` | Path to your Obsidian vault where agent notes are stored | `C:\Users\aarbuckle\Documents\Obsidian\aarbuckle` |

### Atlassian / Jira

| Setting | Description |
|---------|-------------|
| `atlassian.cloud_id` | Your Atlassian Cloud tenant ID. If not set, TPM discovers it on first boot via `getAccessibleAtlassianResources`. |
| `atlassian.site` | Your Atlassian site URL (e.g., `herzog.atlassian.net`) |
| `atlassian.board_id` | Jira board ID for sprint queries (e.g., `393`). Found in your board URL. |
| `atlassian.board_url` | Full URL to your Jira board. Reference for TPM and easy to update if your board changes. |

### Agent Team

| Setting | Description | Default |
|---------|-------------|---------|
| `team.swe_count` | Total max concurrent SWE subagents | `3` |
| `team.swe_performance_cores` | Performance SWE cores (primary workers) | `2` |
| `team.swe_efficiency_cores` | Efficiency SWE cores (side tasks) | `1` |
| `team.qa_count` | Max concurrent QA subagents | `1` |

### Playwright

| Setting | Description | Default |
|---------|-------------|---------|
| `paths.edge_profile` | Path to Microsoft Edge user data directory. Tests use `launchPersistentContext` with this profile to reuse Azure AD sessions. Edge must be closed when running tests. | `C:\Users\aarbuckle\AppData\Local\Microsoft\Edge\User Data` |
| `playwright.headless` | `true` = headless (no browser window), `false` = headed (visible browser, useful for debugging) | `false` |

### Database Access (via LINQPad)

These settings live in the `database` section of `swt_settings.json`:

| Setting | Description | Default |
|---------|-------------|---------|
| `database.enabled` | Global toggle for agent database access | `true` |
| `paths.lprun` | Path to LINQPad 8 CLI runner | `C:\Program Files\LINQPad8\LPRun8.exe` |
| `database.allowlist` | Map of Jira project keys to LINQPad connection names. Agents can only query connections in this map. | — |

**Adding a database:**

1. Create a connection in LINQPad 8 and note its exact name
2. Add an entry to the `database.allowlist` object in `swt_settings.json`:
   ```json
   "database": {
     "enabled": true,
     "allowlist": {
       "CMMS": "localhost, 1433.cmms",
       "MCP": "mcpdevsql.MCP_Dev"
     }
   }
   ```
3. Restart your SWT session for changes to take effect

Database access is **SELECT only** — INSERT, UPDATE, DELETE, DROP, ALTER, CREATE, TRUNCATE, and EXEC are forbidden.

## Team

| Role | Count | Purpose |
|------|-------|---------|
| **TPM** | 1 (long-running) | Orchestrator, discussion partner, edge case hunter, generates testing procedures, writes all Obsidian notes |
| **SWE (Performance)** | 2 (ephemeral) | Primary code work — core logic, complex tasks, critical path. Always deployed first. |
| **SWE (Efficiency)** | 1 (ephemeral) | Tertiary support — side tasks when performance cores are busy. All hands for high-priority work. |
| **QA** | 1 (ephemeral) | Two modes: code review (verifies SWE changes, reviews test files) and Playwright test writing (after AC is met) |

Model assignment is by task difficulty (not role) — TPM decides Opus, Sonnet, or Haiku per agent.

## Boot Sequence

The deploy script prints a compact info panel, then TPM prints structured status lines as it initializes:

```
╭────────────────────────────────────────────────────────────────────────────────────────╮
│                                                                                        │
│   Project SWT vX.Y.Z (Git Bash)                      github.com/T5-labs/Project-SWT   │
│                                                                                        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│   TPM (orchestrator)           1 session                                               │
│   SWE (performance)            2 cores                                                 │
│   SWE (efficiency)             1 core                                                  │
│   QA  (verifier)               1 agent                                                 │
│                                                                                        │
│   cmms-api | bugfix/CMMS-2576-mrir-notification (CMMS-2576)                             │
│   ~/cmms/cmms-api | DB: localhost, 1433.cmms                                           │
│   Feedback: Enabled (3 entries)                                                        │
│   Support: Enabled (3/4 apps mapped)                                                   │
│   Board: https://herzog.atlassian.net/jira/software/c/projects/CMMS/boards/393         │
│   Notes: ~/Documents/Obsidian/aarbuckle                                                │
│                                                                                        │
╰────────────────────────────────────────────────────────────────────────────────────────╯

[swt] ✓ Version: X.Y.Z
[swt] ✓ Config loaded (swt_settings.json)
[swt] ✓ Team: 2 performance + 1 efficiency + 1 QA
[swt] ✓ Branch: bugfix/CMMS-2576-mrir-notification
[swt] ✓ Atlassian: herzog.atlassian.net
[swt] ✓ Ticket: CMMS-2576 (pulled from Jira)
[swt] ✓ Knowledge: CMMS/CMMS.md found
[swt] ✓ Notes: CMMS/2576.md resuming from 2026-04-13
[swt] ✓ Review mode: off (author mode)
[swt] ✓ Work repo: cmms-api (~/cmms/cmms-api)
[swt] ✓ Repo: dotnet, 142 files
[swt] ✓ Ready
```

If any step fails, it prints an X and continues to the next step. If Jira is unavailable, TPM asks you to paste the ticket description.

## Workflow

### Planning Phase (fresh branch)

If `swt --branch` detects a zero-commit branch, TPM auto-deploys 3 SWEs in parallel (architecture, implementation, test-strategy lenses) to plan the implementation from the Jira acceptance criteria. SWEs do not write code; they return structured plan fragments. TPM aggregates, presents the plan, and logs it to the Obsidian ticket notes under `## Implementation Plan`. You review, adjust, then move to the Development Phase.

### Development Phase

1. **Boot** — `swt --branch` pulls the Jira ticket, sets up Obsidian notes, familiarizes with repo
2. **Discuss** — TPM and user talk through implementation, edge cases, trade-offs
3. **Preview (optional)** — For high-risk or large changes, TPM deploys SWEs in preview mode. SWEs plan changes and return a structured preview (files, scope, risks) without editing anything. User approves or adjusts before code is written.
4. **Code** — TPM deploys SWEs with file ownership boundaries. SWEs write code with one-sentence explanations per change.
5. **Regression scan** — SWEs grep test directories for references to modified code and flag potential risks
6. **Review** — TPM deploys QA to verify all changes. QA reviews test files relevant to changed code, flags tests that need updating, and tells the user which test projects to run.
7. **Pre-PR checklist** — TPM runs a CodeRabbit-aware checklist (unintended changes, secrets, dead code, null checks, etc.)
8. **PR description** — TPM generates a two-sentence PR description for Bitbucket
9. **Commit** — User handles all git operations (commit, push, branch)

### Testing Phase (after AC is met)

1. **Generate testing procedures** — TPM and user collaboratively write test scenarios, saved as a `## Testing Procedures` section in the Obsidian ticket notes
2. **Approve** — User reviews and approves the procedures
3. **Playwright tests** — TPM deploys QA to write Playwright specs based on the procedures. QA generates a shared `playwright.config.ts` at the tests root on first use (uses `BASE_URL` env var). Auth uses Edge browser profile via `launchPersistentContext`.
4. **Tests saved** to `Project-SWT/tests/{PROJECT}/{NUMBER}/` (gitignored)

### Session End

When you wrap up, TPM writes a handoff summary to Obsidian notes (completed, in progress, pending, decisions, blockers). Next session picks up where you left off.

## Monitor Mode

Monitor Mode watches a Bitbucket PR for incoming comments and coordinates your response — so you never lose track of a CodeRabbit nitpick or a reviewer question buried in the thread.

### Requirements

- Bitbucket integration must be enabled (`deploy.sh --setup-bitbucket`)
- Must be paired with `--branch`: `swt --branch --monitor`. The ticket is auto-detected from the current git branch name (e.g., a branch named `CMMS-1234-fix-foo` resolves to ticket `CMMS-1234`).
- Mutually exclusive with `--support`
- An open PR must exist on Bitbucket for the current branch. If none is found, TPM prompts to retry or exit.

### How it works

1. TPM resolves the open PR for your current branch, snapshots existing comments (they are not processed), then starts polling every `monitor.interval_seconds` (default: 5 minutes).
2. Each new comment is classified into one of six categories: `nitpick`, `bug`, `style`, `architectural`, `security`, or `question`. Comments are auto-escalated to `risky_change` if they touch .NET-guarded files or exceed the file threshold — `risky_change` is an escalation bucket, not a classifier output.
3. Per-category policy decides what happens: `resolve` auto-deploys a SWE to apply the change; `ask` adds it to the in-session todo list for you to decide. Changes to .NET-guarded files or involving more files than `monitor.risky_change_file_threshold` are automatically escalated to `risky_change`.
4. Type `review` to see the todo list. Respond with `like <n>`, `revert <n>`, or `skip <n>` for each item.
5. Commit and push your changes manually (TPM never does git writes). Then say `posted` — TPM reads the todo list and posts counter-responses back to Bitbucket using your configured `monitor.counter_response_prompt`. Reverted items are skipped — no reply is posted unless you explicitly ask.
6. All activity is logged to the Obsidian ticket notes under `## PR Comments`.
7. Press Ctrl+C to end the session.

### Interaction grammar

| Command | What it does |
|---------|-------------|
| `review` | Show the current todo list of pending comment actions |
| `like <n>` | Mark item N as approved. For resolved items, this confirms the SWE's change. For ask items, this acknowledges the comment without code change. Counter-response posts on `posted`. |
| `revert <n>` | Undo the change made for item N |
| `skip <n>` | Dismiss item N without acting |
| `posted` | Trigger TPM to post counter-responses on Bitbucket for all approved items. Reverted items are silently skipped (unless you explicitly say 'reply on the reverted ones'). |
| `stop monitoring` / `exit monitor` | Halt the polling loop gracefully without exiting the session — TPM remains available for normal interaction |
| Ctrl+C | Stop the monitor session |

> **Multi-item:** Commands accept comma-separated ordinals — e.g., `like 1, 3, 5`, `revert 1, 3`, `skip 2`.

### Example session

```
[TPM] Monitor mode active — watching PR #42 (CMMS-1234)
[TPM] Baseline: 7 existing comments (not processed)
[TPM] Polling every 300s...

[TPM] New comment from coderabbit[bot] on src/Services/EquipmentService.cs:
      "Consider null-checking `equipment` before accessing `.Id`"
      → Classified: nitpick | Policy: resolve
      → Deploying SWE-1 to add null guard

[TPM] SWE-1 complete. Added null check on line 84 of EquipmentService.cs.
      Added to todo list as item #1.

> review
[TPM] Todo list:
  1. [resolved] SWE-1: added null check in EquipmentService.cs (nitpick from coderabbit)
  2. [pending] Architectural concern: "Why is this logic in the service layer?" — awaiting your call

> like 1
> skip 2
> posted
[TPM] Posting counter-responses to PR #42...
[TPM] Done. 1 reply posted.
```

### Configuration (`monitor` block in `swt_settings.json`)

| Setting | Description | Default |
|---------|-------------|---------|
| `monitor.enabled` | Toggle monitor mode capability | `true` |
| `monitor.interval_seconds` | How often to poll Bitbucket for new comments (seconds) | `300` |
| `monitor.risky_change_file_threshold` | Auto-escalate to `risky_change` if a resolved comment touches more files than this | `5` |
| `monitor.categories.{category}.action` | `"resolve"` (auto-apply via SWE) or `"ask"` (surface to user). Categories: `nitpick`, `bug`, `style`, `architectural`, `security`, `question`, `risky_change` | varies |
| `monitor.categories.{category}.prompt` | Additional guidance for TPM when handling this category | varies; see seeded defaults in `deploy.sh` (e.g., `nitpick`: `"Apply the suggestion verbatim if reasonable."`, `style`: `"Match the surrounding style; don't refactor beyond the comment."`, others: `""`) |
| `monitor.counter_response_prompt` | Instruction for TPM when composing replies posted back to Bitbucket | `"Reply professionally and concisely. Acknowledge the comment, state what was done (or why we disagree), and keep it to 1-2 sentences. No double-dashes."` |

> **Note:** `risky_change.action` is always treated as `ask` regardless of config — this is a safety override to prevent auto-applying changes that were escalated specifically because they touched .NET-guarded files (`appsettings`, `.csproj`, etc.) or required NuGet/migration changes.

## Review Mode Posting

Review Mode Posting extends the automatic branch review (triggered on `swt --branch` when commits belong to a colleague) with the ability to share selected findings directly as Bitbucket PR comments. After the 3-SWE security/logic/quality scan completes and findings are displayed with ratings, the user types `post <ordinals>` to select which findings to post.

### Requirements

- Bitbucket integration must be enabled (`deploy.sh --setup-bitbucket`)
- `review.enabled` must be `true` in `swt_settings.json`
- Must be in review mode (branch commits by someone else, detected on `swt --branch`)

### How it works

1. The 3-SWE review scan runs as normal, producing ranked findings — each assigned a `Rating: N/5` (1 = trivial, 5 = critical).
2. The user types `post <ordinals>` to choose findings to share.
3. TPM polishes each selected finding into a 1-2 sentence professional comment using the configured `review.comment_posting_prompt`.
4. TPM shows the polished comments and waits for approval before posting anything.
5. The user responds with `ok` to post, `revise N: <change>` to adjust a specific comment, or `cancel` to abort.
6. TPM posts approved comments via `bb-curl.sh`. Findings with a known `file:line` are placed as inline comments; others go to the PR overview.
7. After posting, TPM annotates the Obsidian `## Branch Review` section with `[posted HH:MM — bitbucket-comment-id #<id>]` per finding.

### Interaction grammar

| Command | What it does |
|---------|-------------|
| `post 1` | Post finding #1 |
| `post 1, 3` | Post findings #1 and #3 |
| `post 2-4` | Post findings #2, #3, and #4 |
| `post all` | Post all findings at or above `min_rating_to_post` |
| `post all security` | Post all security-lens findings at or above `min_rating_to_post` |
| `ok` | Confirm and post all polished comments shown |
| `revise N: <change>` | Ask TPM to revise the polished comment for finding N before posting |
| `cancel` | Abort — no comments are posted |

> **Note:** `min_rating_to_post` only filters `post all` invocations. Explicit ordinals (`post 1`, `post 2-4`, etc.) always override the filter — any finding can be posted regardless of its rating when named directly.

### Example session

```
[TPM] Review mode complete — 6 findings across security, logic, quality lenses.

  1. [security] Rating: 4/5 — SQL query in ReportService.cs:142 builds a WHERE clause by
     string concatenation; parameterize the query to prevent injection.
  2. [logic]    Rating: 2/5 — EquipmentController.cs:88 returns HTTP 200 on a failed save
     instead of 500; update the status code to reflect the error.
  3. [quality]  Rating: 1/5 — Unused import in WorkOrderHelper.cs:3.

> post 1, 2
[TPM] Polishing 2 findings into PR comments...

  Comment 1 (inline → ReportService.cs:142):
    "The WHERE clause in `BuildFilterQuery` constructs SQL by concatenation — parameterize
    this query to prevent SQL injection."

  Comment 2 (inline → EquipmentController.cs:88):
    "This path returns HTTP 200 on a failed save; consider returning 500 or 422 to signal
    the error to callers."

Type ok to post, revise N: <change> to adjust, or cancel to abort.

> ok
[TPM] Posted 2 comments to PR #37.
[TPM] Obsidian ## Branch Review updated with post timestamps and comment IDs.
```

### Configuration (`review` block in `swt_settings.json`)

| Setting | Description | Default |
|---------|-------------|---------|
| `review.enabled` | Toggle review mode posting capability | `true` |
| `review.comment_posting_prompt` | Instruction for TPM when polishing findings into PR comments | `"Polish the finding into a 1-2 sentence professional PR comment. State the issue clearly and suggest a fix when one is obvious. No double-dashes."` |
| `review.min_rating_to_post` | Minimum `Rating: N/5` for a finding to be included when using `post all` | `1` |

## Branch Detection

`swt --branch` extracts the ticket from your git branch name. Supports prefixed and unprefixed branches:

| Branch | Detected Ticket |
|--------|----------------|
| `CMMS-2576-add-login` | CMMS-2576 |
| `bugfix/CMMS-2576-fix-null` | CMMS-2576 |
| `feature/MCP-1234-new-endpoint` | MCP-1234 |
| `HITS-0088-update-dashboard` | HITS-0088 |
| `main` | No match (unconstrained) |

## Rules

- **No destructive git** — Agents use read-only git (`status`, `diff`, `log`, `blame`, `show`) but NEVER write (`commit`, `push`, `add`, `checkout`, `branch`, `merge`, `rebase`, `reset`, `stash`, `pull`)
- **No dotnet commands** — Agents never run any `dotnet` CLI commands (`run`, `test`, `build`, `restore`, `ef`). Only the user runs dotnet. If a build or test run is needed, agents report it.
- **Protect .NET configs** — Never modify `appsettings.json` secrets/connection strings or `launchSettings.json` env values. Flag `.csproj`, `.sln`, and NuGet changes before proceeding.
- **Jira is read-only** — Agents pull ticket context but never modify tickets
- **No deletions** — Agents suggest removals, user executes
- **Obsidian notes** — Only TPM writes to Obsidian; SWEs and QA report back to TPM
- **File ownership** — Parallel SWEs are assigned non-overlapping file scopes to prevent conflicts
- **Database is SELECT only** — Agents query via LINQPad but never modify data or schema

## Directory Structure

Note: `swt_settings.json` lives in your Windows home directory (`C:\Users\<you>\swt_settings.json`), not in this repo.

```
Project-SWT/
├── CLAUDE.md                     # TPM system prompt (loaded via --append-system-prompt-file)
├── README.md                     # This file
├── VERSION                       # Current version
├── deploy.sh                     # The swt command
├── .gitignore                    # Ignores tests/
├── scripts/
│   ├── bb-curl.sh               # Bitbucket REST wrapper (sources secrets locally, never exposes token)
│   ├── clipboard-read.ps1       # Saves Windows clipboard image to temp file
│   └── swt-statusline.sh        # Claude Code statusline hook (SWT version + session tokens + context %)
├── .claude/
│   ├── config/
│   │   └── swt.yml               # Deprecated seed template — used only on first boot
│   ├── settings.json             # Permission settings
│   └── agents/
│       ├── tpm-agent.md          # TPM definition
│       ├── swe-agent.md          # SWE definition
│       └── qa-agent.md           # QA definition
└── tests/                        # Gitignored — Playwright specs only
    ├── playwright.config.ts      # QA (generated once, shared across projects)
    └── {PROJECT}/{NUMBER}/
        └── {project}-{number}.spec.ts  # Written by QA
```

## Obsidian Knowledge Base

```
{obsidian_base_path}/
├── CMMS/
│   ├── CMMS.md                   # Living knowledge base for CMMS project
│   ├── 5412.md                   # Ticket notes for CMMS-5412
│   └── 5423.md                   # Ticket notes for CMMS-5423
```

- **Parent file** (`CMMS/CMMS.md`) — architecture, conventions, gotchas. Agents read first, update with significant discoveries.
- **Ticket notes** (`CMMS/5412.md`) — contains all per-ticket work:
  - `## Ticket Summary` — pulled from Jira at start
  - `## Implementation Plan` — aggregated from planning-mode SWEs (architecture/implementation/test-strategy)
  - `## Implementation Notes` — discussion points, approach decisions
  - `## Changes Made` — one-sentence explanations from SWEs
  - `## Edge Cases` — discovered during development
  - `## Testing Procedures` — written collaboratively by TPM + user
  - `## QA Findings` — from QA review
  - `## Branch Review` — findings from review-mode SWEs (security/logic/quality), each with a `Rating: N/5`; posted findings annotated with `[posted HH:MM — bitbucket-comment-id #<id>]`
  - `## PR Comments` — running log of incoming PR comments, classifications, actions taken, and counter-responses (monitor mode only)
  - `## Session Handoff (date)` — what's done, in progress, pending, decisions, blockers

  Not every section appears in every ticket — Implementation Plan only appears for planning-mode sessions; Branch Review only appears for review-mode sessions; PR Comments only appears for monitor-mode sessions.

## Modes

| Mode | Command | Behavior |
|------|---------|----------|
| **Unconstrained** | `swt` | No ticket context. General team ready for whatever you need. |
| **Constrained** | `swt --branch` | Detects ticket from git branch name. Pulls Jira, sets up Obsidian notes. |
| **Planning (auto)** | `swt --branch` on fresh branch | Constrained mode + 0 commits → 3 SWEs plan the ticket from AC. |
| **Review (auto)** | `swt --branch` on colleague's branch | Constrained mode + commits by others → 3 SWEs review the diff (security/logic/quality lenses). Type `post <ordinals>` to share findings as Bitbucket PR comments (requires Bitbucket integration). |
| **Review (manual)** | mid-session, user says "review the changes" or similar | Constrained or unconstrained — user verbally triggers Review Mode to analyze a branch diff. |
| **Preview (manual)** | mid-session, user or TPM invokes | Dry-run code planning for a specific change. |
| **Support** | `swt --support` | Dedicated multi-app support work. Reads `support.apps` from settings, dispatches 3 SWEs in parallel (Reproduction/Code path/Regression lenses) to investigate across configured app repos. |
| **Monitor** | `swt --branch --monitor` | Watches the PR for new comments (ticket auto-detected from branch name), classifies them, coordinates SWE responses, and posts replies after the user pushes. Requires Bitbucket integration. Runs until Ctrl+C. |
