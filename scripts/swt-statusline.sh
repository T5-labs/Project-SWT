#!/usr/bin/env bash
# swt-statusline.sh — Claude Code statusLine hook for Project-SWT.
#
# Emits exactly one line on stdout (no trailing newline) describing the
# current SWT version and, optionally, the user's 5-hour Claude usage.
#
# Behavior:
#   - Always shows [SWT v<version>].
#   - If swt_settings.json -> statusline.enabled is true AND the JSON
#     payload on stdin contains rate_limits.five_hour with both
#     used_percentage and resets_at, also shows "5h <pct>% · resets <HH:MM AM/PM>".
#   - On ANY error the script must NOT fail and must NOT print error text;
#     it falls back to [SWT v<version>] (or [SWT vunknown] if VERSION is unreadable).
#
# Portability: derives paths from the script's own location and `$USER`, with
# `$SWT_DIR` and `$SWT_SETTINGS_PATH` env vars taking priority when set (these
# are exported by deploy.sh). Works for any user on WSL or native Linux.
#
# Dependencies: bash, python3 (used for safe JSON parsing — jq is NOT assumed).
# Installation: chmod +x this file and reference it from ~/.claude/settings.json:
#   { "statusLine": { "type": "command",
#                     "command": "/path/to/Project-SWT/scripts/swt-statusline.sh" } }
#
# Note: deliberately does NOT use `set -e` — every command handles its own
# failure via fallbacks so the script can never abort partway through.

# Derive SWT_DIR from the script's own location (parent of scripts/).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _SCRIPT_DIR=""
_SWT_DIR_DEFAULT="$(cd "${_SCRIPT_DIR}/.." 2>/dev/null && pwd)" || _SWT_DIR_DEFAULT=""
VERSION_FILE="${SWT_DIR:-$_SWT_DIR_DEFAULT}/VERSION"

# Settings file: prefer SWT_SETTINGS_PATH env var (set by deploy.sh), else
# fall back to /mnt/c/Users/$USER/swt_settings.json (WSL convention).
SETTINGS_FILE="${SWT_SETTINGS_PATH:-/mnt/c/Users/${USER:-$(id -un 2>/dev/null)}/swt_settings.json}"

# --- 1. Read VERSION (strip trailing newline/whitespace) ---
version="$( { tr -d '[:space:]' < "$VERSION_FILE"; } 2>/dev/null)"
[ -z "$version" ] && version="unknown"

# --- 2. Capture stdin once (Claude Code's JSON payload) ---
payload="$(cat 2>/dev/null)" || payload=""

# --- 3. Ask python3 to do all the JSON work in one shot.
# Inputs via env: SETTINGS_FILE, PAYLOAD.
# Outputs on stdout: "<enabled>|<pct_or_empty>|<epoch_or_empty>"
parsed="$(SETTINGS_FILE="$SETTINGS_FILE" PAYLOAD="$payload" python3 - <<'PY' 2>/dev/null
import json, os, sys

enabled = "0"
pct = ""
epoch = ""

# settings -> statusline.enabled
try:
    with open(os.environ["SETTINGS_FILE"], "r", encoding="utf-8") as f:
        s = json.load(f)
    if isinstance(s, dict):
        sl = s.get("statusline")
        if isinstance(sl, dict) and sl.get("enabled") is True:
            enabled = "1"
except Exception:
    pass

# stdin payload -> rate_limits.five_hour.{used_percentage, resets_at}
raw = os.environ.get("PAYLOAD", "")
if raw.strip():
    try:
        p = json.loads(raw)
        rl = p.get("rate_limits") if isinstance(p, dict) else None
        fh = rl.get("five_hour") if isinstance(rl, dict) else None
        if isinstance(fh, dict):
            up = fh.get("used_percentage")
            ra = fh.get("resets_at")
            if isinstance(up, (int, float)):
                pct = str(int(round(up)))
            if isinstance(ra, (int, float)) and ra > 0:
                epoch = str(int(ra))
    except Exception:
        pass

sys.stdout.write(f"{enabled}|{pct}|{epoch}")
PY
)"

# Defensive split (if python3 itself failed, parsed will be empty -> all defaults).
enabled="${parsed%%|*}"
rest="${parsed#*|}"
pct="${rest%%|*}"
epoch="${rest#*|}"
[ "$enabled" != "1" ] && enabled="0"

# --- 4. Format the output line ---
if [ "$enabled" = "1" ] && [ -n "$pct" ] && [ -n "$epoch" ]; then
    reset_str="$(date -d "@${epoch}" '+%-I:%M %p' 2>/dev/null)"
    if [ -n "$reset_str" ]; then
        printf '[SWT v%s │ 5h %s%% · resets %s]' "$version" "$pct" "$reset_str"
    else
        printf '[SWT v%s]' "$version"
    fi
else
    printf '[SWT v%s]' "$version"
fi
