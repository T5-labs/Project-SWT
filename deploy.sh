#!/bin/bash
# Deploys the SWT agent team — TPM as orchestrator with on-demand SWE/QA subagents.
# Pulls latest Project-SWT from git, then starts claude in the user's cwd.
#
# Usage:
#   swt                      → unconstrained mode (general team, no ticket context)
#   swt --branch             → constrained mode (auto-detect ticket from git branch)
#   swt --CMMS-5412          → constrained mode (manually specify Jira ticket)
#
# Install:
#   See README.md for full setup. Quick version:
#   1. Create ~/bin/swt with: exec ~/Project-SWT/deploy.sh "$@"
#   2. chmod +x ~/bin/swt

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

# Detect current git branch in the work repo (if it's a git repo)
export SWT_BRANCH="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "none")"

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
REMOTE=false

TICKET_COUNT=0
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: swt [options]"
            echo ""
            echo "  swt                    Unconstrained mode (general team, no ticket context)"
            echo "  swt --branch           Constrained mode (auto-detect ticket from git branch)"
            echo "  swt --CMMS-5412        Constrained mode (manually specify ticket)"
            echo "  swt --remote           Enable remote control (can combine with other flags)"
            echo ""
            echo "Run from inside your work repo (Git Bash only)."
            echo "Project-SWT: $SWT_DIR"
            exit 0
            ;;
        --remote)
            REMOTE=true
            ;;
        --branch)
            # Auto-detect ticket from current git branch name
            # Strip optional prefix (bugfix/, feature/, hotfix/, etc.) before matching
            BRANCH_NAME="${SWT_BRANCH##*/}"
            if [ "$SWT_BRANCH" != "none" ] && [[ "$BRANCH_NAME" =~ ^([A-Za-z]+)-([0-9]+) ]]; then
                SWT_PROJECT=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
                SWT_NUMBER="${BASH_REMATCH[2]}"
                SWT_TICKET="${SWT_PROJECT}-${SWT_NUMBER}"
                MODE="constrained"
                export SWT_TICKET
                export SWT_PROJECT
                export SWT_NUMBER
                echo "[swt] Auto-detected ticket from branch: $SWT_TICKET"
            else
                echo "[swt] Could not detect ticket from branch: $SWT_BRANCH"
                echo "[swt] Expected branch format: PROJECT-NUMBER-description (e.g., CMMS-2563-add-login)"
                exit 1
            fi
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

# ── Resolve Database Config ──────────────────────────────────────
DB_ENABLED_RAW=$(grep 'database_enabled' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null | sed 's/.*: *//')
if [ "$DB_ENABLED_RAW" = "true" ]; then
    export SWT_DB_ENABLED="true"
else
    export SWT_DB_ENABLED="false"
fi

LPRUN_RAW=$(grep 'lprun_path' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')
export SWT_LPRUN_PATH="$LPRUN_RAW"

SWT_DB_CONNECTION=""
if [ "$SWT_DB_ENABLED" = "true" ] && [ -n "$SWT_PROJECT" ]; then
    SWT_DB_CONNECTION=$(awk "/- project: $SWT_PROJECT\$/{getline; gsub(/.*connection: *\"|\"$/,\"\"); print}" "$SWT_DIR/.claude/config/swt.yml")
fi
export SWT_DB_CONNECTION

# ── Boot Diagnostics ──────────────────────────────────────────────
DISPLAY_DIR="${WORK_DIR/#${HOME}/\~}"

INFO1="SWT v${VERSION} · ${SWE_PERFORMANCE_CORES} perf + ${SWE_EFFICIENCY_CORES} eff + ${QA_AGENT_COUNT} QA"
if [ "$MODE" = "constrained" ]; then
    INFO2="${SWT_TICKET} · ${SWT_BRANCH}"
else
    INFO2="Unconstrained · ${SWT_BRANCH}"
fi
INFO3="${DISPLAY_DIR}"
if [ "$SWT_DB_ENABLED" = "true" ] && [ -n "$SWT_DB_CONNECTION" ]; then
    INFO3="${INFO3} · DB: ${SWT_DB_CONNECTION}"
fi

# Print a padded line inside the box (handles multi-byte chars like ·)
swt_line() {
    local text="$1" max=85 vis=${#1}
    if [ $vis -gt $max ]; then text="${text:0:$((max-3))}..."; vis=$max; fi
    printf "│   %s%$((max - vis))s│\n" "$text" ""
}

REPO_URL="github.com/T5-labs/Project-SWT"

printf -v BORDER '%88s' ''; BORDER="${BORDER// /─}"
echo ""
echo "╭${BORDER}╮"
printf "│%88s│\n" ""
# Title line: left-aligned name, right-aligned repo link
TITLE="Project SWT"
TITLE_PAD=$((85 - ${#TITLE} - ${#REPO_URL} - 3))
printf "│   %s%${TITLE_PAD}s%s   │\n" "$TITLE" "" "$REPO_URL"
printf "│%88s│\n" ""
echo "├${BORDER}┤"
printf "│%88s│\n" ""
swt_line "$INFO1"
swt_line "$INFO2"
swt_line "$INFO3"
printf "│%88s│\n" ""
echo "╰${BORDER}╯"
echo ""

# ── Launch TPM ────────────────────────────────────────────────────
echo "[swt] Starting TPM v${VERSION} in CLI mode..."
echo "[swt] Work directory: $WORK_DIR"

if [ "$MODE" = "constrained" ]; then
    echo "[swt] Ticket: $SWT_TICKET (project=$SWT_PROJECT, number=$SWT_NUMBER)"
fi

echo ""

# Launch claude with TPM identity loaded from CLAUDE.md + Project-SWT file access
# cwd stays as the user's work repo
CLAUDE_ARGS=(--dangerously-skip-permissions --add-dir "$SWT_DIR" --append-system-prompt-file "$SWT_DIR/CLAUDE.md")

if [ "$REMOTE" = true ]; then
    CLAUDE_ARGS+=(--remote-control)
    echo "[swt] Remote control enabled"
fi

exec claude "${CLAUDE_ARGS[@]}"
