#!/usr/bin/env bash
# swt-statusline.sh — Claude Code statusLine hook for Project-SWT.
#
# Emits exactly one line on stdout (no trailing newline) describing the
# current SWT version and, optionally, the user's session token usage.
#
# Behavior:
#   - Always shows [SWT v<version>].
#   - If swt_settings.json -> statusline.enabled is true AND the JSON
#     payload on stdin contains both context_window.total_input_tokens +
#     total_output_tokens AND context_window.used_percentage, also shows
#     "<tokens> · <pct>%" — e.g. "142k · 62%".
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
# Outputs on stdout: "<enabled>|<tokens_str_or_empty>|<pct_or_empty>"
parsed="$(SETTINGS_FILE="$SETTINGS_FILE" PAYLOAD="$payload" python3 - <<'PY' 2>/dev/null
import json, os, sys

enabled = "0"
tokens_str = ""
pct = ""

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

def fmt_tokens(n):
    # Human-friendly: <1k -> "<N>", 1k-999k -> "<N>k", >=1M -> "<N.N>M"
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        return f"{n // 1000}k"
    return f"{n / 1_000_000:.1f}M"

# stdin payload -> context_window.{total_input_tokens, total_output_tokens, used_percentage}
raw = os.environ.get("PAYLOAD", "")
if raw.strip():
    try:
        p = json.loads(raw)
        cw = p.get("context_window") if isinstance(p, dict) else None
        if isinstance(cw, dict):
            ti = cw.get("total_input_tokens")
            to = cw.get("total_output_tokens")
            up = cw.get("used_percentage")
            if isinstance(ti, (int, float)) and isinstance(to, (int, float)):
                total = int(ti) + int(to)
                if total >= 0:
                    tokens_str = fmt_tokens(total)
            if isinstance(up, (int, float)):
                p_int = int(round(up))
                if p_int < 0:
                    p_int = 0
                pct = str(p_int)
    except Exception:
        pass

sys.stdout.write(f"{enabled}|{tokens_str}|{pct}")
PY
)"

# Defensive split (if python3 itself failed, parsed will be empty -> all defaults).
enabled="${parsed%%|*}"
rest="${parsed#*|}"
tokens_str="${rest%%|*}"
pct="${rest#*|}"
[ "$enabled" != "1" ] && enabled="0"

# --- 4. Format the output line ---
if [ "$enabled" = "1" ] && [ -n "$tokens_str" ] && [ -n "$pct" ]; then
    if [ "$pct" -ge 85 ] 2>/dev/null; then
        printf '[SWT v%s │ %s · \033[31m%s%%\033[0m]' "$version" "$tokens_str" "$pct"
    else
        printf '[SWT v%s │ %s · %s%%]' "$version" "$tokens_str" "$pct"
    fi
else
    printf '[SWT v%s]' "$version"
fi
