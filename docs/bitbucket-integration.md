# Bitbucket Integration

This document is the reference for SWT's Bitbucket Cloud integration: a `bb-curl.sh` REST wrapper that lets TPM and SWE agents query and post to Bitbucket without handling raw credentials. Agents make read and write calls via the wrapper at user direction; the safety boundary is the agent hard rule (never see the token, never construct `Authorization` headers, always go through the wrapper).

---

## Decisions

| Decision | Value |
|---|---|
| Bitbucket flavor | Cloud (`api.bitbucket.org/2.0`). Server/DC support deferred behind `bitbucket.flavor` flag. |
| Default state | Opt-in (`bitbucket.enabled: false`). Non-Bitbucket users skip the layer cleanly. |
| Auth model | HTTP Basic auth (email + Atlassian API token). Migrated from Bearer in v0.32.0. |
| Token URL | `https://id.atlassian.com/manage-profile/security/api-tokens` — NOT the legacy Bitbucket app passwords URL. |
| Required scopes | Read: `read:bitbucket-account`, `read:bitbucket-pull-request`, `read:bitbucket-pipeline`. Optional write add-on for agents to post or reply to PR comments at user direction: `write:bitbucket-pull-request`. |
| Token storage | `${SWT_SECRETS_PATH}` (= `${WIN_HOME_DIR}/.swt_secrets`), chmod 600. Three fields: `BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, `BITBUCKET_WORKSPACE`. |
| Settings file `bitbucket` block | `enabled`, `flavor`, `auth.token_source`. Workspace moved to secrets file — it is user-specific account data, not project config. |
| Initial ops scope | Read and write via `bb-curl` at user direction. Safety boundary is the agent hard rule (never see token, never construct headers, always go through the wrapper). |
| Schema version | `_schema: 5`. v3 added the `bitbucket` block. v4 adds the `monitor` block (Monitor Mode polling, per-category policies, counter-response prompt). v5 adds the `review` block (Review Mode posting, per-finding rating threshold, comment polishing prompt). |

---

## REST Layer (`bb-curl`)

`scripts/bb-curl.sh` is the authenticated REST wrapper — the only path for Bitbucket access. Every call sources credentials from `.swt_secrets` inside a subshell; the token never enters the caller's environment and is never echoed. The wrapper is verb-agnostic: agents call `GET` for read ops and `POST`/`PUT`/`PATCH`/`DELETE` for write ops at user direction (for example, posting a reply to a PR comment). The secrets hard rule applies to all calls regardless of verb.

**Delivered artifacts:**
- `scripts/bb-curl.sh` — REST wrapper, HTTP Basic auth, sources secrets locally, never echoes credentials.
- `deploy.sh` — `_resolve_bitbucket_secrets` function, `--setup-bitbucket` interactive setup flow, schema migration v2→v3, schema migration v3→v4 (`monitor` block with defaults), schema migration v4→v5 (`review` block with defaults).
- `swt_settings.json` schema bumped to v3 (`bitbucket` block added, disabled by default), then v4 (`monitor` block added with polling interval, per-category policies, and counter-response prompt), then v5 (`review` block added with Review Mode posting, per-finding rating threshold, and comment polishing prompt).
- `${SWT_SECRETS_PATH}` template with `# === Bitbucket Cloud ===` header and 3 fields (`BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, `BITBUCKET_WORKSPACE`).
- Hard rule "NEVER read or echo secrets" added to all agent definitions.
- Full docs: `SETUP.md` Section 6, `CLAUDE.md` Bitbucket Integration section, `tpm-agent.md` Bitbucket Integration section, `README.md` features, schema row, and directory tree.

**Usage:**

```bash
# Relative paths are prepended with https://api.bitbucket.org/2.0
scripts/bb-curl.sh GET /user
scripts/bb-curl.sh GET /repositories/herzog/cmms-api/pullrequests
scripts/bb-curl.sh GET /repositories/herzog/cmms-api/pullrequests/42/comments

# Find the open PR for a specific branch (used by Monitor Mode on startup)
scripts/bb-curl.sh GET '/repositories/herzog/cmms-api/pullrequests?q=source.branch.name="bugfix/CMMS-1234-foo"&state=OPEN'

# Post an overview comment
scripts/bb-curl.sh POST /repositories/herzog/cmms-api/pullrequests/42/comments \
    -H 'Content-Type: application/json' \
    -d '{"content":{"raw":"Fixed the null check — added guard on line 84."}}'

# Post an inline reply (parent.id = comment being replied to; inline.path + inline.to = line anchor)
scripts/bb-curl.sh POST /repositories/herzog/cmms-api/pullrequests/42/comments \
    -H 'Content-Type: application/json' \
    -d '{"content":{"raw":"Done."},"parent":{"id":101},"inline":{"path":"src/Services/EquipmentService.cs","to":84}}'

# Absolute paths (e.g. paginated next-links) are used as-is
scripts/bb-curl.sh GET https://api.bitbucket.org/2.0/repositories/herzog/cmms-api/pullrequests?page=2
```

**Secrets resolution chain** (first file found wins):
1. `$SWT_SECRETS_PATH`
2. `dirname($SWT_SETTINGS_PATH)/.swt_secrets`
3. `/mnt/c/Users/$USER/.swt_secrets` (WSL)
4. `/c/Users/$USER/.swt_secrets` (Git Bash)

---

## Per-User Shareability

For someone fresh-cloning the repo:

1. Run `deploy.sh --setup` and opt into Bitbucket when prompted, or run `deploy.sh --setup-bitbucket` directly.
2. The setup creates `${SWT_SECRETS_PATH}` (chmod 600) with template lines for `BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, and `BITBUCKET_WORKSPACE`, prompts for the workspace slug, and flips `bitbucket.enabled: true` in `swt_settings.json`.
3. Fill in `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN` in the secrets file. The workspace line is pre-populated by setup.
4. `scripts/bb-curl.sh` ships with the repo and works for every user once their secrets file is populated.
5. `SETUP.md` Section 6 is the authoritative step-by-step walkthrough.
6. Hard rules against reading or echoing secrets apply repo-wide and travel with every clone.

**TPM-driven alternative:** instead of running `--setup-bitbucket` interactively, ask TPM to do it in an `swt` session. TPM creates the secrets template (chmod 600), pre-populates the workspace line, and updates `swt_settings.json`. The only remaining manual step is pasting the token.
