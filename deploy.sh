#!/bin/bash
# Deploys the SWT agent team — TPM as orchestrator with on-demand SWE/QA subagents.
# Pulls latest Project-SWT from git, then starts claude in the user's cwd.
#
# Usage:
#   swt                      → unconstrained mode (general team, no ticket context)
#   swt --branch             → constrained mode (auto-detect ticket from git branch)
#   swt --support            → support mode (scoped to swt_settings.json apps)
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

# ── Python Dependency Check ────────────────────────────────────────
# python3 is required for JSON parsing of swt_settings.json. Fail loudly with
# a clear remediation message if missing — every downstream env var depends on it.
if ! command -v python3 &>/dev/null; then
    echo "[swt] Error: python3 is required but not found on PATH." >&2
    echo "[swt] swt_settings.json is read/written via python3 — install it first:" >&2
    if [ "$IS_WSL" = true ]; then
        echo "[swt]   sudo apt-get install -y python3" >&2
    else
        echo "[swt]   See https://www.python.org/downloads/ (or use your package manager)" >&2
    fi
    exit 1
fi

# ── YAML Helpers (legacy — only used during first-boot migration) ──
# Read an unquoted scalar value for an anchored top-level key from swt.yml.
# Returns empty (and exit 0) when the key is missing — caller applies its own default.
SWT_YML="$SWT_DIR/.claude/config/swt.yml"

_yml_scalar() {
    local key="$1"
    { grep "^${key}:" "$SWT_YML" 2>/dev/null || true; } | head -n1 | sed 's/.*: *//' | sed 's/ *#.*//' | tr -d '"' | tr -d '\r'
}

# Parse YAML flow-style list: "[A, B, C]" → newline-separated tokens.
_yml_flow_list() {
    local key="$1"
    { grep "^${key}:" "$SWT_YML" 2>/dev/null || true; } \
        | head -n1 \
        | sed 's/^[^:]*: *//' \
        | sed 's/^\[//; s/\]$//' \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | sed 's/^"//; s/"$//' \
        | grep -v '^$' \
        || true
}

# ── JSON Helpers ───────────────────────────────────────────────────
# All read/write helpers wrap python3. Each is defensive — malformed or missing
# files return empty strings / non-zero gracefully so `set -euo pipefail` survives.
# Key paths are dotted (e.g. "team.swe_count", "atlassian.cloud_id"). These
# helpers do not interpret array indexes — array access goes through _json_get_array.

# Get a scalar value at a dotted key path. Prints empty string on missing/null.
_json_get() {
    local file="$1" path="$2"
    [ -f "$file" ] || { echo ""; return 0; }
    python3 - "$file" "$path" <<'PY' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    cur = data
    for part in sys.argv[2].split('.'):
        if part == '':
            continue
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            cur = None
            break
    if cur is None:
        print('')
    elif isinstance(cur, bool):
        print('true' if cur else 'false')
    elif isinstance(cur, (dict, list)):
        # Caller wanted a scalar — return empty for containers.
        print('')
    else:
        print(cur)
except Exception:
    print('')
PY
}

# Get an array of strings at a dotted key path, one per line. Empty for missing/non-array.
_json_get_array() {
    local file="$1" path="$2"
    [ -f "$file" ] || return 0
    python3 - "$file" "$path" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    cur = data
    for part in sys.argv[2].split('.'):
        if part == '':
            continue
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            cur = None
            break
    if isinstance(cur, list):
        for item in cur:
            if item is None:
                continue
            print(item)
except Exception:
    pass
PY
}

# Get the keys of an object at a dotted key path, one per line. Empty for missing/non-object.
_json_get_keys() {
    local file="$1" path="$2"
    [ -f "$file" ] || return 0
    python3 - "$file" "$path" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    cur = data
    for part in sys.argv[2].split('.'):
        if part == '':
            continue
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            cur = None
            break
    if isinstance(cur, dict):
        for k in cur.keys():
            print(k)
except Exception:
    pass
PY
}

# Set a scalar value at a dotted key path (creates intermediate objects).
# Value is interpreted as a string by default; "true"/"false" become bools, ints/floats stay numeric.
_json_set() {
    local file="$1" path="$2" value="$3"
    [ -f "$file" ] || return 0
    python3 - "$file" "$path" "$value" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    raw = sys.argv[3]
    # Coerce: bool first, then int, then float, else string.
    if raw == 'true':
        coerced = True
    elif raw == 'false':
        coerced = False
    else:
        try:
            coerced = int(raw)
        except ValueError:
            try:
                coerced = float(raw)
            except ValueError:
                coerced = raw
    parts = [p for p in sys.argv[2].split('.') if p]
    cur = data
    for part in parts[:-1]:
        if not isinstance(cur, dict):
            raise SystemExit(0)
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    if isinstance(cur, dict) and parts:
        cur[parts[-1]] = coerced
        with open(sys.argv[1], 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
except Exception:
    pass
PY
}

# Append a JSON-fragment to an array at a dotted key path. Creates the array if missing.
_json_array_append() {
    local file="$1" path="$2" fragment="$3"
    [ -f "$file" ] || return 0
    python3 - "$file" "$path" "$fragment" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    item = json.loads(sys.argv[3])
    parts = [p for p in sys.argv[2].split('.') if p]
    cur = data
    for part in parts[:-1]:
        if not isinstance(cur, dict):
            raise SystemExit(0)
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    if isinstance(cur, dict) and parts:
        last = parts[-1]
        if last not in cur or not isinstance(cur[last], list):
            cur[last] = []
        cur[last].append(item)
        with open(sys.argv[1], 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
except Exception:
    pass
PY
}

# Set a key inside the object at a dotted key path. Value coerced like _json_set.
# Pass the literal "null" string to write a JSON null.
_json_object_set() {
    local file="$1" path="$2" key="$3" value="$4"
    [ -f "$file" ] || return 0
    python3 - "$file" "$path" "$key" "$value" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    raw = sys.argv[4]
    if raw == 'null':
        coerced = None
    elif raw == 'true':
        coerced = True
    elif raw == 'false':
        coerced = False
    else:
        try:
            coerced = int(raw)
        except ValueError:
            try:
                coerced = float(raw)
            except ValueError:
                coerced = raw
    parts = [p for p in sys.argv[2].split('.') if p]
    cur = data
    for part in parts:
        if not isinstance(cur, dict):
            raise SystemExit(0)
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    if isinstance(cur, dict):
        cur[sys.argv[3]] = coerced
        with open(sys.argv[1], 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
except Exception:
    pass
PY
}

# ── Resolve Windows User Home ────────────────────────────────────
# Compute the Windows-side username and home path once — settings.json,
# feedback, support, and any future user-state features auto-resolve here.
# Works on both WSL (whoami.exe) and Git Bash (USERPROFILE).
WIN_USER=""
WIN_HOME_DIR=""
if [ "$IS_WSL" = true ]; then
    WIN_USER="$(whoami.exe 2>/dev/null | sed 's|.*\\||' | tr -d '\r\n')"
    if [ -n "$WIN_USER" ] && [ -n "$WSL_C_MOUNT" ]; then
        WIN_HOME_DIR="${WSL_C_MOUNT}/Users/${WIN_USER}"
    fi
else
    if [ -n "${USERPROFILE:-}" ]; then
        WIN_HOME_DIR=$(to_native_path "${USERPROFILE//\\//}")
        WIN_USER="$(basename "$WIN_HOME_DIR" 2>/dev/null || echo "")"
    fi
fi

# ── Unified Settings File ─────────────────────────────────────────
# swt_settings.json lives in the user's Windows home directory. It replaces
# user-tunable values from swt.yml plus the persistent swt_feedback.md /
# swt_support.md files. On first boot (file missing), seed from swt.yml and
# migrate any existing MD content. After creation, swt.yml is never read again.
SWT_SETTINGS_PATH=""
if [ -n "$WIN_HOME_DIR" ]; then
    SWT_SETTINGS_PATH="${WIN_HOME_DIR}/swt_settings.json"
fi
export SWT_SETTINGS_PATH

# Build the initial JSON document (seeded from swt.yml + optional MD migration)
# and write it to $SWT_SETTINGS_PATH. Idempotent — does nothing if file exists.
_ensure_settings_file() {
    [ -n "$SWT_SETTINGS_PATH" ] || return 0
    [ -f "$SWT_SETTINGS_PATH" ] && return 0

    # Seed values from swt.yml (these are the only times we ever read swt.yml
    # after this boot — every subsequent read goes through swt_settings.json).
    local seed_swe_count seed_swe_eff seed_swe_perf seed_qa_count
    seed_swe_count="$(_yml_scalar swe_agent_count)"
    seed_swe_eff="$(_yml_scalar swe_efficiency_cores)"
    seed_swe_perf="$(_yml_scalar swe_performance_cores)"
    seed_qa_count="$(_yml_scalar qa_agent_count)"

    local seed_cloud_id seed_site seed_board_id seed_board_url
    seed_cloud_id="$({ grep '^atlassian_cloud_id:' "$SWT_YML" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//')"
    seed_site="$({ grep '^atlassian_site:' "$SWT_YML" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//')"
    seed_board_id="$(_yml_scalar board_id)"
    seed_board_url="$({ grep '^board_url:' "$SWT_YML" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//')"

    # Path values: strip surrounding quotes AND normalize YAML-escaped \\ to /
    # so the JSON stores clean forward-slash Windows paths (matches the prior
    # sed pipeline used elsewhere in the script).
    local seed_obsidian seed_edge seed_lprun
    seed_obsidian="$({ grep '^obsidian_base_path:' "$SWT_YML" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')"
    seed_edge="$({ grep '^edge_profile_path:' "$SWT_YML" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')"
    seed_lprun="$({ grep '^lprun_path:' "$SWT_YML" 2>/dev/null || true; } | sed 's/.*: *"//' | sed 's/".*//' | sed 's/\\\\/\//g')"

    local seed_pw_headless seed_db_enabled seed_feedback_enabled seed_support_enabled
    seed_pw_headless="$(_yml_scalar playwright_headless)"
    seed_db_enabled="$(_yml_scalar database_enabled)"
    seed_feedback_enabled="$(_yml_scalar feedback_enabled)"
    seed_support_enabled="$(_yml_scalar support_enabled)"

    # Build the database allowlist as a python dict literal from the YAML
    # repeated-block style ("- project: X / connection: Y"). Use awk to
    # collect pairs, then format for python.
    local db_pairs
    db_pairs="$(awk '
        /^[[:space:]]*-[[:space:]]*project:[[:space:]]*/ {
            sub(/.*project:[[:space:]]*/, "", $0); sub(/[[:space:]]*$/, "", $0); proj=$0; next
        }
        /^[[:space:]]*connection:[[:space:]]*/ {
            sub(/.*connection:[[:space:]]*"?/, "", $0); sub(/"?[[:space:]]*$/, "", $0)
            if (proj != "") { print proj "\t" $0; proj="" }
        }
    ' "$SWT_YML" 2>/dev/null || true)"

    # Support apps + roots
    local support_apps support_roots
    support_apps="$(_yml_flow_list support_apps)"
    support_roots="$(_yml_flow_list support_search_roots)"

    # Migration: parse existing swt_feedback.md (bullet lines beginning "- ").
    # Preserve any **YYYY-MM-DD** prefix as the date; default to today otherwise.
    local feedback_md="${WIN_HOME_DIR}/swt_feedback.md"
    local feedback_entries=""
    if [ -f "$feedback_md" ]; then
        feedback_entries="$(cat "$feedback_md" 2>/dev/null || true)"
    fi

    # Migration: parse existing swt_support.md ("- APP: <path>" or "- APP: # TODO").
    local support_md="${WIN_HOME_DIR}/swt_support.md"
    local support_md_content=""
    if [ -f "$support_md" ]; then
        support_md_content="$(cat "$support_md" 2>/dev/null || true)"
    fi

    # Track whether we actually migrated MD content (for the boot message and
    # the SWT_SETTINGS_MIGRATED signal env var consumed by TPM at startup).
    local migrated_md="false"
    _SWT_SETTINGS_MIGRATED="false"   # global — survives function return
    if [ -f "$feedback_md" ] || [ -f "$support_md" ]; then
        migrated_md="true"
        _SWT_SETTINGS_MIGRATED="true"
    fi

    # Hand off to python to build the JSON document. Pass everything via env
    # to avoid arg-list quoting headaches.
    SEED_SWE_COUNT="${seed_swe_count:-3}" \
    SEED_SWE_EFF="${seed_swe_eff:-1}" \
    SEED_SWE_PERF="${seed_swe_perf:-2}" \
    SEED_QA_COUNT="${seed_qa_count:-1}" \
    SEED_CLOUD_ID="$seed_cloud_id" \
    SEED_SITE="$seed_site" \
    SEED_BOARD_ID="${seed_board_id:-}" \
    SEED_BOARD_URL="$seed_board_url" \
    SEED_OBSIDIAN="$seed_obsidian" \
    SEED_EDGE="$seed_edge" \
    SEED_LPRUN="$seed_lprun" \
    SEED_PW_HEADLESS="${seed_pw_headless:-false}" \
    SEED_DB_ENABLED="${seed_db_enabled:-true}" \
    SEED_FEEDBACK_ENABLED="${seed_feedback_enabled:-true}" \
    SEED_SUPPORT_ENABLED="${seed_support_enabled:-true}" \
    DB_PAIRS="$db_pairs" \
    SUPPORT_APPS="$support_apps" \
    SUPPORT_ROOTS="$support_roots" \
    FEEDBACK_MD="$feedback_entries" \
    SUPPORT_MD="$support_md_content" \
    OUT_FILE="$SWT_SETTINGS_PATH" \
    python3 - <<'PY' 2>/dev/null || return 0
import json, os, re, datetime

def _bool(v, default):
    if v is None or v == '':
        return default
    return v.lower() == 'true'

def _int(v, default):
    try:
        return int(v) if v not in (None, '') else default
    except ValueError:
        return default

today = datetime.date.today().isoformat()

# Database allowlist (TAB-separated proj/connection pairs).
allowlist = {}
for line in os.environ.get('DB_PAIRS', '').splitlines():
    if not line.strip():
        continue
    if '\t' in line:
        proj, conn = line.split('\t', 1)
        allowlist[proj.strip()] = conn.strip()

# Support apps list.
apps = [a.strip() for a in os.environ.get('SUPPORT_APPS', '').splitlines() if a.strip()]
# Support search roots — normalize YAML-escaped \\ to / for consistent path form.
roots = [r.strip().replace('\\\\', '/').replace('\\', '/')
         for r in os.environ.get('SUPPORT_ROOTS', '').splitlines() if r.strip()]

# Feedback migration: each non-empty line starting with "- " is one entry.
# Preserve **YYYY-MM-DD** prefix as the date if present; else today.
feedback_entries = []
date_re = re.compile(r'^\*\*(\d{4}-\d{2}-\d{2})\*\*\s*[:\-]?\s*(.*)$')
for raw in os.environ.get('FEEDBACK_MD', '').splitlines():
    s = raw.strip()
    if not s.startswith('- '):
        continue
    text = s[2:].strip()
    m = date_re.match(text)
    if m:
        feedback_entries.append({'date': m.group(1), 'text': m.group(2).strip()})
    else:
        feedback_entries.append({'date': today, 'text': text})

# Support repos: parse "- APP: <value>" lines. Skip "# TODO" markers (→ null).
repos = {a: None for a in apps}
support_line_re = re.compile(r'^- ([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$')
for raw in os.environ.get('SUPPORT_MD', '').splitlines():
    m = support_line_re.match(raw.strip())
    if not m:
        continue
    app, val = m.group(1), m.group(2).strip()
    if not val or val.startswith('#'):
        repos[app] = None
    else:
        repos[app] = val

doc = {
    "_schema": 2,
    "team": {
        "swe_count": _int(os.environ.get('SEED_SWE_COUNT'), 3),
        "swe_efficiency_cores": _int(os.environ.get('SEED_SWE_EFF'), 1),
        "swe_performance_cores": _int(os.environ.get('SEED_SWE_PERF'), 2),
        "qa_count": _int(os.environ.get('SEED_QA_COUNT'), 1),
    },
    "atlassian": {
        "cloud_id": os.environ.get('SEED_CLOUD_ID', ''),
        "site": os.environ.get('SEED_SITE', ''),
        "board_id": _int(os.environ.get('SEED_BOARD_ID'), 0),
        "board_url": os.environ.get('SEED_BOARD_URL', ''),
    },
    "paths": {
        "obsidian_base": os.environ.get('SEED_OBSIDIAN', ''),
        "edge_profile": os.environ.get('SEED_EDGE', ''),
        "lprun": os.environ.get('SEED_LPRUN', ''),
    },
    "playwright": {
        "headless": _bool(os.environ.get('SEED_PW_HEADLESS'), False),
    },
    "database": {
        "enabled": _bool(os.environ.get('SEED_DB_ENABLED'), True),
        "allowlist": allowlist,
    },
    "feedback": {
        "enabled": _bool(os.environ.get('SEED_FEEDBACK_ENABLED'), True),
        "entries": feedback_entries,
    },
    "support": {
        "enabled": _bool(os.environ.get('SEED_SUPPORT_ENABLED'), True),
        "apps": repos,
    },
    "statusline": {
        "enabled": False,
    },
}

out = os.environ['OUT_FILE']
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, 'w', encoding='utf-8') as f:
    json.dump(doc, f, indent=2)
    f.write('\n')
PY

    if [ -f "$SWT_SETTINGS_PATH" ]; then
        if [ "$migrated_md" = "true" ]; then
            echo "[swt] ✓ Settings: created swt_settings.json (migrated from swt.yml + MD files)"
        else
            echo "[swt] ✓ Settings: created swt_settings.json (seeded from swt.yml)"
        fi
    fi
}

_ensure_settings_file || true

# ── Schema Migration (v1 → v2) ────────────────────────────────────
# v2 collapses support.{apps[], search_roots[], repos{}} into a single
# support.apps{} map (APP → path|null) and bumps _schema to 2. Runs in-place
# on an existing settings file; no-op if already on v2 (or higher), if the
# file is missing, or if the JSON is malformed. Never fails the boot.
_migrate_settings_schema() {
    [ -n "$SWT_SETTINGS_PATH" ] && [ -f "$SWT_SETTINGS_PATH" ] || return 0

    SWT_SETTINGS_PATH="$SWT_SETTINGS_PATH" python3 - <<'PY' 2>/dev/null
import json, os, shutil, sys, tempfile

path = os.environ.get('SWT_SETTINGS_PATH', '')
if not path:
    sys.exit(0)

try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    print('[swt] ⚠ swt_settings.json: schema unreadable, skipping migration')
    sys.exit(0)

if not isinstance(data, dict):
    print('[swt] ⚠ swt_settings.json: schema unreadable, skipping migration')
    sys.exit(0)

schema = data.get('_schema')
support = data.get('support')

# Detect v1-shaped support: array apps, or presence of search_roots/repos.
v1_shape = (
    isinstance(support, dict) and (
        isinstance(support.get('apps'), list)
        or 'search_roots' in support
        or 'repos' in support
    )
)

if schema == 1 and v1_shape:
    # Backup the v1 file before mutating (only if no backup exists yet).
    backup_path = path + '.v1.bak'
    if not os.path.exists(backup_path):
        try:
            shutil.copy2(path, backup_path)
        except Exception as e:
            print(f"[swt] ⚠ swt_settings.json: backup failed ({e}), continuing migration")

    old_apps = support.get('apps') or []
    old_repos = support.get('repos') or {}
    new_apps_map = {}
    if isinstance(old_apps, list):
        for app in old_apps:
            if not app:
                continue
            new_apps_map[app] = old_repos.get(app, None) if isinstance(old_repos, dict) else None
    elif isinstance(old_apps, dict):
        # Defensive: if apps is somehow already an object, preserve it as-is.
        new_apps_map = old_apps

    data['support'] = {
        'enabled': support.get('enabled', True),
        'apps': new_apps_map,
    }
    data['_schema'] = 2

    # Atomic write via temp file in the same directory + rename.
    out_dir = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.swt_settings.', suffix='.tmp', dir=out_dir)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        print('[swt] ⚠ swt_settings.json: write failed during migration, skipping')
        sys.exit(0)

    print(f"[swt] migrated swt_settings.json schema 1 → 2 (backup: {backup_path})")
    print('__SWT_SCHEMA_MIGRATED__')
elif schema in (None, ) or not isinstance(schema, int):
    print('[swt] ⚠ swt_settings.json: schema unreadable, skipping migration')
# else: schema >= 2 → silent no-op
PY
}

# Capture migration output so we can detect the schema-migrated marker and
# fold it into SWT_SETTINGS_MIGRATED. The marker line is consumed; everything
# else (banner + warnings) is forwarded to the user verbatim.
_migration_output="$(_migrate_settings_schema 2>&1 || true)"
if [ -n "$_migration_output" ]; then
    while IFS= read -r _mline; do
        if [ "$_mline" = "__SWT_SCHEMA_MIGRATED__" ]; then
            _SWT_SETTINGS_MIGRATED="true"
        else
            echo "$_mline"
        fi
    done <<< "$_migration_output"
fi
unset _migration_output

# ── Agent Team Configuration ───────────────────────────────────────
# Read team-size knobs from swt_settings.json (with sensible defaults). Falls
# back to swt.yml values only at first-boot via _ensure_settings_file above.
_SWE_AGENT_COUNT_RAW="$(_json_get "$SWT_SETTINGS_PATH" team.swe_count)"
_SWE_EFFICIENCY_CORES_RAW="$(_json_get "$SWT_SETTINGS_PATH" team.swe_efficiency_cores)"
_SWE_PERFORMANCE_CORES_RAW="$(_json_get "$SWT_SETTINGS_PATH" team.swe_performance_cores)"
_QA_AGENT_COUNT_RAW="$(_json_get "$SWT_SETTINGS_PATH" team.qa_count)"

export TPM_COUNT=1                                                     # There can only be one TPM
export SWE_AGENT_COUNT="${_SWE_AGENT_COUNT_RAW:-3}"                    # Total max concurrent SWE subagents
export SWE_EFFICIENCY_CORES="${_SWE_EFFICIENCY_CORES_RAW:-1}"          # Routine tasks
export SWE_PERFORMANCE_CORES="${_SWE_PERFORMANCE_CORES_RAW:-2}"        # Complex tasks
export QA_AGENT_COUNT="${_QA_AGENT_COUNT_RAW:-1}"                      # Max concurrent QA subagents
export SWT_SETTINGS_MIGRATED="${_SWT_SETTINGS_MIGRATED:-false}"        # true only when MD files were migrated this boot
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
MODE_SUPPORT=false
MODE_BRANCH=false

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: swt [options]"
            echo ""
            echo "  swt                    Unconstrained mode (general team, no ticket context)"
            echo "  swt --branch           Constrained mode (auto-detect ticket from git branch)"
            echo "  swt --support          Support mode (scoped to apps in swt_settings.json)"
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
            MODE_BRANCH=true
            ;;
        --support)
            MODE_SUPPORT=true
            ;;
        *)
            echo "[swt] unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# Validate flag combinations after parsing — --support and --branch are
# mutually exclusive because they imply different session modes (support
# scope vs. ticket scope). --remote is independent and combines with either.
if [ "$MODE_SUPPORT" = true ] && [ "$MODE_BRANCH" = true ]; then
    echo "[swt] --support and --branch are mutually exclusive" >&2
    exit 2
fi

if [ "$MODE_BRANCH" = true ]; then
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
fi

# ── Validate Obsidian Path ────────────────────────────────────────
OBSIDIAN_PATH_RAW="$(_json_get "$SWT_SETTINGS_PATH" paths.obsidian_base)"
OBSIDIAN_PATH=$(to_native_path "$OBSIDIAN_PATH_RAW")
export SWT_OBSIDIAN_PATH="$OBSIDIAN_PATH"
if [ -n "$OBSIDIAN_PATH" ] && [ ! -d "$OBSIDIAN_PATH" ]; then
    echo "[swt] Warning: Obsidian base path does not exist: $OBSIDIAN_PATH"
    echo "[swt] Agents will create it on first use, or update swt_settings.json"
fi

# ── Resolve Database Config ──────────────────────────────────────
DB_ENABLED_RAW="$(_json_get "$SWT_SETTINGS_PATH" database.enabled)"
if [ "$DB_ENABLED_RAW" = "true" ]; then
    export SWT_DB_ENABLED="true"
else
    export SWT_DB_ENABLED="false"
fi

LPRUN_RAW="$(_json_get "$SWT_SETTINGS_PATH" paths.lprun)"
export SWT_LPRUN_PATH=$(to_native_path "$LPRUN_RAW")

EDGE_PROFILE_RAW="$(_json_get "$SWT_SETTINGS_PATH" paths.edge_profile)"
export SWT_EDGE_PROFILE_PATH=$(to_native_path "$EDGE_PROFILE_RAW")

SWT_PLAYWRIGHT_HEADLESS="$(_json_get "$SWT_SETTINGS_PATH" playwright.headless)"
export SWT_PLAYWRIGHT_HEADLESS="${SWT_PLAYWRIGHT_HEADLESS:-false}"

# Look up the project's allowlisted DB connection (if any). The allowlist is an
# object keyed by Jira project (CMMS, MCP, …) → connection-name string.
SWT_DB_CONNECTION=""
if [ "$SWT_DB_ENABLED" = "true" ] && [ -n "$SWT_PROJECT" ]; then
    SWT_DB_CONNECTION="$(_json_get "$SWT_SETTINGS_PATH" "database.allowlist.${SWT_PROJECT}")"
fi
export SWT_DB_CONNECTION

# ── Resolve Feedback Config ──────────────────────────────────────
# Feedback now lives in the unified swt_settings.json under feedback.entries.
# SWT_FEEDBACK_PATH is preserved for backward compat with TPM, pointing at the
# same JSON file (TPM reads feedback.entries instead of bullet lines).
FEEDBACK_ENABLED_RAW="$(_json_get "$SWT_SETTINGS_PATH" feedback.enabled)"
if [ "${FEEDBACK_ENABLED_RAW:-true}" = "false" ]; then
    export SWT_FEEDBACK_ENABLED="false"
    export SWT_FEEDBACK_PATH=""
elif [ -n "$SWT_SETTINGS_PATH" ] && [ -f "$SWT_SETTINGS_PATH" ]; then
    export SWT_FEEDBACK_ENABLED="true"
    export SWT_FEEDBACK_PATH="$SWT_SETTINGS_PATH"
else
    echo "[swt] ⚠ Feedback: settings file unavailable, disabling"
    export SWT_FEEDBACK_ENABLED="false"
    export SWT_FEEDBACK_PATH=""
fi

# ── Resolve Support Config ───────────────────────────────────────
# Support data lives in swt_settings.json under support.{enabled, apps{}}.
# support.apps is an APP → path|null map. SWT_SUPPORT_PATH is preserved for
# backward compat — it points at the unified settings file.
# Discovery runs only when --support is passed (SWT_SUPPORT_MODE=true): for any
# app whose path is null, scan curated dev roots (and a depth-limited C-drive
# fallback) and write the result back into support.apps.
SUPPORT_ENABLED_RAW="$(_json_get "$SWT_SETTINGS_PATH" support.enabled)"
if [ "${SUPPORT_ENABLED_RAW:-true}" = "false" ]; then
    export SWT_SUPPORT_ENABLED="false"
    export SWT_SUPPORT_PATH=""
elif [ -n "$SWT_SETTINGS_PATH" ] && [ -f "$SWT_SETTINGS_PATH" ]; then
    export SWT_SUPPORT_ENABLED="true"
    export SWT_SUPPORT_PATH="$SWT_SETTINGS_PATH"
else
    echo "[swt] ⚠ Support: settings file unavailable, disabling"
    export SWT_SUPPORT_ENABLED="false"
    export SWT_SUPPORT_PATH=""
fi

# Export support mode flag — true only when --support was passed this boot.
if [ "$MODE_SUPPORT" = true ]; then
    export SWT_SUPPORT_MODE="true"
else
    export SWT_SUPPORT_MODE="false"
fi

# Incremental discovery: for any app whose repo path is null in support.apps,
# search a curated set of common dev roots, then fall back to a depth-limited
# C-drive scan. Runs only when support mode is active (--support). Never fails
# the boot — every error path produces a single warning line and continues.
_discover_support_apps() {
    [ "$SWT_SUPPORT_MODE" = "true" ] || return 0
    [ "$SWT_SUPPORT_ENABLED" = "true" ] || return 0
    [ -n "$SWT_SETTINGS_PATH" ] && [ -f "$SWT_SETTINGS_PATH" ] || return 0

    # Curated roots — only those that exist on disk. WIN_USER feeds the Windows
    # home path under WSL; if it's empty, that root simply won't resolve.
    # /mnt/c/Users/$USER comes first because users frequently keep repos directly
    # under their home (subsumes the older source/repos and Documents entries at
    # maxdepth 4). /mnt/c/dev, /mnt/c/Projects, /mnt/c/Source are alternate
    # common dev roots outside the user home.
    local curated_candidates=(
        "/mnt/c/Users/${WIN_USER}"
        "/mnt/c/dev"
        "/mnt/c/Projects"
        "/mnt/c/Source"
    )
    local curated_roots=()
    local root
    for root in "${curated_candidates[@]}"; do
        [ -n "$root" ] || continue
        if [ -d "$root" ]; then
            curated_roots+=("$root")
        fi
    done

    # Iterate apps: only attempt discovery for apps whose value is null.
    local app current
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        current="$(_json_get "$SWT_SETTINGS_PATH" "support.apps.${app}")"
        if [ -n "$current" ]; then
            continue
        fi

        # Stage 1 — curated roots. Collect matches that have a .git/ subdir.
        # Prune AppData / node_modules / .git / $Recycle.Bin uniformly across all
        # curated roots — the prune cost is negligible when the directories
        # don't exist, and it keeps the scan bounded when the root is the user
        # home (which contains plenty of noisy subtrees).
        local matches=()
        local match
        for root in "${curated_roots[@]}"; do
            while IFS= read -r match; do
                [ -n "$match" ] || continue
                if [ -d "${match}/.git" ]; then
                    matches+=("$match")
                fi
            done < <({ find "$root" -maxdepth 4 -type d \
                \( -iname AppData -o -iname 'AppData.*' -o -iname node_modules \
                   -o -iname .git -o -iname '$Recycle.Bin' \) -prune -o \
                -type d -iname "$app" -print 2>/dev/null || true; })
        done

        # Stage 2 — depth-limited C-drive fallback if curated yielded nothing.
        # Capture rc via "|| rc=$?" so set -e doesn't trip when the find/timeout
        # exits non-zero (124 on timeout is the expected case to handle).
        local stage2_status="ok"
        if [ "${#matches[@]}" -eq 0 ] && [ -d "/mnt/c" ]; then
            local fallback_output="" rc=0
            fallback_output="$(timeout 15 find /mnt/c -maxdepth 6 -type d \
                \( -iname Windows -o -iname 'Program Files*' -o -iname AppData \
                   -o -iname '$Recycle.Bin' -o -iname 'System Volume Information' \
                   -o -iname node_modules -o -iname '.git' \) -prune \
                -o -type d -iname "$app" -print 2>/dev/null)" || rc=$?
            if [ "$rc" -eq 124 ]; then
                stage2_status="timeout"
            elif [ "$rc" -ne 0 ]; then
                stage2_status="error"
            fi
            if [ "$stage2_status" = "ok" ] && [ -n "$fallback_output" ]; then
                while IFS= read -r match; do
                    [ -n "$match" ] || continue
                    if [ -d "${match}/.git" ]; then
                        matches+=("$match")
                    fi
                done <<< "$fallback_output"
            fi
        fi

        # Pick the best candidate by most-recent commit time. Treat git failures
        # as commit_time=0 so a non-git or broken candidate doesn't crash the loop.
        local found=""
        if [ "${#matches[@]}" -gt 0 ]; then
            if [ "${#matches[@]}" -eq 1 ]; then
                found="${matches[0]}"
            else
                local best="" best_ts=-1 candidate ts
                for candidate in "${matches[@]}"; do
                    ts="$(git -C "$candidate" log -1 --format=%ct 2>/dev/null || echo 0)"
                    [ -n "$ts" ] || ts=0
                    if [ "$ts" -gt "$best_ts" ] 2>/dev/null; then
                        best_ts="$ts"
                        best="$candidate"
                    fi
                done
                found="$best"
            fi
        fi

        if [ -n "$found" ]; then
            _json_object_set "$SWT_SETTINGS_PATH" "support.apps" "$app" "$found" || true
            echo "[swt] discovered ${app} at ${found}"
        else
            case "$stage2_status" in
                timeout) echo "[swt] could not discover ${app} (search timed out)" ;;
                error)   echo "[swt] could not discover ${app} (search error)" ;;
                *)       echo "[swt] could not discover ${app} (no match)" ;;
            esac
        fi
    done <<< "$(_json_get_keys "$SWT_SETTINGS_PATH" support.apps)"
}

_discover_support_apps || true

# ── Resolve Board Config ────────────────────────────────────────
SWT_BOARD_URL="$(_json_get "$SWT_SETTINGS_PATH" atlassian.board_url)"
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

# Feedback panel line: count entries in feedback.entries JSON array.
if [ "$SWT_FEEDBACK_ENABLED" = "true" ]; then
    FEEDBACK_COUNT=0
    if [ -n "$SWT_SETTINGS_PATH" ] && [ -f "$SWT_SETTINGS_PATH" ]; then
        FEEDBACK_COUNT="$(_json_get_array "$SWT_SETTINGS_PATH" feedback.entries | { grep -c . 2>/dev/null || true; } | head -n1)"
        FEEDBACK_COUNT="${FEEDBACK_COUNT:-0}"
    fi
    if [ "$FEEDBACK_COUNT" -gt 0 ] 2>/dev/null; then
        INFO_FEEDBACK="Feedback: Enabled (${FEEDBACK_COUNT} entries)"
    else
        INFO_FEEDBACK="Feedback: Enabled (no entries yet)"
    fi
else
    INFO_FEEDBACK="Feedback: Disabled"
fi

# Support panel line: count apps with a non-null repo path vs total tracked apps.
if [ "$SWT_SUPPORT_ENABLED" = "true" ]; then
    SUPPORT_MAPPED=0
    SUPPORT_TOTAL=0
    if [ -n "$SWT_SETTINGS_PATH" ] && [ -f "$SWT_SETTINGS_PATH" ]; then
        SUPPORT_TOTAL="$(_json_get_keys "$SWT_SETTINGS_PATH" support.apps | { grep -c . 2>/dev/null || true; } | head -n1)"
        SUPPORT_TOTAL="${SUPPORT_TOTAL:-0}"
        # support.apps is now an object (APP → path|null). Iterate keys and
        # count non-null/non-empty values to compute the mapped tally.
        SUPPORT_MAPPED=0
        while IFS= read -r _app; do
            [ -n "$_app" ] || continue
            if [ -n "$(_json_get "$SWT_SETTINGS_PATH" "support.apps.${_app}")" ]; then
                SUPPORT_MAPPED=$((SUPPORT_MAPPED + 1))
            fi
        done <<< "$(_json_get_keys "$SWT_SETTINGS_PATH" support.apps)"
    fi
    if [ "$SWT_SUPPORT_MODE" = "true" ]; then
        INFO_SUPPORT="Support: ON (mode active, ${SUPPORT_MAPPED}/${SUPPORT_TOTAL} apps mapped)"
    else
        INFO_SUPPORT="Support: Enabled (${SUPPORT_MAPPED}/${SUPPORT_TOTAL} apps mapped)"
    fi
else
    INFO_SUPPORT="Support: Disabled"
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
swt_line "$INFO_SUPPORT"
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
