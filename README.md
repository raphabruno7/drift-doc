# drift-doc

A [Claude Code](https://claude.com/claude-code) skill that keeps a project's state documentation — `CLAUDE.md`, `AGENTS.md`, `PLAN.md`, skill/agent READMEs, and agent system-prompt files: the docs an agent reads to understand the project — current as the work moves forward. It audits them against the repository and proposes targeted fixes.

It never rewrites docs outright and never invents what changed. A deterministic bash pre-pass (`scripts/audit.sh`) checks documented file paths against git history and flags stale header fields; Claude then applies judgment (`references/judgment.md`) to turn raw findings into a short, actionable report.

## What it catches

- **Renamed/deleted paths** — a doc references `old/path.md` (in backticks or as a markdown link target), but git history shows it was renamed or deleted.
- **Identity drift** — when a doc shows staleness, its project name, version and repo/site URL are checked against the manifest (`package.json` etc.).
- **Missing handoff headers** — `PLAN.md`-style docs missing `Status` / `Owner` / `Last updated` fields.
- **Work that outran the doc** — files the doc names (in backticks, links, or anywhere in its text for non-generic names) changed after the doc's last edit, or the doc still carries a TODO/"to be filled in" marker the repo may have since fulfilled.

## What it deliberately does not do

- Never edits source code — only documentation/instruction files.
- Never rewrites a whole document — only proposes targeted diffs.
- Never commits or pushes on your behalf.
- Never flags stylistic differences or intentionally-open roadmap items — only factual mismatches with the current repo state.

## Known limit

It checks paths, links, handoff headers, staleness and identity (name/version/URL) deterministically, then judges only what those checks point at — it does not read every doc end to end. Prose claims about features or setup (e.g. "password reset, if available", "`/content` is a git submodule") can slip through.

Measured by replaying real history: 12 commits from 5 repos where the author changed code and updated `CLAUDE.md`/`AGENTS.md` in the same commit. Each repo was rebuilt with the code change in place and the doc still at its old version, then audited: drift-doc pointed at that doc 12/12 times and listed no other docs. As a control, the same 12 commits audited after the author's doc update: it pointed at the (now current) doc 0/12 times. An unrestricted Claude Code audit of the stale states also found 12/12, additionally listing 10 other docs (not verified), at the same cost (~$0.11 per run). Small sample, one run per case; these 12 cases were held out while the checks were being tuned.

## Modes

- **Review mode (default).** Reports findings with diffs; nothing is written until you approve each one.
- **Auto mode.** Only when you explicitly ask for it (e.g. "auto mode", "sync the docs directly"). Even then, only findings that carry ready-made replacement text (confirmed renames) are applied directly, because asking for auto mode is your opt-in — everything else still requires a decision.

## Requirements

- `git`, `bash`, `awk`, `grep`, `sed`, `iconv` — all standard on macOS and Linux. No Python, no other runtime dependency.
- A git repository. Outside a git repo, path-history and staleness checks are skipped and the report says so.

## Installation

See [INSTALL.md](INSTALL.md).

## Usage

Inside a Claude Code session in your project, just ask something that implies the docs might be stale, e.g.:

> "check if CLAUDE.md is still accurate"
> "does PLAN.md match what we actually did?"
> "audit the docs before I hand this off"

Claude Code will detect the trigger, invoke the skill, and print a short report:

```
2 finding(s)
● CLAUDE.md: update reference to renamed config path
● PLAN.md: add missing Status/Owner/Last updated header
Which ones should I apply? (ask for an item's diff to see the exact text before approving)
```

Ask for a specific item's diff before approving it, or say "auto mode" / "sync the docs directly" to let ready-made fixes (confirmed renames) apply automatically while everything else still asks.

## Testing

```
bash scripts/test_audit.sh
```

Runs the regression suite for `scripts/audit.sh` against macOS bash/awk and both gawk and mawk (CI covers all three — see `.github/workflows/test.yml`).

## License

MIT — see [LICENSE](LICENSE).
