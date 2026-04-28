#!/bin/bash
# Deploys the SWT agent team — TPM as orchestrator with on-demand SWE/QA subagents.
# Pulls latest Project-SWT from git, then starts claude in the user's cwd.
#
# Usage:
#   swt                      → unconstrained mode (general team, no ticket context)
#   swt --branch             → constrained mode (auto-detect ticket from git branch)
#
# Install:
#   See README.md for full setup. Quick version:
#   deploy.sh --setup       → creates ~/bin/swt launcher and updates PATH

set -euo pipefail

# ── Platform Detection ─────────────────────────────────────────────
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
fi
export SWT_IS_WSL="$IS_WSL"

# Detect where the C: drive is actually mounted in WSL (varies by distro/config).
WSL_C_MOUNT=""
if [ "$IS_WSL" = true ]; then
    # Try wslpath first; strip trailing slash
    _wslpath_result="$(wslpath -u 'C:\' 2>/dev/null | sed 's|/$||')"
    if [ -n "$_wslpath_result" ] && [ -d "$_wslpath_result" ]; then
        WSL_C_MOUNT="$_wslpath_result"
    else
        # Fallback: check known alternate mount points
        for _candidate in /mnt/host/c /mnt/c; do
            if [ -d "$_candidate" ]; then
                WSL_C_MOUNT="$_candidate"
                break
            fi
        done
    fi
fi

# Convert a Windows-style path (e.g. C:/Users/...) to native platform format.
# WSL: converts to /mnt/c/Users/... (or the detected mount point).
# Git Bash: passes through unchanged.
to_native_path() {
    local p="$1"
    if [ "$IS_WSL" = true ] && [ -n "$p" ]; then
        # Try wslpath first
        local converted
        converted="$(wslpath -u "$p" 2>/dev/null)"
        if [ -n "$converted" ]; then
            # Verify the converted path's parent directory exists
            local parent_dir
            parent_dir="$(dirname "$converted")"
            if [ -d "$parent_dir" ]; then
                echo "$converted"
                return
            fi
        fi
        # Fallback: manual conversion using detected mount point
        # Strip drive letter (C:/ or C:\) and prepend WSL mount
        local stripped="${p#[A-Za-z]:/}"
        stripped="${stripped#[A-Za-z]:\\}"
        # Convert backslashes to forward slashes
        stripped="${stripped//\\//}"
        echo "${WSL_C_MOUNT}/${stripped}"
    else
        echo "$p"
    fi
}

# Project-SWT directory (where this script lives) — exported so TPM can reference it
export SWT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Agent Team Configuration ───────────────────────────────────────
# Read team-size knobs from swt.yml; fall back to sensible defaults if missing.
SWT_YML="$SWT_DIR/.claude/config/swt.yml"

_yml_scalar() {
    # Read an unquoted scalar value for an anchored top-level key from swt.yml.
    # Returns empty (and exit 0) when the key is missing — caller applies its own default.
    local key="$1"
    { grep "^${key}:" "$SWT_YML" 2>/dev/null || true; } | head -n1 | sed 's/.*: *//' | sed 's/ *#.*//' | tr -d '"' | tr -d '\r'
}

_SWE_AGENT_COUNT_RAW="$(_yml_scalar swe_agent_count)"
_SWE_EFFICIENCY_CORES_RAW="$(_yml_scalar swe_efficiency_cores)"
_SWE_PERFORMANCE_CORES_RAW="$(_yml_scalar swe_performance_cores)"
_QA_AGENT_COUNT_RAW="$(_yml_scalar qa_agent_count)"

export TPM_COUNT=1                                                     # There can only be one TPM
export SWE_AGENT_COUNT="${_SWE_AGENT_COUNT_RAW:-3}"                    # Total max concurrent SWE subagents
export SWE_EFFICIENCY_CORES="${_SWE_EFFICIENCY_CORES_RAW:-1}"          # Routine tasks
export SWE_PERFORMANCE_CORES="${_SWE_PERFORMANCE_CORES_RAW:-2}"        # Complex tasks
export QA_AGENT_COUNT="${_QA_AGENT_COUNT_RAW:-1}"                      # Max concurrent QA subagents
# ───────────────────────────────────────────────────────────────────

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

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: swt [options]"
            echo ""
            echo "  swt                    Unconstrained mode (general team, no ticket context)"
            echo "  swt --branch           Constrained mode (auto-detect ticket from git branch)"
            echo "  swt --remote           Enable remote control (can combine with other flags)"
            echo "  swt --setup            Install the swt launcher into ~/bin and update PATH"
            echo ""
            echo "Run from inside your work repo (Git Bash or WSL)."
            echo "Project-SWT: $SWT_DIR"
            exit 0
            ;;
        --setup)
            echo "[swt] Running setup..."
            LAUNCHER_DIR="$HOME/bin"
            LAUNCHER_PATH="$LAUNCHER_DIR/swt"

            # Compute WIN_SWT_DIR — Windows-format path with forward slashes
            WIN_SWT_DIR=""
            # Try Git Bash's pwd -W (returns C:/Users/... natively)
            WIN_SWT_DIR="$(cd "$SWT_DIR" && pwd -W 2>/dev/null)" || true
            if [ -z "$WIN_SWT_DIR" ]; then
                # Try WSL wslpath
                WIN_SWT_DIR="$(wslpath -w "$SWT_DIR" 2>/dev/null | tr '\\' '/')" || true
            fi
            if [ -z "$WIN_SWT_DIR" ]; then
                # Fallback: use SWT_DIR as-is
                WIN_SWT_DIR="$SWT_DIR"
            fi

            # Create ~/bin if it doesn't exist
            if [ ! -d "$LAUNCHER_DIR" ]; then
                mkdir -p "$LAUNCHER_DIR"
                echo "[swt] Created $LAUNCHER_DIR"
            fi

            # Write the cross-platform launcher using a quoted heredoc (no expansion),
            # then substitute the placeholder with the actual Windows-format path.
            cat > "$LAUNCHER_PATH" <<'EOF'
#!/bin/bash
# SWT launcher — cross-platform (Git Bash + WSL)
SWT_DIR_WIN="__SWT_DIR_WIN__"
if grep -qi microsoft /proc/version 2>/dev/null; then
    SWT_DIR="$(wslpath -u "$SWT_DIR_WIN" 2>/dev/null)"
    if [ ! -d "$SWT_DIR" ]; then
        # Fallback for non-standard WSL mount points
        DRIVE="${SWT_DIR_WIN%%:*}"
        REST="${SWT_DIR_WIN#*:/}"
        DRIVE_LOWER="$(echo "$DRIVE" | tr '[:upper:]' '[:lower:]')"
        for prefix in /mnt/$DRIVE_LOWER /mnt/host/$DRIVE_LOWER; do
            if [ -d "$prefix/$REST" ]; then
                SWT_DIR="$prefix/$REST"
                break
            fi
        done
    fi
else
    SWT_DIR="$SWT_DIR_WIN"
fi
exec "$SWT_DIR/deploy.sh" "$@"
EOF
            sed -i "s|__SWT_DIR_WIN__|$WIN_SWT_DIR|" "$LAUNCHER_PATH"
            chmod +x "$LAUNCHER_PATH"
            echo "[swt] Launcher written to $LAUNCHER_PATH"

            # Check if ~/bin is already on PATH
            if echo ":$PATH:" | grep -q ":$LAUNCHER_DIR:"; then
                echo "[swt] $LAUNCHER_DIR is already on your PATH"
            else
                # Detect shell rc file
                if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
                    RC_FILE="$HOME/.zshrc"
                else
                    RC_FILE="$HOME/.bashrc"
                fi
                echo "" >> "$RC_FILE"
                echo 'export PATH="$HOME/bin:$PATH"' >> "$RC_FILE"
                echo "[swt] Added PATH entry to $RC_FILE"
                echo "[swt] Run: source $RC_FILE  (or open a new terminal)"
            fi

            echo "[swt] Setup complete. Run: swt --help"
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
        *)
            echo "[swt] unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# ── Validate Obsidian Path ────────────────────────────────────────
OBSIDIAN_PATH_RAW=$({ grep '^obsidian_base_path:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')
OBSIDIAN_PATH=$(to_native_path "$OBSIDIAN_PATH_RAW")
export SWT_OBSIDIAN_PATH="$OBSIDIAN_PATH"
if [ -n "$OBSIDIAN_PATH" ] && [ ! -d "$OBSIDIAN_PATH" ]; then
    echo "[swt] Warning: Obsidian base path does not exist: $OBSIDIAN_PATH"
    echo "[swt] Agents will create it on first use, or update .claude/config/swt.yml"
fi

# ── Resolve Database Config ──────────────────────────────────────
DB_ENABLED_RAW=$({ grep '^database_enabled:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *//')
if [ "$DB_ENABLED_RAW" = "true" ]; then
    export SWT_DB_ENABLED="true"
else
    export SWT_DB_ENABLED="false"
fi

LPRUN_RAW=$({ grep '^lprun_path:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')
export SWT_LPRUN_PATH=$(to_native_path "$LPRUN_RAW")

EDGE_PROFILE_RAW=$({ grep '^edge_profile_path:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')
export SWT_EDGE_PROFILE_PATH=$(to_native_path "$EDGE_PROFILE_RAW")

SWT_PLAYWRIGHT_HEADLESS=$({ grep '^playwright_headless:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *//')
export SWT_PLAYWRIGHT_HEADLESS="${SWT_PLAYWRIGHT_HEADLESS:-false}"

SWT_DB_CONNECTION=""
if [ "$SWT_DB_ENABLED" = "true" ] && [ -n "$SWT_PROJECT" ]; then
    SWT_DB_CONNECTION=$(awk "/- project: $SWT_PROJECT\$/{getline; gsub(/.*connection: *\"|\"$/,\"\"); print}" "$SWT_DIR/.claude/config/swt.yml")
fi
export SWT_DB_CONNECTION

# ── Resolve Feedback Config ──────────────────────────────────────
# Long-running feedback log: TPM checks this file on startup and asks the user
# if they want to revisit prior ideas. Path auto-resolves to the user's Windows
# home directory when feedback_path is empty (works for any user/colleague).
FEEDBACK_ENABLED_RAW=$({ grep '^feedback_enabled:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *//' | sed 's/ *#.*//' | tr -d '"' | tr -d '\r')
FEEDBACK_PATH_RAW=$({ grep '^feedback_path:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')

if [ "${FEEDBACK_ENABLED_RAW:-true}" = "false" ]; then
    export SWT_FEEDBACK_ENABLED="false"
    export SWT_FEEDBACK_PATH=""
else
    # Default ON unless explicitly disabled.
    FEEDBACK_DIR=""
    if [ -n "$FEEDBACK_PATH_RAW" ]; then
        FEEDBACK_DIR=$(to_native_path "$FEEDBACK_PATH_RAW")
        if [ ! -d "$FEEDBACK_DIR" ]; then
            echo "[swt] Warning: Feedback path does not exist: $FEEDBACK_DIR"
            echo "[swt] Agents will create it on first use, or update .claude/config/swt.yml"
        fi
    elif [ "$IS_WSL" = true ]; then
        # Derive Windows username from whoami.exe (e.g. HOSTNAME\user → user).
        WIN_USER="$(whoami.exe 2>/dev/null | sed 's|.*\\||' | tr -d '\r\n')"
        if [ -n "$WIN_USER" ] && [ -n "$WSL_C_MOUNT" ]; then
            FEEDBACK_DIR="${WSL_C_MOUNT}/Users/${WIN_USER}"
        fi
    else
        # Git Bash: USERPROFILE points at the Windows home in native form.
        if [ -n "${USERPROFILE:-}" ]; then
            FEEDBACK_DIR=$(to_native_path "${USERPROFILE//\\//}")
        fi
    fi

    if [ -n "$FEEDBACK_DIR" ]; then
        export SWT_FEEDBACK_ENABLED="true"
        export SWT_FEEDBACK_PATH="${FEEDBACK_DIR}/swt_feedback.md"
    else
        echo "[swt] ⚠ Feedback: could not resolve user home, disabling"
        export SWT_FEEDBACK_ENABLED="false"
        export SWT_FEEDBACK_PATH=""
    fi
fi

# ── Resolve Board Config ────────────────────────────────────────
SWT_BOARD_URL=$({ grep '^board_url:' "$SWT_DIR/.claude/config/swt.yml" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//')
export SWT_BOARD_URL

# ── Boot Diagnostics ──────────────────────────────────────────────
if [ "$IS_WSL" = true ]; then PLATFORM="WSL"; else PLATFORM="Git Bash"; fi

INFO1="TPM (orchestrator)           ${TPM_COUNT} session"
INFO2="SWE (performance)            ${SWE_PERFORMANCE_CORES} cores"
INFO3="SWE (efficiency)             ${SWE_EFFICIENCY_CORES} core"
INFO4="QA  (verifier)               ${QA_AGENT_COUNT} agent"

INFO_PROJECT=""
INFO_TICKET=""
if [ "$MODE" = "constrained" ]; then
    INFO_PROJECT="Project: ${SWT_PROJECT}"
    INFO_TICKET="Ticket: ${SWT_NUMBER}"
fi

if [ "$SWT_DB_ENABLED" = "true" ] && [ -n "$SWT_DB_CONNECTION" ]; then
    INFO_DB="DB: ${SWT_DB_CONNECTION}"
else
    INFO_DB="DB: disabled"
fi

if [ "$SWT_FEEDBACK_ENABLED" = "true" ]; then
    FEEDBACK_COUNT=0
    if [ -f "$SWT_FEEDBACK_PATH" ]; then
        # grep -c returns exit 1 when no lines match — guard against pipefail.
        FEEDBACK_COUNT=$({ grep -c '^- ' "$SWT_FEEDBACK_PATH" 2>/dev/null || true; } | head -n1)
        FEEDBACK_COUNT="${FEEDBACK_COUNT:-0}"
    fi
    if [ "$FEEDBACK_COUNT" -gt 0 ] 2>/dev/null; then
        INFO_FEEDBACK="Feedback: Enabled (${FEEDBACK_COUNT} items)"
    else
        INFO_FEEDBACK="Feedback: Enabled"
    fi
else
    INFO_FEEDBACK="Feedback: Disabled"
fi

INFO_BOARD=""
if [ -n "$SWT_BOARD_URL" ]; then
    INFO_BOARD="Board: ${SWT_BOARD_URL}"
fi

DISPLAY_OBSIDIAN="${SWT_OBSIDIAN_PATH/#${HOME}/\~}"
INFO_NOTES="Notes: ${DISPLAY_OBSIDIAN}"

# Print a padded line inside the box
swt_line() {
    local text="$1"
    local vis=${#text} max=85
    if [ $vis -gt $max ]; then text="${text:0:$((max-3))}..."; vis=$max; fi
    printf -v pad '%*s' $((max - vis)) ''
    echo "│   ${text}${pad}│"
}

REPO_URL="github.com/T5-labs/Project-SWT"

printf -v BORDER '%88s' ''; BORDER="${BORDER// /─}"
echo ""
echo "╭${BORDER}╮"
printf "│%88s│\n" ""
# Title line: left-aligned name + version, right-aligned repo link
TITLE="Project SWT v${VERSION} (${PLATFORM})"
TITLE_PAD=$((85 - ${#TITLE} - ${#REPO_URL} - 3))
if [ $TITLE_PAD -lt 1 ]; then TITLE_PAD=1; fi
printf "│   %s%${TITLE_PAD}s%s   │\n" "$TITLE" "" "$REPO_URL"
printf "│%88s│\n" ""
echo "├${BORDER}┤"
printf "│%88s│\n" ""
swt_line "$INFO1"
swt_line "$INFO2"
swt_line "$INFO3"
swt_line "$INFO4"
printf "│%88s│\n" ""
if [ -n "$INFO_PROJECT" ]; then
    swt_line "$INFO_PROJECT"
fi
if [ -n "$INFO_TICKET" ]; then
    swt_line "$INFO_TICKET"
fi
swt_line "$INFO_DB"
swt_line "$INFO_FEEDBACK"
if [ -n "$INFO_BOARD" ]; then
    swt_line "$INFO_BOARD"
fi
swt_line "$INFO_NOTES"
printf "│%88s│\n" ""
echo "╰${BORDER}╯"
echo ""

# ── Launch TPM ────────────────────────────────────────────────────
echo "[swt] Starting TPM v${VERSION} in CLI mode..."
echo ""

# Launch claude with TPM identity loaded from CLAUDE.md + Project-SWT file access
# cwd stays as the user's work repo
CLAUDE_ARGS=(--dangerously-skip-permissions --add-dir "$SWT_DIR" --append-system-prompt-file "$SWT_DIR/CLAUDE.md")

if [ "$REMOTE" = true ]; then
    CLAUDE_ARGS+=(--remote-control)
    echo "[swt] Remote control enabled"
fi

if ! command -v claude &>/dev/null; then
    echo "[swt] Error: 'claude' command not found."
    if [ "$IS_WSL" = true ]; then
        echo "[swt] Install Node.js and Claude Code in WSL:"
        echo "[swt]   curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
        echo "[swt]   sudo apt-get install -y nodejs"
        echo "[swt]   npm install -g @anthropic-ai/claude-code"
        echo "[swt]   claude auth login"
    else
        echo "[swt] Install: https://claude.ai/code"
    fi
    exit 1
fi

# Verify claude actually runs (catches WSL finding Windows-side shim without node)
if ! claude --version &>/dev/null; then
    echo "[swt] Error: 'claude' was found at $(command -v claude) but failed to run."
    if [ "$IS_WSL" = true ]; then
        echo "[swt] WSL is likely finding the Windows Claude installation, but Node.js"
        echo "[swt] is not installed natively in WSL."
        echo "[swt]"
        echo "[swt] Install Node.js and Claude Code in WSL:"
        echo "[swt]   curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
        echo "[swt]   sudo apt-get install -y nodejs"
        echo "[swt]   npm install -g @anthropic-ai/claude-code"
        echo "[swt]   claude auth login"
    else
        echo "[swt] Try reinstalling: https://claude.ai/code"
    fi
    exit 1
fi

exec claude "${CLAUDE_ARGS[@]}" "initiate"
