#!/usr/bin/env bash
# bb-curl.sh — Bitbucket REST API curl wrapper for Project-SWT.
#
# Purpose:
#   Thin, secure wrapper around `curl` for hitting the Bitbucket Cloud REST
#   API (v2.0) with an API token + email sourced from a `.swt_secrets` file
#   (HTTP Basic auth; see resolution chain in Dependencies). Designed so
#   SWE/QA agents can read PRs, comments, and pipelines without ever seeing
#   or printing the raw token.
#
# Dependencies:
#   - bash, curl
#   - A `.swt_secrets` file containing `BITBUCKET_EMAIL=...`,
#     `BITBUCKET_TOKEN=...`, and `BITBUCKET_WORKSPACE=...` (created by
#     `deploy.sh --setup-bitbucket`). The token is the new Atlassian Cloud
#     API token, generated at
#     https://id.atlassian.com/manage-profile/security/api-tokens — NOT the
#     legacy Bitbucket app password. Resolved in priority order from:
#       1. $SWT_SECRETS_PATH
#       2. dirname($SWT_SETTINGS_PATH)/.swt_secrets
#       3. /mnt/c/Users/$USER/.swt_secrets   (WSL convention)
#       4. /c/Users/$USER/.swt_secrets       (Git Bash convention)
#   - Env vars set by deploy.sh on boot when Bitbucket is enabled:
#       SWT_BB_FLAVOR     ("cloud"; default "cloud") — only "cloud" supported
#
# Usage:
#   bb-curl <METHOD> <PATH> [extra-curl-args...]
#
# Examples:
#   bb-curl GET /user
#   bb-curl GET /repositories/herzog/cmms-api/pullrequests
#   bb-curl GET /repositories/herzog/cmms-api/pullrequests/42/comments
#   bb-curl POST /repositories/herzog/cmms-api/pullrequests/42/comments \
#           -d '{"content":{"raw":"hello"}}'
#
# Path can be:
#   - Relative (starts with "/"): prepended with https://api.bitbucket.org/2.0
#   - Absolute (starts with "http"): used as-is — useful for paginated `next`
#     URLs returned by the API.
#
# Security notes:
#   - The token is sourced inside a subshell-safe pattern; it is never written
#     to stdout/stderr, never logged, and never exported back to the caller.
#   - This script deliberately does NOT enable `set -x` or any debug tracing
#     that could echo the Authorization header.
#   - Only SELECT-equivalent reads are needed by most agent flows; write
#     methods (POST/PUT/PATCH/DELETE) are accepted but used at the agent's
#     own discretion under the project's hard rules.
#
# Setup:
#   Run `deploy.sh --setup-bitbucket` to create the `.swt_secrets` file
#   (with BITBUCKET_EMAIL, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE) and
#   populate SWT_BB_FLAVOR in swt_settings.json.
#
# Note: deliberately uses `set -uo pipefail` (no `-e`) so we control error
# flow explicitly via early `exit 1` calls with clear messages on stderr.

set -uo pipefail

# ---------------------------------------------------------------------------
# Help text — printed on `-h`, `--help`, or no args. Never includes secrets.
# ---------------------------------------------------------------------------
_print_help() {
    cat >&2 <<'EOF'
bb-curl — Bitbucket REST API wrapper

Usage:
  bb-curl <METHOD> <PATH> [extra-curl-args...]

Methods:
  GET, POST, PUT, PATCH, DELETE

Path:
  Relative (starts with "/"):  prepended with https://api.bitbucket.org/2.0
  Absolute (starts with "http"): used as-is (for paginated next-links)

Examples:
  bb-curl GET /user
  bb-curl GET /repositories/herzog/cmms-api/pullrequests
  bb-curl GET /repositories/herzog/cmms-api/pullrequests/42
  bb-curl GET /repositories/herzog/cmms-api/pullrequests/42/comments
  bb-curl POST /repositories/herzog/cmms-api/pullrequests/42/comments \
          -d '{"content":{"raw":"hello"}}'

Required env (set by deploy.sh --setup-bitbucket):
  SWT_BB_FLAVOR      "cloud" (only supported value in this version)

Required secrets (in .swt_secrets, resolved via SWT_SECRETS_PATH /
SWT_SETTINGS_PATH dirname / Windows home fallbacks):
  BITBUCKET_EMAIL      Atlassian account email (used as Basic-auth user)
  BITBUCKET_TOKEN      Atlassian Cloud API token (Basic-auth password);
                       generate at
                       https://id.atlassian.com/manage-profile/security/api-tokens
  BITBUCKET_WORKSPACE  Bitbucket workspace slug (e.g. herzog)
EOF
}

# ---------------------------------------------------------------------------
# 1. Argument intake & help short-circuit.
# ---------------------------------------------------------------------------
if [ "$#" -eq 0 ]; then
    _print_help
    exit 0
fi

case "${1:-}" in
    -h|--help)
        _print_help
        exit 0
        ;;
esac

if [ "$#" -lt 2 ]; then
    echo "bb-curl: missing arguments — expected <METHOD> <PATH> [curl-args...]" >&2
    _print_help
    exit 1
fi

method="$1"
path="$2"
shift 2  # remaining "$@" is passed straight to curl

# ---------------------------------------------------------------------------
# 2. Method validation — accept only the standard REST verbs.
# ---------------------------------------------------------------------------
case "$method" in
    GET|POST|PUT|PATCH|DELETE) : ;;
    *)
        echo "bb-curl: unsupported HTTP method '$method' (allowed: GET, POST, PUT, PATCH, DELETE)" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# 3. Flavor sanity gate.
#    Flavor stays in swt_settings.json because it's project-level config,
#    not user-specific. Workspace presence is checked after secrets sourcing
#    (see step 4) since it now lives in .swt_secrets.
# ---------------------------------------------------------------------------
SWT_BB_FLAVOR="${SWT_BB_FLAVOR:-cloud}"

if [ "$SWT_BB_FLAVOR" != "cloud" ]; then
    echo "bb-curl: only flavor=cloud is supported in this version (got: $SWT_BB_FLAVOR)" >&2
    exit 1
fi

BASE_URL="https://api.bitbucket.org/2.0"

# ---------------------------------------------------------------------------
# 4. Token sourcing — strictly local. We auto-export anything in the resolved
#    .swt_secrets file only for the duration of this script's process; it is
#    NOT written back to the caller's environment, and BITBUCKET_TOKEN is
#    never echoed. Resolution chain (first existing file wins):
#       1. $SWT_SECRETS_PATH
#       2. dirname($SWT_SETTINGS_PATH)/.swt_secrets
#       3. /mnt/c/Users/$USER/.swt_secrets   (WSL)
#       4. /c/Users/$USER/.swt_secrets       (Git Bash)
# ---------------------------------------------------------------------------
_swt_user="${USER:-$(id -un 2>/dev/null)}"
_swt_settings_dir=""
if [ -n "${SWT_SETTINGS_PATH:-}" ]; then
    _swt_settings_dir="$(dirname "$SWT_SETTINGS_PATH")"
fi

_secrets_candidates=(
    "${SWT_SECRETS_PATH:-}"
    "${_swt_settings_dir:+${_swt_settings_dir}/.swt_secrets}"
    "/mnt/c/Users/${_swt_user}/.swt_secrets"
    "/c/Users/${_swt_user}/.swt_secrets"
)

for _path in "${_secrets_candidates[@]}"; do
    [ -z "$_path" ] && continue
    [ ! -f "$_path" ] && continue
    set -a
    # shellcheck disable=SC1090
    . "$_path" 2>/dev/null || true
    set +a
    [ -n "${BITBUCKET_TOKEN:-}" ] && break
done

BITBUCKET_TOKEN="${BITBUCKET_TOKEN:-}"
if [ -z "$BITBUCKET_TOKEN" ]; then
    echo "bb-curl: BITBUCKET_TOKEN not set. Did you run deploy.sh --setup-bitbucket and add your token to .swt_secrets?" >&2
    exit 1
fi

BITBUCKET_EMAIL="${BITBUCKET_EMAIL:-}"
if [ -z "$BITBUCKET_EMAIL" ]; then
    echo "bb-curl: BITBUCKET_EMAIL not set. Add it to your .swt_secrets file alongside BITBUCKET_TOKEN. Run deploy.sh --setup-bitbucket to update the template." >&2
    exit 1
fi

BITBUCKET_WORKSPACE="${BITBUCKET_WORKSPACE:-}"
if [ -z "$BITBUCKET_WORKSPACE" ]; then
    echo "bb-curl: BITBUCKET_WORKSPACE not set. Add it to your .swt_secrets file alongside BITBUCKET_EMAIL and BITBUCKET_TOKEN. Run deploy.sh --setup-bitbucket to update the template." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. URL construction.
# ---------------------------------------------------------------------------
case "$path" in
    http://*|https://*)
        url="$path"
        ;;
    /*)
        url="${BASE_URL}${path}"
        ;;
    *)
        echo "bb-curl: path must start with '/' (relative) or 'http' (absolute); got: $path" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# 6. Curl invocation. -sS = silent but show errors; -f intentionally omitted
#    so 4xx/5xx JSON error bodies still flow back to the caller for parsing.
#    Basic auth via `-u user:pass`; curl builds the Authorization header
#    internally and never echoes the credentials. No shell tracing is
#    enabled anywhere.
# ---------------------------------------------------------------------------
exec curl -sS \
    -X "$method" \
    -u "${BITBUCKET_EMAIL}:${BITBUCKET_TOKEN}" \
    -H "Accept: application/json" \
    "$url" \
    "$@"
