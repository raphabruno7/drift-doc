#!/bin/bash
# Regression suite for audit.sh. Run after any change to audit.sh.
# Only depends on git + bash + grep/sed — same footprint as audit.sh itself,
# so anyone who can run the skill can run this.
set -u
SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd)
AUDIT="$SCRIPT_DIR/audit.sh"
PASS=0
FAIL=0

need() { command -v "$1" >/dev/null 2>&1 || { echo "SKIP: missing $1"; exit 1; }; }
need git

new_repo() {
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@t.com
  git -C "$d" config user.name t
  printf '%s' "$d"
}

# field <json> <name>: first occurrence of a flat (non-array) field's value,
# unquoted. Good enough for our fixtures (no embedded quotes in test data).
field() {
  local q='"'
  printf '%s' "$1" | grep -oE "${q}$2${q}:(${q}[^${q}]*${q}|null|true|false|-?[0-9]+)" | head -1 | sed -E "s/^${q}$2${q}://; s/^${q}//; s/${q}\$//"
}

count() { # count occurrences of a literal grep pattern
  printf '%s' "$1" | grep -o "$2" | wc -l | tr -d ' '
}

empty_findings() {
  printf '%s' "$1" | grep -q '"documents_with_findings":\[\]'
}

# check <name> <expected> <actual>
check() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; FAIL=$((FAIL+1))
  fi
}

# 1: simple rename
d=$(new_repo)
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `src/a.py`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" replacement_text); check "rename_simple" "src/b.py" "$got"
rm -rf "$d"

# 2: chained rename resolves to final
d=$(new_repo)
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename1
git -C "$d" mv src/b.py src/c.py; git -C "$d" commit -qm rename2
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `src/a.py`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" replacement_text); check "rename_chain" "src/c.py" "$got"
rm -rf "$d"

# 3: renamed then deleted -> no replacement
d=$(new_repo)
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename
git -C "$d/src" rm -q b.py; git -C "$d" commit -qm "delete final"
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `src/a.py`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" directly_verified); check "renamed_then_deleted_unverified" "false" "$got"
got=$(field "$out" replacement_text); check "renamed_then_deleted_no_replacement" "null" "$got"
rm -rf "$d"

# 4: glob and version string are not findings
d=$(new_repo)
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `convex/*.ts`. Version `v1.2.3`. Repo `anthropic/claude-code`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(empty_findings "$out" && echo yes); check "glob_version_not_findings" "yes" "$got"
rm -rf "$d"

# 5: whole header missing -> consolidated
d=$(new_repo)
printf 'No header at all, just prose.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" type); check "missing_header_consolidated" "missing_header" "$got"
got=$(count "$out" '\[fill in\]'); [ "$got" -gt 0 ] && got=yes; check "missing_header_has_placeholders" "yes" "$got"
rm -rf "$d"

# 6: partial header missing
d=$(new_repo)
printf 'Status: done\nOwner: x\n\nOnly last updated missing.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" field); check "missing_header_field_partial" "Last updated" "$got"
got=$(field "$out" suggested_value); [ "$got" != "null" ] && got=set; check "missing_header_field_suggests_value" "set" "$got"
rm -rf "$d"

# 7: dirty doc suppresses staleness
d=$(new_repo)
printf 'Project notes referencing `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x"
echo "uncommitted edit" >> "$d/CLAUDE.md"
out=$("$AUDIT" "$d")
got=$(empty_findings "$out" && echo yes); check "dirty_doc_suppresses_staleness" "yes" "$got"
rm -rf "$d"

# 8: staleness fires on referenced path change
d=$(new_repo)
printf 'Project notes referencing `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x, referenced by CLAUDE.md"
out=$("$AUDIT" "$d")
got=$(count "$out" '"type":"staleness_pressure"'); check "staleness_fires_on_change" "1" "$got"
rm -rf "$d"

# 9: staleness does not fire on unrelated change
d=$(new_repo)
printf 'Project notes referencing `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "y, unrelated" > "$d/src/y.py"
git -C "$d" add -A; git -C "$d" commit -qm "unrelated change"
out=$("$AUDIT" "$d")
got=$(empty_findings "$out" && echo yes); check "staleness_ignores_unrelated" "yes" "$got"
rm -rf "$d"

# 10: non-git dir reports note
d=$(mktemp -d)
printf 'Status: done\n' > "$d/PLAN.md"
out=$("$AUDIT" "$d")
got=$(field "$out" is_git_repo); check "non_git_is_git_repo_false" "false" "$got"
got=$(count "$out" '"note"'); check "non_git_note" "1" "$got"
rm -rf "$d"

# 11: leading-slash path is repo-root relative; staleness still fires
d=$(new_repo)
printf 'Project notes referencing `/src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x"
out=$("$AUDIT" "$d")
got=$(count "$out" '"type":"staleness_pressure"'); check "leading_slash_staleness" "1" "$got"
rm -rf "$d"

# 12: markdown link to a deleted file is a finding, old_text as written
d=$(new_repo)
mkdir -p "$d/docs"; echo gone > "$d/docs/gone.md"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d/docs" rm -q gone.md; git -C "$d" commit -qm "delete gone"
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee [the doc](./docs/gone.md#intro).\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" old_text); check "md_link_deleted_old_text" "./docs/gone.md" "$got"
got=$(field "$out" replacement_text); check "md_link_deleted_no_replacement" "null" "$got"
rm -rf "$d"

# 13: markdown link to a renamed file keeps the doc's prefix in the replacement
d=$(new_repo)
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\n![img](/src/a.py)\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" replacement_text); check "md_link_renamed" "/src/b.py" "$got"
rm -rf "$d"

# 14: URLs, mailto and pure anchors in links are not findings
d=$(new_repo)
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\n[a](https://x.io/y.md) [b](mailto:a@b.co) [c](#top)\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(empty_findings "$out" && echo yes); check "md_link_urls_ignored" "yes" "$got"
rm -rf "$d"

# 15: markdown link to a file that never existed is a finding
d=$(new_repo)
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\n![shot](./docs/assets/shot.png)\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(field "$out" old_text); check "md_link_never_tracked" "./docs/assets/shot.png" "$got"
got=$(count "$out" 'never tracked'); check "md_link_never_tracked_evidence" "1" "$got"
rm -rf "$d"

# 16: never-tracked backtick paths and extensionless link targets stay silent
d=$(new_repo)
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nExample `lib/foo.py`. Open [the dashboard](/dashboard).\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out=$("$AUDIT" "$d")
got=$(empty_findings "$out" && echo yes); check "never_tracked_code_and_routes_ignored" "yes" "$got"
rm -rf "$d"

# 17: staleness finding carries manifest identity and the doc's identity lines
d=$(new_repo)
printf '{\n  "name": "new-name",\n  "version": "2.0.0"\n}\n' > "$d/package.json"
printf '# old-name\n\nVersion 1.0. Code in `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x"
out=$("$AUDIT" "$d")
got=$(field "$out" manifest_name); check "identity_manifest_name" "new-name" "$got"
got=$(field "$out" manifest_version); check "identity_manifest_version" "2.0.0" "$got"
got=$(count "$out" '1: # old-name'); check "identity_doc_title_line" "1" "$got"
rm -rf "$d"

# 18: truncated identity lines stay valid UTF-8 even when the cut lands mid-character
d=$(new_repo)
printf '{\n  "name": "n",\n  "version": "1.0.0"\n}\n' > "$d/package.json"
long=$(printf 'ação%.0s' $(seq 1 60))
printf '# t\n\nVersão 1.0 %s\n\nCode in `src/x.py`.\n' "$long" > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x"
out=$("$AUDIT" "$d")
got=$(printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo valid); check "identity_lines_valid_utf8" "valid" "$got"
rm -rf "$d"

echo ""
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
[ "$FAIL" -eq 0 ]
