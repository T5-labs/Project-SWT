# Project SWT

A multi-agent development team you deploy from any repo to collaboratively work on Jira tickets. Spring 2026.

## Quick Start

```bash
# cd into your work repo first, then:
swt                    # Unconstrained — general team, no ticket context
swt --branch           # Constrained — auto-detects ticket from git branch name
swt --CMMS-5412        # Constrained — manually specify a Jira ticket
```

## Setup

### Prerequisites

- [Claude Code CLI](https://claude.ai/code) installed and authenticated
- Git Bash (comes with [Git for Windows](https://git-scm.com/download/win))
- A `~/bin` directory on your PATH (create with `mkdir -p ~/bin`)
- Set Git Bash path for Claude Code in `~/.bashrc`:
  ```bash
  export CLAUDE_CODE_GIT_BASH_PATH="C:\Users\aarbuckle\AppData\Local\Programs\Git\bin\bash.exe"
  ```

### Install

1. Clone the repo:
   ```bash
   git clone https://github.com/T5-labs/Project-SWT.git ~/Project-SWT
   ```

2. Create the launcher in `~/bin`:

   ```bash
   echo '#!/bin/bash
   exec ~/Project-SWT/deploy.sh "$@"' > ~/bin/swt
   chmod +x ~/bin/swt
   ```

3. Configure `.claude/config/swt.yml` (see [Configuration](#configuration) below)

### WSL Setup

If you prefer running SWT from WSL instead of Git Bash:

1. Install Claude Code CLI in WSL:
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude auth login
   ```

2. Create the launcher (using the Windows-side clone via `/mnt/c`):
   ```bash
   mkdir -p ~/bin
   echo '#!/bin/bash
   exec /mnt/c/Users/aarbuckle/Project-SWT/deploy.sh "$@"' > ~/bin/swt
   chmod +x ~/bin/swt
   ```

3. Ensure `~/bin` is on your PATH. Add to `~/.bashrc` if needed:
   ```bash
   export PATH="$HOME/bin:$PATH"
   ```

4. Reload your shell and verify:
   ```bash
   source ~/.bashrc
   swt --help
   ```

**Notes:**
- WSL does **not** need the `CLAUDE_CODE_GIT_BASH_PATH` env var — that's Git Bash only
- `deploy.sh` auto-detects WSL and translates Windows paths from `swt.yml` to `/mnt/c/...` format
- The `swt.yml` config file is shared between Git Bash and WSL — no separate config needed
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
| `swt --CMMS-5412` | Constrained mode — manually specify a Jira ticket |
| `swt --remote` | Enable Claude Code remote control (can combine with other flags) |
| `swt --help` | Show usage help |

**Examples:**

```bash
swt --branch                     # Detect ticket from branch, e.g. bugfix/CMMS-2576-fix → CMMS-2576
swt --CMMS-5412                  # Work on CMMS-5412 regardless of branch
swt --branch --remote            # Constrained + remote control
swt --remote                     # Unconstrained + remote control
```

Only one ticket per session. Multiple ticket flags will error.

## Configuration

All configuration lives in `.claude/config/swt.yml`.

### Obsidian

| Setting | Description | Default |
|---------|-------------|---------|
| `obsidian_base_path` | Path to your Obsidian vault where agent notes are stored | `C:\Users\aarbuckle\Documents\Obsidian\aarbuckle` |

### Atlassian / Jira

| Setting | Description |
|---------|-------------|
| `atlassian_cloud_id` | Your Atlassian Cloud tenant ID. If not set, TPM discovers it on first boot via `getAccessibleAtlassianResources`. |
| `atlassian_site` | Your Atlassian site URL (e.g., `herzog.atlassian.net`) |

### Agent Team

| Setting | Description | Default |
|---------|-------------|---------|
| `swe_agent_count` | Total max concurrent SWE subagents | `3` |
| `swe_performance_cores` | Performance SWE cores (primary workers) | `2` |
| `swe_efficiency_cores` | Efficiency SWE cores (side tasks) | `1` |
| `qa_agent_count` | Max concurrent QA subagents | `1` |

### Playwright

| Setting | Description | Default |
|---------|-------------|---------|
| `edge_profile_path` | Path to Microsoft Edge user data directory. Tests use `launchPersistentContext` with this profile to reuse Azure AD sessions. Edge must be closed when running tests. | `C:\Users\aarbuckle\AppData\Local\Microsoft\Edge\User Data` |
| `playwright_headless` | `true` = headless (no browser window), `false` = headed (visible browser, useful for debugging) | `false` |

### Database Access (via LINQPad)

| Setting | Description | Default |
|---------|-------------|---------|
| `database_enabled` | Global toggle for agent database access | `true` |
| `lprun_path` | Path to LINQPad 8 CLI runner | `C:\Program Files\LINQPad8\LPRun8.exe` |
| `databases` | Allowlist mapping Jira project keys to LINQPad connection names. Agents can only query connections in this list. | — |

**Adding a database:**

1. Create a connection in LINQPad 8 and note its exact name
2. Add an entry under `databases:` with the project key and connection name:
   ```yaml
   databases:
     - project: CMMS
       connection: "localhost, 1433.cmms"
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
│   Project SWT v0.16.0 (Git Bash)                      github.com/T5-labs/Project-SWT   │
│                                                                                        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│   TPM (orchestrator)           1 session                                               │
│   SWE (performance)            2 cores                                                 │
│   SWE (efficiency)             1 core                                                  │
│   QA  (verifier)               1 agent                                                 │
│                                                                                        │
│   CMMS-2576 | bugfix/CMMS-2576-mrir-notification                                       │
│   ~/cmms/cmms-api | DB: localhost, 1433.cmms                                           │
│                                                                                        │
╰────────────────────────────────────────────────────────────────────────────────────────╯

[swt] ✓ Version: 0.16.0
[swt] ✓ Config loaded (swt.yml)
[swt] ✓ Team: 2 performance + 1 efficiency + 1 QA
[swt] ✓ Branch: bugfix/CMMS-2576-mrir-notification
[swt] ✓ Atlassian: herzog.atlassian.net
[swt] ✓ Ticket: CMMS-2576 (pulled from Jira)
[swt] ✓ Knowledge: CMMS/CMMS.md found
[swt] ✓ Notes: CMMS/2576.md resuming from 2026-04-13
[swt] ✓ Repo: dotnet, 142 files
[swt] ✓ Ready
```

If any step fails, it prints an X and continues to the next step. If Jira is unavailable, TPM asks you to paste the ticket description.

## Workflow

### Development Phase

1. **Boot** — `swt --branch` or `swt --CMMS-5412` pulls the Jira ticket, sets up Obsidian notes, familiarizes with repo
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

```
Project-SWT/
├── CLAUDE.md                     # TPM system prompt (loaded via --append-system-prompt-file)
├── README.md                     # This file
├── VERSION                       # Current version
├── deploy.sh                     # The swt command
├── .gitignore                    # Ignores tests/
├── .claude/
│   ├── config/
│   │   └── swt.yml               # All configuration (see Configuration section)
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
  - `## Implementation Notes` — discussion points, approach decisions
  - `## Changes Made` — one-sentence explanations from SWEs
  - `## Edge Cases` — discovered during development
  - `## Testing Procedures` — written collaboratively by TPM + user
  - `## QA Findings` — from QA review
  - `## Session Handoff (date)` — what's done, in progress, pending, decisions, blockers

## Modes

| Mode | Command | Behavior |
|------|---------|----------|
| **Unconstrained** | `swt` | No ticket context. General team ready to help with whatever you need. TPM can bootstrap constrained mode mid-session if you reference a ticket. |
| **Constrained (auto)** | `swt --branch` | Detects ticket from your git branch name (e.g., `CMMS-2563-add-login` or `bugfix/CMMS-2563-fix` → `CMMS-2563`). Pulls Jira, sets up Obsidian notes, session scoped to that ticket. |
| **Constrained (manual)** | `swt --CMMS-5412` | Manually specify a ticket. Same behavior as auto, but you choose the ticket regardless of branch. |
