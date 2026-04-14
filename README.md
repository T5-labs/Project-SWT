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

3. Configure `.claude/config/swt.yml`:
   - `obsidian_base_path` — path to your Obsidian vault (default: `C:\Users\aarbuckle\Documents\Obsidian\aarbuckle`)
   - `atlassian_cloud_id` — your Atlassian Cloud tenant ID (find via Atlassian admin or let TPM discover it on first boot)
   - `atlassian_site` — your Atlassian site URL (e.g., `herzog.atlassian.net`)

### Verify

```bash
swt --help
```

## Team

| Role | Count | Purpose |
|------|-------|---------|
| **TPM** | 1 (long-running) | Orchestrator, discussion partner, edge case hunter, generates testing procedures, writes all Obsidian notes |
| **SWE (Performance)** | 2 (ephemeral) | Primary code work — core logic, complex tasks, critical path. Always deployed first. |
| **SWE (Efficiency)** | 1 (ephemeral) | Tertiary support — side tasks when performance cores are busy. All hands for high-priority work. |
| **QA** | 1 (ephemeral) | Two modes: code review (verifies SWE changes) and Playwright test writing (after AC is met) |

Model assignment is by task difficulty (not role) — TPM decides Opus, Sonnet, or Haiku per agent.

## Boot Sequence

When TPM starts, it prints structured status lines:

```
[swt] ✓ Version: 0.7.2
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
6. **Review** — TPM deploys QA to verify all changes. QA cross-references SWE regression findings. Reports PASS/FAIL.
7. **Pre-PR checklist** — TPM runs a CodeRabbit-aware checklist (unintended changes, secrets, dead code, null checks, etc.)
8. **PR description** — TPM generates a two-sentence PR description for Bitbucket
9. **Commit** — User handles all git operations (commit, push, branch)

### Testing Phase (after AC is met)

1. **Generate testing procedures** — TPM and user collaboratively write test scenarios
2. **Approve** — User reviews and approves the procedures
3. **Playwright tests** — TPM deploys QA to write Playwright specs based on the procedures. QA generates a shared `playwright.config.ts` at the tests root on first use (uses `BASE_URL` env var, works for any project).
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

- **No destructive git** — Agents use read-only git (`status`, `diff`, `log`, `blame`, `show`) but NEVER write (`commit`, `push`, `add`, `checkout`, `branch`, `merge`, `reset`, `stash`, `pull`)
- **No dotnet ef** — Agents never run database migration commands. Aware that `dotnet run`/`dotnet test` can trigger implicit migrations.
- **Protect .NET configs** — Never modify `appsettings.json` secrets/connection strings or `launchSettings.json` env values. Flag `.csproj`, `.sln`, and NuGet changes before proceeding.
- **Jira is read-only** — Agents pull ticket context but never modify tickets
- **No deletions** — Agents suggest removals, user executes
- **Obsidian notes** — Only TPM writes to Obsidian; SWEs and QA report back to TPM
- **File ownership** — Parallel SWEs are assigned non-overlapping file scopes to prevent conflicts

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
│   │   └── swt.yml               # Obsidian path, core allocation, Atlassian config
│   ├── settings.json             # Permission settings
│   └── agents/
│       ├── tpm-agent.md          # TPM definition
│       ├── swe-agent.md          # SWE definition
│       └── qa-agent.md           # QA definition
└── tests/                        # Gitignored — per-ticket Playwright tests
    ├── playwright.config.ts      # QA (generated once, shared across projects)
    └── {PROJECT}/{NUMBER}/
        ├── test-procedures.md    # Generated by TPM + user
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
- **Ticket notes** (`CMMS/5412.md`) — Jira summary, implementation notes, SWE changes, edge cases, QA findings, session handoff.

## Modes

| Mode | Command | Behavior |
|------|---------|----------|
| **Unconstrained** | `swt` | No ticket context. General team ready to help with whatever you need. TPM can bootstrap constrained mode mid-session if you reference a ticket. |
| **Constrained (auto)** | `swt --branch` | Detects ticket from your git branch name (e.g., `CMMS-2563-add-login` or `bugfix/CMMS-2563-fix` → `CMMS-2563`). Pulls Jira, sets up Obsidian notes, session scoped to that ticket. |
| **Constrained (manual)** | `swt --CMMS-5412` | Manually specify a ticket. Same behavior as auto, but you choose the ticket regardless of branch. |
