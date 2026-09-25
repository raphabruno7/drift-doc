# Judgment rules for drift-doc findings

Read this only when `scripts/audit.sh` returned at least one finding — skip it entirely for a clean report.

## The core invariant

**Auto mode may only write text that a tool result already produced — never text the model composed.** A finding being verified (the field is absent, the path doesn't exist) is not the same as an edit being determined (what value goes in the field). Only apply a finding automatically when the JSON already carries the exact replacement text (currently: only `missing_path` findings of kind "renamed", which carry `replacement_text`). Every other finding — even one marked directly verified for its own existence — gets asked about, because writing it requires inventing content.

## After judging: drop what doesn't need an edit

Judging a finding (below) can conclude one of two ways: it needs an edit, or it doesn't (false positive, already fixed elsewhere, not real drift). Only the first kind goes in the report. The second kind is dropped completely — no mention, no explanation, not even a tally. The report exists to get edits approved, not to narrate the investigation.

## Per-finding-type judgment

- **`missing_path` (kind "renamed")** — write the diff straight from `line`/`old_text`/`replacement_text`; the finding already has everything needed, don't `Read` the doc.
- **`missing_path` (kind "deleted", no `replacement_text`)** — the path is confirmed gone, but what to write instead requires looking at what replaced it, if anything. Use the finding's `context` (a few lines around it) to judge phrasing; only fall back to `git log -p` or reading the current replacement file if `context` genuinely isn't enough to write the diff. Don't `Read` the doc itself.
- **`missing_header` (whole header absent)** — never write `suggested_block` verbatim, it contains `[fill in]` placeholders. Show it to the user as a preview, ask one question to collect the `Status` and `Owner/context` values, then write the block with those real values substituted in. `Last updated` is already a real, robust reference (date + short commit SHA, not just a date, since a SHA can be re-verified with `git show` and a bare date can't) — keep it as given.
- **`missing_header_field` (only some fields absent)** — same rule per field: if `suggested_value` is present (only happens for `Last updated`), propose it; otherwise ask the user, don't invent it.
- **`staleness_pressure`** — a signal, not a conclusion. Look at `sample_recent_commits` and decide whether the doc's content actually needs a change, or whether the doc is fine and those commits are unrelated. Don't flag it further if the commits don't obviously touch what the doc describes. Before concluding the doc is fine, also check its identity claims against the repo's manifest (`package.json`, `pyproject.toml`, `Cargo.toml` or equivalent, plus `git remote get-url origin`): project name, version and repository/site URL. Read only the lines that state them (`grep -n`), not the whole doc. A mismatch there is a finding; report it with the manifest value as evidence.

## Applying edits per mode

- **Review mode:** never apply edits automatically. Present the full report and diffs, then ask which findings to apply. Only write changes that are explicitly approved, one file at a time.
- **Auto mode:** apply only findings that carry ready-made replacement text (renamed-path findings) directly — the user opted in by requesting auto mode. Everything else — deleted paths with no replacement, header fields, staleness pressure — still gets asked about, even in auto mode. Print a combined report afterward: what was auto-applied vs. what still needs a decision.
- In both modes: never commit or push as part of this skill.

## Actually writing an approved edit

The `Edit` tool requires a prior `Read` of the file, even though the finding's `old_text`/`context` already tells you exactly what to change — that precondition can't be skipped. But it doesn't require reading the *whole* file: `Read` with `offset` set a few lines above the finding's `line` and a small `limit` (e.g. `offset = max(1, line - 5)`, `limit = 15`) satisfies it. Never `Read` the full document just to apply an edit you already have the exact text for.
