# Installing drift-doc

drift-doc is a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills): a folder with a `SKILL.md` plus supporting scripts that Claude Code loads and invokes automatically when relevant.

## 1. Copy the skill into place

Claude Code looks for skills in two places. Pick one:

**Personal (all your projects), macOS/Linux:**

```bash
git clone https://github.com/raphabruno7/drift-doc.git ~/.claude/skills/drift-doc
```

**Project-only (checked into a specific repo, shared with your team):**

```bash
git clone https://github.com/raphabruno7/drift-doc.git .claude/skills/drift-doc
```

If you'd rather not keep the `.git` history inside your skills folder, export a clean copy instead:

```bash
git clone https://github.com/raphabruno7/drift-doc.git /tmp/drift-doc
git -C /tmp/drift-doc archive --prefix=drift-doc/ HEAD | tar -x -C ~/.claude/skills
```

(`tar -C` needs `~/.claude/skills` to exist already; it does once you have any personal skill installed.)

## 2. Verify it's picked up

Start (or restart) a Claude Code session anywhere, and check that `drift-doc` shows up in the available-skills listing. You can also invoke it directly:

```
/drift-doc
```

or trigger it naturally by asking, inside a project, something like "check if CLAUDE.md is still accurate."

## 3. Make the scripts executable (usually not needed)

Claude Code runs `scripts/audit.sh` via `bash`, not by executing it directly, so no `chmod` is required. If you want to run it by hand:

```bash
chmod +x scripts/audit.sh scripts/test_audit.sh
./scripts/audit.sh /path/to/project
```

## 4. Confirm the test suite passes on your machine

```bash
bash scripts/test_audit.sh
```

This exercises `audit.sh` against your local `awk`/`git`. If it fails, check your `awk` implementation (mawk vs. gawk vs. BSD awk) — the CI workflow (`.github/workflows/test.yml`) pins all three variants and is the reference for expected behavior.

## Updating

```bash
cd ~/.claude/skills/drift-doc   # or .claude/skills/drift-doc for a project install
git pull
```

## Uninstalling

Delete the `~/.claude/skills/drift-doc` folder (or `.claude/skills/drift-doc` for a project install).
