#!/usr/bin/env bash
# lprun-query.sh — Run a SQL query via LINQPad's CLI runner without leaving
# .sql files in the work repo.
#
# Purpose:
#   `lprun8` (LINQPad's CLI runner) accepts only a path to a script file —
#   it does not take an inline query string. Without a wrapper, agents end
#   up writing scratch `.sql` files into the active work repo, which can
#   pollute `git status` and risks accidental commits. This script owns
#   the temp file lifecycle: it writes the SQL to a Windows-accessible
#   scratch directory OUTSIDE the work repo, invokes `lprun8` against the
#   translated Windows path, and removes the temp file on exit (including
#   error / Ctrl+C). Agents call this wrapper and never touch .sql files
#   themselves.
#
# Dependencies:
#   - bash, mktemp, wslpath (WSL only)
#   - $SWT_LPRUN_PATH — absolute (WSL-style) path to lprun8.exe, exported
#                       by deploy.sh after resolving `paths.lprun` from
#                       swt_settings.json.
#
# Usage:
#   lprun-query.sh -c <connection> "<inline SQL>"
#   echo "<SQL>" | lprun-query.sh -c <connection>
#   cat <<'EOF' | lprun-query.sh -c <connection>
#   SELECT TOP 10 t.Id, t.Name FROM Asset t WHERE t.IsActive = 1
#   EOF
#   lprun-query.sh -h    # help
#
# Examples:
#   lprun-query.sh -c "localhost, 1433.cmms" "SELECT TOP 10 Id, Name FROM Asset"
#   echo "SELECT 1" | lprun-query.sh -c "localhost, 1433.cmms"
#
# Exit codes:
#   0   success (passthrough of lprun8's exit code on success)
#   1   missing required env / lprun8 binary / write failure / no connection
#   2   misuse (e.g. -c without a value, unknown flag)
#   *   non-zero exit code from lprun8 is passed back unchanged
#
# Hard rules respected:
#   - Connection name is REQUIRED via `-c` — never defaulted.
#   - This script's cleanup of its own scratch file under
#     /mnt/c/Users/$USER/AppData/Local/Temp/swt-queries/ is wrapper-managed
#     (NOT the agent doing a `rm`). The "no deletions" rule for agents
#     applies to project files in the work repo, not to wrapper-owned
#     scratch files.
#   - SELECT-only is enforced upstream by SWE/QA agent rules and the
#     `database.allowlist` in swt_settings.json — this wrapper does not
#     parse SQL and does not relax those constraints.
#
# Note: deliberately uses `set -uo pipefail` (no `-e`) so we control error
# flow explicitly via early `exit` calls with clear messages on stderr.

set -uo pipefail

# ---------------------------------------------------------------------------
# Help text — printed on `-h`, `--help`, or no args + no stdin.
# ---------------------------------------------------------------------------
_print_help() {
    cat >&2 <<'EOF'
lprun-query — Run a SQL query via LINQPad's CLI runner (lprun8)

Usage:
  lprun-query.sh -c <connection> "<inline SQL>"
  echo "<SQL>" | lprun-query.sh -c <connection>
  cat <<'EOF' | lprun-query.sh -c <connection>
  SELECT TOP 10 t.Id, t.Name FROM Asset t WHERE t.IsActive = 1
  EOF

Options:
  -c <connection>   LINQPad connection name (required, no default).
                    Quote names with commas/spaces, e.g. "localhost, 1433.cmms".
  -h, --help        Show this help and exit.

Behavior:
  - SQL is read from a single positional argument OR from stdin when no
    positional is given.
  - The wrapper writes SQL to a unique temp file under
    /mnt/c/Users/$USER/AppData/Local/Temp/swt-queries/, invokes lprun8 with
    -lang=SQL -format=csv against the Windows-translated path, and removes
    the temp file on exit (including Ctrl+C / errors).
  - Output from lprun8 is printed to stdout unchanged.

Required env (set by deploy.sh):
  SWT_LPRUN_PATH    Absolute (WSL-style) path to lprun8.exe.

Hard rules (enforced upstream by agent definitions):
  - SELECT-only — never INSERT/UPDATE/DELETE/DROP/ALTER/CREATE/TRUNCATE/EXEC.
  - Connection name MUST come from the swt_settings.json database.allowlist
    (passed via TPM's assignment).
EOF
}

# ---------------------------------------------------------------------------
# 1. Argument intake.
# ---------------------------------------------------------------------------
connection=""
inline_sql=""
have_inline_sql=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            _print_help
            exit 0
            ;;
        -c)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                echo "[lprun-query] -c requires a connection name argument" >&2
                exit 2
            fi
            connection="$2"
            shift 2
            ;;
        -c=*)
            connection="${1#-c=}"
            if [ -z "$connection" ]; then
                echo "[lprun-query] -c requires a connection name argument" >&2
                exit 2
            fi
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[lprun-query] unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [ "$have_inline_sql" -eq 1 ]; then
                echo "[lprun-query] only one positional SQL argument is supported (got extra: $1)" >&2
                exit 2
            fi
            inline_sql="$1"
            have_inline_sql=1
            shift
            ;;
    esac
done

# Any leftover args after `--` are treated as SQL fragments only if no
# inline SQL was supplied; otherwise reject for clarity.
if [ "$#" -gt 0 ]; then
    if [ "$have_inline_sql" -eq 1 ]; then
        echo "[lprun-query] unexpected extra arguments after SQL: $*" >&2
        exit 2
    fi
    inline_sql="$*"
    have_inline_sql=1
fi

# ---------------------------------------------------------------------------
# 2. Help short-circuit: no connection AND no SQL AND stdin is a TTY -> help.
#    This makes a bare `lprun-query.sh` invocation print help, while a
#    pipe like `echo ... | lprun-query.sh -c foo` still proceeds.
# ---------------------------------------------------------------------------
if [ -z "$connection" ] && [ "$have_inline_sql" -eq 0 ] && [ -t 0 ]; then
    _print_help
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Validate connection.
# ---------------------------------------------------------------------------
if [ -z "$connection" ]; then
    echo "[lprun-query] connection name is required (use -c \"<connection>\")" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Validate lprun8 binary path.
# ---------------------------------------------------------------------------
if [ -z "${SWT_LPRUN_PATH:-}" ]; then
    echo "[lprun-query] SWT_LPRUN_PATH is not set — is the SWT environment loaded? (deploy.sh exports it from swt_settings.json paths.lprun)" >&2
    exit 1
fi

if [ ! -f "$SWT_LPRUN_PATH" ]; then
    echo "[lprun-query] SWT_LPRUN_PATH does not point to an existing file: $SWT_LPRUN_PATH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Resolve SQL source: positional arg OR stdin.
#    If no positional and stdin is a TTY (no pipe), error — there is no SQL
#    to run. (The help short-circuit above already handled the bare-invocation
#    case where no connection is present either.)
# ---------------------------------------------------------------------------
if [ "$have_inline_sql" -eq 0 ]; then
    if [ -t 0 ]; then
        echo "[lprun-query] no SQL provided — pass as positional arg or pipe via stdin" >&2
        exit 1
    fi
    # Read all of stdin into inline_sql. Use IFS= and -r to preserve content.
    inline_sql="$(cat)"
fi

if [ -z "${inline_sql// /}" ]; then
    echo "[lprun-query] empty SQL — nothing to run" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Prepare scratch directory and temp file. Directory lives OUTSIDE the
#    work repo, in the user's Windows %TEMP% so lprun8 (a Windows binary)
#    can read it after wslpath translation.
# ---------------------------------------------------------------------------
_swt_user="${USER:-$(id -un 2>/dev/null)}"
if [ -z "$_swt_user" ]; then
    echo "[lprun-query] could not determine current user (\$USER unset and id -un failed)" >&2
    exit 1
fi

scratch_dir="/mnt/c/Users/${_swt_user}/AppData/Local/Temp/swt-queries"
if ! mkdir -p "$scratch_dir" 2>/dev/null; then
    echo "[lprun-query] failed to create scratch directory: $scratch_dir" >&2
    exit 1
fi

tempfile="$(mktemp "${scratch_dir}/q.XXXXXXXX.sql" 2>/dev/null)" || tempfile=""
if [ -z "$tempfile" ] || [ ! -f "$tempfile" ]; then
    echo "[lprun-query] failed to create temp file under $scratch_dir" >&2
    exit 1
fi

# Cleanup trap — fires on normal exit, error, and signal-driven termination
# (bash runs EXIT after handling INT/TERM/HUP, which is sufficient here).
trap 'rm -f "$tempfile" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# 7. Write SQL to the temp file.
# ---------------------------------------------------------------------------
if ! printf '%s\n' "$inline_sql" > "$tempfile" 2>/dev/null; then
    echo "[lprun-query] failed to write SQL to temp file" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 8. Translate the temp path to Windows for lprun8 (a Windows binary).
# ---------------------------------------------------------------------------
win_tempfile=""
if command -v wslpath >/dev/null 2>&1; then
    win_tempfile="$(wslpath -w "$tempfile" 2>/dev/null)"
fi
if [ -z "$win_tempfile" ]; then
    # Fallback: synthesize a Windows path from /mnt/c/...
    case "$tempfile" in
        /mnt/[a-zA-Z]/*)
            drive_letter="${tempfile:5:1}"
            rest="${tempfile:7}"
            # shellcheck disable=SC2018,SC2019
            drive_upper="$(echo "$drive_letter" | tr 'a-z' 'A-Z')"
            win_tempfile="${drive_upper}:\\${rest//\//\\}"
            ;;
        *)
            echo "[lprun-query] could not translate temp path to Windows: $tempfile" >&2
            exit 1
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 9. Invoke lprun8. Output flows to stdout. The trap will clean up the
#    temp file on exit regardless of lprun8's exit code.
# ---------------------------------------------------------------------------
"$SWT_LPRUN_PATH" \
    -cxname="$connection" \
    -lang=SQL \
    -format=csv \
    "$win_tempfile"
rc=$?

exit "$rc"
