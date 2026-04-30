# Bitbucket Integration + Monitor Mode — Implementation Plan

**Status as of v0.35.0:** Phase 1a and Phase 1b complete and end-to-end verified. Phase 2a through Phase 2d pending.

This document is the single source of truth for the multi-phase initiative adding Bitbucket Cloud integration and a `swt --monitor` mode to SWT. Update the status table below as phases ship.

---

## Phase Status

| Phase | Description | Status | Version landed |
|---|---|---|---|
| **1a** | Bitbucket foundation: secrets file flow, `bb-curl` wrapper, schema migration, hard rules, full docs | ✅ **Complete** | v0.32.2 |
| **1b** | MCP server scouting + integration | ✅ **Complete** | v0.35.0 |
| **2a** | `--monitor` flag, PR resolution, info-box updates | ⏳ Pending | — |
| **2b** | `ScheduleWakeup` polling loop, comment fetch + categorization, action gates | ⏳ Pending | — |
| **2c** | Per-comment tracking, revert flow, resolution checklist | ⏳ Pending | — |
| **2d** | Local test command runner, CI failure handling | ⏳ Pending | — |

---

## Decisions Locked

| Decision | Value | Notes |
|---|---|---|
| Bitbucket flavor | Cloud (`api.bitbucket.org/2.0/...`) | Server/DC support deferred behind `bitbucket.flavor` flag |
| Default state | Opt-in (`bitbucket.enabled: false`) | Non-Bitbucket users skip the layer cleanly |
| Auth model | HTTP Basic auth (email + Atlassian API token) | Migrated from Bearer in v0.32.0 |
| Token URL | `https://id.atlassian.com/manage-profile/security/api-tokens` | NOT the legacy `bitbucket.org/account/settings/app-passwords/` |
| Required scopes | `read:bitbucket-account`, `read:bitbucket-pull-request`, `read:bitbucket-pipeline` | Read-only by design for Phases 1a-2d. Write ops out of scope. |
| Token storage | `${SWT_SECRETS_PATH}` (= `${WIN_HOME_DIR}/.swt_secrets`) | chmod 600. Three fields: `BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, `BITBUCKET_WORKSPACE` |
| Settings file (`swt_settings.json`) `bitbucket` block | `enabled`, `flavor`, `auth.token_source` | Workspace moved to secrets file in v0.32.1 |
| MCP server choice | Scout existing public ones first; build minimal custom only if needed | Phase 1b decision |
| Initial ops scope | Read-only (PRs, comments, branches, pipeline status) | Mirrors no-destructive-git philosophy |
| Test runner exception (monitor mode) | Project-configurable via `monitor.test_command` in `swt_settings.json` | Narrow carve-out from NO DOTNET rule. Active only in monitor mode. |
| Polling interval | Default 20 min, min 60s, max 1 hour | Configurable via `monitor.poll_interval_seconds` |
| Comment author filter | Humans only; bot accounts (CodeRabbit, pipeline bots) logged but never acted on | `monitor.ignore_bot_authors: true` default |
| Comment scope | Both PR-level and inline; inline comments include line-anchor context | |
| Sequencing | Plan both features together; ship Phase 1 first, then Phase 2 on top | |
| Resolution checklist | Top-of-`## Monitor Activity` section in Obsidian; TPM-owned (clobbers manual edits) | Standard `[ ]` / `[x]` markdown checkboxes |
| Schema version | Currently `_schema: 3` | v3 added bitbucket block; future bumps as needed |

---

## Phase 1a — Bitbucket Integration (✅ Complete, shipped v0.32.2)

The Bitbucket foundation is fully shipped. End-to-end auth verified against `herzog-technologies` workspace (472 repos accessible).

**Delivered artifacts:**
- `scripts/bb-curl.sh` — REST wrapper, sources secrets locally, HTTP Basic auth, never echoes credentials
- `deploy.sh` — `_resolve_bitbucket_secrets`, `--setup-bitbucket` interactive flow, schema migration v2→v3
- `swt_settings.json` schema bumped to v3, `bitbucket` block added (disabled by default)
- `~/.swt_secrets` template with `# === Bitbucket Cloud ===` header and 3 fields
- Hard rule "NEVER read or echo secrets" added byte-identical to all 4 agent definitions
- Full docs: SETUP.md Section 6, CLAUDE.md Bitbucket Integration blurb, tpm-agent.md Bitbucket Integration section, README.md Features bullet + schema row + directory tree

**Verified end-to-end:** Token + email + workspace + Basic auth = 200 OK from Bitbucket Cloud. Real workspace queried, real repos listed.

---

## Phase 1b — MCP Server Integration (✅ Complete, shipped v0.35.0)

The Bitbucket MCP layer is shipped. Agents now call high-level `mcp__bitbucket__*` tools instead of constructing REST paths by hand. Same security posture as Phase 1a — the MCP server never holds the auth token in its process env, every HTTP call shells out to `bb-curl`.

**Decision rationale.** Scouting reviewed the public landscape (notably `tugudush/bitbucket-mcp` and a handful of similar community projects). Decision was to build a custom in-repo server rather than adopt a third-party package. Reasoning:
- **Supply-chain risk reduction** — no external npm dependency tree, no transitive packages to audit, no version drift to chase.
- **Smaller surface area** — we ship exactly the 7 read-only tools we need; nothing else.
- **Alignment with SWT's "own small tools" pattern** — `bb-curl`, `swt-statusline.sh`, `clipboard-read.ps1`, and `deploy.sh` are all in-repo, zero-dep, easy to read end-to-end. The MCP server fits the same mold.
- **Auth posture preserved** — by shelling out to `bb-curl` for every HTTP call, the token never enters the MCP server's process env. A third-party server would have wanted the credentials directly.

**Delivered artifacts:**
- `mcp/bitbucket/index.js` — zero-dep Node entry point, JSON-RPC over stdio, shells out to `scripts/bb-curl.sh` for every HTTP call.
- `mcp/bitbucket/package.json` — minimal manifest, no runtime dependencies.
- `.mcp.json` at repo root — registers the server with the Claude Code harness; every clone gets the same wiring.
- Workspace resolution via `SWT_BB_WORKSPACE_DISPLAY` env var, with the secrets file as a fallback parser. The token is never in the MCP server's environment.

**Tools exposed (7):**

| Tool | Purpose |
|------|---------|
| `list_pull_requests` | List PRs in a repo (filterable by state) |
| `get_pull_request` | Get full PR details by ID |
| `get_pr_diff` | Get the unified diff text for a PR |
| `get_pr_comments` | List inline + PR-level comments |
| `list_branches` | List branches (with optional substring filter) |
| `get_pipeline_status` | Latest pipeline statuses (filterable by commit) |
| `search_repos` | List repos in the configured workspace |

Required/optional argument shapes are documented in `tpm-agent.md` under the MCP Tools Available subsection.

**bb-curl status.** Stays as the escape hatch. Agents prefer the MCP tools when an operation fits, and drop down to `bb-curl` only for endpoints the MCP server doesn't cover. Documented in `tpm-agent.md`.

---

## Phase 2 — Monitor Mode (⏳ Pending)

A new mode `swt --monitor` that watches a PR for new comments and CI failures, acts on them per a configurable rubric, and surfaces work to the user via Obsidian.

### Phase 2a — `--monitor` flag, PR resolution, info-box

**Adds:**
- New CLI flag: `swt --monitor`. Mutually exclusive with `--branch` and `--support`.
- Pre-flight gate: refuses to launch if `bitbucket.enabled` is not true OR if the secrets are missing OR if `monitor.enabled` is false. Clear error message pointing at `--setup-bitbucket` or `monitor.enabled` toggle.
- PR resolution at boot: queries Bitbucket for open PRs by source branch (using `$SWT_BRANCH`). One match → announce. Zero → ask user for link. Multiple → present options.
- Info-box additions: `Monitor: Enabled (poll: 20 min)` and (after PR resolution) `PR: bitbucket.org/.../pull-requests/123`.
- New `monitor` block in `swt_settings.json`:

```json
"monitor": {
  "enabled": true,
  "poll_interval_seconds": 1200,
  "test_command": null,
  "ignore_bot_authors": true,
  "comment_categories": [
    {
      "name": "directive",
      "label": "Clear directive",
      "trigger": "Imperative phrasing (\"add X\", \"rename Y\", \"extract Z\")",
      "action": "act"
    },
    {
      "name": "bug",
      "label": "Substantive bug",
      "trigger": "Reports a defect (\"this throws on empty input\")",
      "action": "act"
    },
    {
      "name": "style",
      "label": "Style / preference",
      "trigger": "Subjective (\"could be cleaner\", \"I'd do this differently\")",
      "action": "propose"
    },
    {
      "name": "question",
      "label": "Question",
      "trigger": "Interrogative (\"why are we doing this?\")",
      "action": "propose"
    },
    {
      "name": "ambiguous",
      "label": "Ambiguous",
      "trigger": "Unclear intent",
      "action": "flag"
    },
    {
      "name": "bot",
      "label": "Bot-authored",
      "trigger": "ignore_bot_authors is true and author is a bot account",
      "action": "log_only"
    }
  ]
}
```

- Schema bump v3 → v4 (one-time migration adds the `monitor` block, defaults `enabled: true`).

### Phase 2b — Polling loop, comment fetch, categorization

**Adds:**
- TPM uses `ScheduleWakeup` to self-pace at `monitor.poll_interval_seconds` intervals.
- On each wake: fetch new comments since last check (compare comment IDs against saved set in Obsidian), fetch latest pipeline status.
- Comment processing flow per comment:
  1. Fetch verbatim — capture comment ID, author, timestamp, body, line anchor (if inline).
  2. Append to Obsidian ticket notes under `## Monitor Activity` section (always, regardless of category).
  3. If `ignore_bot_authors: true` and author is a bot → assign `bot` category, take its action (log_only), done.
  4. Otherwise: evaluate against `comment_categories` in order, assign first matching category.
  5. Take the action defined for that category (see Action enum).
  6. Notify user on next engagement.
- **Fallback:** if no category matches, fall back to `flag` action.

**Action enum (locked):**

| Action | Behavior |
|---|---|
| `act` | Deploy SWE immediately, apply changes, document in Obsidian. No pre-action approval gate. |
| `propose` | Log the comment, formulate a specific recommended action, gate on user approval before acting. |
| `flag` | Log the comment with a flag, no specific proposal. For comments where intent is unclear and TPM doesn't have a confident recommendation. |
| `log_only` | Log the comment, take no further action. |

**Mid-session config edits:** changes to `comment_categories` are picked up on next poll. New comments use new policy; already-evaluated comments keep their original category.

### Phase 2c — Per-comment tracking, revert flow, resolution checklist

**Adds:**
- Per-comment Obsidian schema in `${PROJECT}/${NUMBER}.md` ticket notes:

```markdown
## Monitor Activity

### Resolution Checklist
- [x] Added null check before token property access (#abc123)
- [x] Renamed `userObj` to `user` for consistency (#def456)
- [ ] Extract validation block into `IsTokenValid()` helper — proposed (#ghi789)
- [ ] Reviewer asked about library choice — proposed response (#jkl012)
- [ ] Ambiguous comment about state management — flagged (#mno345)

---

### 2026-04-28 14:35 — Comment #abc123 by @jsmith
> [verbatim comment text]
**Category:** Directive
**Action taken:** Applied
**Files changed:** [details]
**Status:** Awaiting your confirmation
```

- **Resolution checklist semantics:**
  - `[x]` = TPM took action (made the change). Independent of post-hoc approval.
  - `[ ]` = no code change made yet (proposed / flagged / pending).
  - Bot comments NOT included in checklist (only in detail log).
  - TPM-owned, clobbers manual edits.
- **Item format:**
  - `act` outcome: `[x] <one-line summary> (#commentid)`
  - `propose` outcome: `[ ] <one-line summary> — proposed (#commentid)`
  - `flag` outcome: `[ ] <one-line summary> — flagged (#commentid)`
- **Lifecycle transitions:**
  - User approves a proposed item → flip `[ ]` → `[x]`, drop "— proposed" suffix
  - User says "revert comment #abc" → flip `[x]` → `[ ]`, append "— reverted" suffix
- **Revert flow:** TPM reads the comment's entry, extracts documented before/after snippets, deploys SWE to apply reverse-diff via Edit. Surfaces conflicts honestly if other comments touched overlapping lines.

### Phase 2d — Local test command runner, CI failure handling

**Adds:**
- Pipeline failure detection on each poll.
- Pull failure logs from Bitbucket via MCP/bb-curl.
- **If `monitor.test_command` is set:** SWE runs the configured command locally — the **only** dotnet/test command sanctioned by the carve-out from the NO DOTNET hard rule. Document this exception clearly in swe-agent.md.
- SWE investigates failure: stack trace, recent changes, likely cause.
- **If confident in fix:** SWE applies the fix, documents in Obsidian under `## Monitor Activity` → CI failure entry. TPM tells user.
- **If not confident:** SWE surfaces findings + 2–3 candidate fixes. TPM presents to user, waits for direction.

**New hard rules (monitor mode):**
- TPM may use `ScheduleWakeup` only for monitor-mode polling. No other use sanctioned.
- SWE may run **only** `monitor.test_command` (read from `swt_settings.json`) when in monitor mode and a CI failure has been detected. The general NO DOTNET COMMANDS rule applies to all other dotnet invocations and to any SWE not in monitor mode.

### VERSION

Phase 2 lands incrementally:
- Phase 2a → v0.34.0
- Phase 2b → v0.35.0
- Phase 2c → v0.36.0
- Phase 2d → v0.37.0

(Or batched into a single v0.34.0 if shipped together.)

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `ScheduleWakeup` behavior across compaction / context window edges | Verify experimentally during Phase 2b. If unreliable, fallback to "check on next user prompt" — degrades to manual but doesn't break anything. |
| Comment miscategorization | Every gating-category comment ends with a user approval gate. Worst case = redundant approval, never silent damage. |
| Bitbucket API rate limits | 20-min default poll is well under any reasonable limit. Log rate-limit responses if encountered. |
| Public Bitbucket MCP server doesn't exist or is stale | Phase 1b explicit fallback: build minimal custom MCP. ~200 lines of Node, read-only tools. |
| User has multiple PRs for one branch | Boot sequence asks user to pick. Don't guess. |
| Two comments touch overlapping lines | Per-comment revert flags the conflict; TPM doesn't try to merge automatically. |

---

## Per-User Shareability (clones)

For someone fresh-cloning the repo:
1. They run `deploy.sh --setup` (extend existing setup) → offers "Configure Bitbucket integration?" (Y/n).
2. **If yes:** setup runs `--setup-bitbucket` (creates `.swt_secrets` template at `${SWT_SECRETS_PATH}`, prompts for workspace + flavor, flips `bitbucket.enabled: true`).
3. **If no:** nothing happens. The Bitbucket layer is fully optional and skipped at boot.
4. **MCP config** (Phase 1b) lives in `.mcp.json` at repo root (committed) so every clone gets the same MCP server reference.
5. **`scripts/bb-curl.sh`** ships with the repo (works for everyone).
6. **SETUP.md Section 6** is the authoritative walkthrough.
7. **Hard rules** apply repo-wide so security posture travels with the clone.

---

## How to Update This Document

- **As phases ship:** flip the status row to ✅, add the version that landed, update any decision rows that changed.
- **Mid-phase scope changes:** edit the relevant phase section in place; note the change in a new "Changelog" footer if it's substantive.
- **New phases:** append to the Phase Status table and add a new section. Don't renumber existing phases.

This document is intended to be authoritative. If the agent definitions or SETUP.md drift from this, that's a bug — reconcile against this document.
