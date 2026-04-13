#!/bin/bash
# Deploys the SWT agent team — TPM as orchestrator with on-demand SWE/QA subagents.
# Pulls latest Project-SWT from git, then starts claude in the user's cwd.
#
# Usage:
#   swt                      → unconstrained mode (no ticket context)
#   swt --CMMS-5412          → constrained mode (pulls Jira ticket, sets up Obsidian notes)
#
# Install:
#   Add this script's directory to your PATH, or symlink it:
#   ln -s /path/to/Project-SWT/deploy.sh /usr/local/bin/swt

set -e

# ── Agent Team Configuration ───────────────────────────────────────
export TPM_COUNT=1                # There can only be one TPM
export SWE_AGENT_COUNT=3          # Total max concurrent SWE subagents
export SWE_EFFICIENCY_CORES=1     # Routine tasks
export SWE_PERFORMANCE_CORES=2    # Complex tasks
export QA_AGENT_COUNT=1           # Max concurrent QA subagents
# ───────────────────────────────────────────────────────────────────

# Project-SWT directory (where this script lives) — exported so TPM can reference it
export SWT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Save the user's current working directory — this is the work repo
WORK_DIR="$(pwd)"

# Pull latest Project-SWT agent definitions
echo "[swt] Pulling latest agent definitions..."
cd "$SWT_DIR"
git pull --ff-only 2>/dev/null || echo "[swt] git pull skipped — continuing with local version"
cd "$WORK_DIR"

VERSION="$(cat "$SWT_DIR/VERSION" 2>/dev/null || echo "unknown")"

# ── Parse Arguments ────────────────────────────────────────────────
SWT_TICKET=""
SWT_PROJECT=""
SWT_NUMBER=""
MODE="unconstrained"

TICKET_COUNT=0
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: swt [--PROJECT-NUMBER]"
            echo ""
            echo "  swt                    Unconstrained mode (ad-hoc tasks)"
            echo "  swt --CMMS-5412        Constrained mode (scoped to Jira ticket)"
            echo ""
            echo "Run from inside your work repo (Git Bash only)."
            echo "Project-SWT: $SWT_DIR"
            exit 0
            ;;
        --*)
            # Parse --PROJECT-NUMBER (e.g., --CMMS-5412)
            TICKET="${arg#--}"
            if [[ "$TICKET" =~ ^([A-Za-z]+)-([0-9]+)$ ]]; then
                TICKET_COUNT=$((TICKET_COUNT + 1))
                if [ "$TICKET_COUNT" -gt 1 ]; then
                    echo "[swt] Error: only one ticket per session."
                    echo "[swt] Got multiple ticket arguments. Run separate sessions for each ticket."
                    exit 1
                fi
                # Normalize project name to uppercase for consistent Obsidian folders
                SWT_PROJECT=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
                SWT_NUMBER="${BASH_REMATCH[2]}"
                SWT_TICKET="${SWT_PROJECT}-${SWT_NUMBER}"
                MODE="constrained"
                export SWT_TICKET
                export SWT_PROJECT
                export SWT_NUMBER
            else
                echo "[swt] Invalid ticket format: $arg"
                echo "[swt] Expected: --PROJECT-NUMBER (e.g., --CMMS-5412)"
                exit 1
            fi
            ;;
    esac
done

# ── Validate Obsidian Path ────────────────────────────────────────
OBSIDIAN_PATH=$(grep 'obsidian_base_path' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')
if [ -n "$OBSIDIAN_PATH" ] && [ ! -d "$OBSIDIAN_PATH" ]; then
    echo "[swt] Warning: Obsidian base path does not exist: $OBSIDIAN_PATH"
    echo "[swt] Agents will create it on first use, or update .claude/config/swt.yml"
fi

# ── Boot Diagnostics ──────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│  SWT (Software Team) v${VERSION}                      │"
echo "├─────────────────────────────────────────────────┤"
echo "│  TPM (orchestrator)           ${TPM_COUNT} session          │"
echo "│  SWE cores (total)            ${SWE_AGENT_COUNT} agents           │"
echo "│    ├─ Efficiency              ${SWE_EFFICIENCY_CORES} core             │"
echo "│    └─ Performance             ${SWE_PERFORMANCE_CORES} cores            │"
echo "│  QA (verifier)                ${QA_AGENT_COUNT} agent            │"
echo "├─────────────────────────────────────────────────┤"

if [ "$MODE" = "constrained" ]; then
    echo "│  Mode: Constrained (ticket)                     │"
    echo "│  Ticket: ${SWT_TICKET}                                  │"
else
    echo "│  Mode: Unconstrained (ad-hoc)                   │"
fi

echo "│  Work dir: ${WORK_DIR}"
echo "└─────────────────────────────────────────────────┘"
echo ""

# ── Launch TPM ────────────────────────────────────────────────────
echo "[swt] Starting TPM v${VERSION} in CLI mode..."
echo "[swt] Work directory: $WORK_DIR"

if [ "$MODE" = "constrained" ]; then
    echo "[swt] Ticket: $SWT_TICKET (project=$SWT_PROJECT, number=$SWT_NUMBER)"
fi

echo ""

# Launch claude with Project-SWT added for CLAUDE.md discovery + file access
# cwd stays as the user's work repo
exec claude --dangerously-skip-permissions --add-dir "$SWT_DIR"
