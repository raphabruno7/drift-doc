---
name: drift-doc
description: This skill should be used when auditing whether a project's state documentation (CLAUDE.md, PLAN.md, AGENTS.md, README files describing skills/agents, and agent system-prompt files such as those for voice or conversation agents) still matches the current state of the codebase. Trigger it when the user asks to check, update, or sync project documentation, after landing a chunk of work (a feature, refactor or fix) to keep those docs current, when starting work on a task handoff, or when the user mentions that CLAUDE.md, PLAN.md, AGENTS.md, or an agent prompt file seems stale or out of date. Runs in review mode by default (report + diffs, nothing written until approved); runs in auto mode — applying findings directly without per-diff approval — only when the user explicitly asks for auto mode, automatic sync, or says to update the docs directly.
---

# Drift Doc

## Overview

Keep the docs an agent (or whoever picks up the work) reads to understand the project current as the work moves forward: audit them against verifiable evidence from the repository and report concrete divergences with proposed diffs. Never rewrite documentation outright and never fabricate what changed.

## Modes

- **Review mode (default).** Report + diffs, nothing written until approved.
- **Auto mode.** Only when explicitly requested (e.g. "auto mode", "atualiza automaticamente", "sync the docs directly"). See `references/judgment.md` for exactly what it may write once the user has opted in.

## Scope lock

Only read and propose edits to documentation/instruction files:
- Files named CLAUDE.md, AGENTS.md or PLAN.md (any location, any case variant)
- README files that document a skill, agent or prompt (inside `skills/`, `agents/`, `prompts/`, or next to a `SKILL.md`) — not a project's product README
- Agent/system-prompt files (e.g. `**/prompts/*.md`, `**/system_prompt*`)

Never edit source code as part of this skill. If the audit surfaces a source-code bug or TODO, mention it as a note, not as a proposed edit.

## Workflow

1. **Run the deterministic pre-pass first, always.** Execute `scripts/audit.sh <project_root>` (defaults to cwd; pure bash + git/awk/grep, no runtime dependency beyond what a git repo already implies). It finds the state documents and checks them against git/filesystem — do not re-discover documents or re-run these checks by hand.

2. **If `documents_with_findings` is empty:** report in one line that no broken paths, missing handoff headers or staleness signals were found, and stop. Never say the docs are "up to date" or "accurate": the pre-pass does not check prose claims (project name, version, domain), so a clean result is not a content check. If `is_git_repo` is `false`, say instead that path-history and staleness checks were skipped.

3. **If there are findings, read `references/judgment.md` before acting on any of them.** It has the write-safety rule and the per-finding-type judgment guidance — don't skip it, and don't improvise judgment it already covers.

4. **Produce an audit report listing only findings that need an edit, one line per finding, nothing else:**
   ```
   <N> finding(s)
   ● <file>: <change, imperative, <12 words, no line number, no diff text>
   ```
   Open with `<N> finding(s)` (N = findings surviving judgment), nothing else on that line, no emoji, no color markup. Then bullet (`●`) + plain filename (no bold, no other markup) per line. No headers, no justification, no old→new text, no line numbers. End with "Which one should I apply?" when N=1, or "Which ones should I apply?" when N>1, followed by "(ask for an item's diff to see the exact text before approving)." Show the actual diff for an item only when the user asks for it, at approval time — compute it then from the finding's `line`/`context` fields (see `references/judgment.md`), never by `Read`-ing the full document. Write this report and every other message in whatever language the conversation is already in — nothing here is meant to force English on a non-English user.

   If judgment in step 3 concludes a finding doesn't actually need a change (false positive, already fixed, not real drift), drop it silently — do not list it, do not explain why, not even a one-line count. If the script returned findings but step 3 drops every single one, output one line ("No update needed for the flagged items.") and stop.

   Apply edits per the active mode as `references/judgment.md` describes.

5. **Stop after the report and any applied/approved edits for the current session.** Does not run in the background or monitor the repo continuously.

## What NOT to flag

- Stylistic differences, or a roadmap item intentionally left open by design — staleness means factual mismatch with current repo state, not incompleteness.
- Anything that can't be backed by a concrete git/filesystem check.
