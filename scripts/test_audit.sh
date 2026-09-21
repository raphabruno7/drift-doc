#!/bin/bash
# Regression suite for audit.sh. Run after any change to audit.sh.
# Only depends on git + bash + grep/sed — same footprint as audit.sh itself,
# so anyone who can run the skill can run this.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/audit.sh"
PASS=0
FAIL=0

need() { command -v "$1" >/dev/null 2>&1 || { echo "SKIP: missing $1"; exit 1; }; }
need git

new_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.com
  git -C "$d" config user.name t
  printf '%s' "$d"
}

# field <json> <name>: first occurrence of a flat (non-array) field's value,
# unquoted. Good enough for our fixtures (no embedded quotes in test data).
field() {
  printf '%s' "$1" | grep -oE "\"$2\":(\"[^\"]*\"|null|true|false|-?[0-9]+)" | head -1 | sed -E "s/^\"$2\"://; s/^\"//; s/\"\$//"
}

count() { # count occurrences of a literal grep pattern
  printf '%s' "$1" | grep -o "$2" | wc -l | tr -d ' '
}

empty_findings() {
  printf '%s' "$1" | grep -q '"documents_with_findings":\[\]'
}

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    echo "ok   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; FAIL=$((FAIL+1))
  fi
}

# 1: simple rename
d="$(new_repo)"
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `src/a.py`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out="$("$AUDIT" "$d")"
check "rename_simple" "$([ "$(field "$out" replacement_text)" = "src/b.py" ] && echo 1 || echo 0)"
rm -rf "$d"

# 2: chained rename resolves to final
d="$(new_repo)"
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename1
git -C "$d" mv src/b.py src/c.py; git -C "$d" commit -qm rename2
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `src/a.py`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out="$("$AUDIT" "$d")"
check "rename_chain" "$([ "$(field "$out" replacement_text)" = "src/c.py" ] && echo 1 || echo 0)"
rm -rf "$d"

# 3: renamed then deleted -> no replacement
d="$(new_repo)"
mkdir -p "$d/src"; echo "content long enough for git similarity detection to work" > "$d/src/a.py"
git -C "$d" add -A; git -C "$d" commit -qm init
git -C "$d" mv src/a.py src/b.py; git -C "$d" commit -qm rename
git -C "$d" rm -q src/b.py; git -C "$d" commit -qm "delete final"
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `src/a.py`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out="$("$AUDIT" "$d")"
check "renamed_then_deleted" "$([ "$(field "$out" directly_verified)" = "false" ] && [ "$(field "$out" replacement_text)" = "null" ] && echo 1 || echo 0)"
rm -rf "$d"

# 4: glob and version string are not findings
d="$(new_repo)"
printf 'Status: done\nOwner: x\nLast updated: 2020-01-01\n\nSee `convex/*.ts`. Version `v1.2.3`. Repo `anthropic/claude-code`.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out="$("$AUDIT" "$d")"
check "glob_version_not_findings" "$(empty_findings "$out" && echo 1 || echo 0)"
rm -rf "$d"

# 5: whole header missing -> consolidated
d="$(new_repo)"
printf 'No header at all, just prose.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out="$("$AUDIT" "$d")"
check "missing_header_consolidated" "$([ "$(field "$out" type)" = "missing_header" ] && [[ "$out" == *"[fill in]"* ]] && echo 1 || echo 0)"
rm -rf "$d"

# 6: partial header missing
d="$(new_repo)"
printf 'Status: done\nOwner: x\n\nOnly last updated missing.\n' > "$d/PLAN.md"
git -C "$d" add -A; git -C "$d" commit -qm plan
out="$("$AUDIT" "$d")"
check "missing_header_field_partial" "$([ "$(field "$out" field)" = "Last updated" ] && [ "$(field "$out" suggested_value)" != "null" ] && echo 1 || echo 0)"
rm -rf "$d"

# 7: dirty doc suppresses staleness
d="$(new_repo)"
printf 'Project notes referencing `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x"
echo "uncommitted edit" >> "$d/CLAUDE.md"
out="$("$AUDIT" "$d")"
check "dirty_doc_suppresses_staleness" "$(empty_findings "$out" && echo 1 || echo 0)"
rm -rf "$d"

# 8: staleness fires on referenced path change
d="$(new_repo)"
printf 'Project notes referencing `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "x changed" > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm "change x, referenced by CLAUDE.md"
out="$("$AUDIT" "$d")"
check "staleness_fires_on_change" "$([ "$(count "$out" '"type":"staleness_pressure"')" = "1" ] && echo 1 || echo 0)"
rm -rf "$d"

# 9: staleness does not fire on unrelated change
d="$(new_repo)"
printf 'Project notes referencing `src/x.py`.\n' > "$d/CLAUDE.md"
mkdir -p "$d/src"; echo x > "$d/src/x.py"
git -C "$d" add -A; git -C "$d" commit -qm init
echo "y, unrelated" > "$d/src/y.py"
git -C "$d" add -A; git -C "$d" commit -qm "unrelated change"
out="$("$AUDIT" "$d")"
check "staleness_ignores_unrelated" "$(empty_findings "$out" && echo 1 || echo 0)"
rm -rf "$d"

# 10: non-git dir reports note
d="$(mktemp -d)"
printf 'Status: done\n' > "$d/PLAN.md"
out="$("$AUDIT" "$d")"
check "non_git_note" "$([ "$(field "$out" is_git_repo)" = "false" ] && printf '%s' "$out" | grep -q '"note"' && echo 1 || echo 0)"
rm -rf "$d"

echo ""
echo "$PASS/$((PASS+FAIL)) passed"
[ "$FAIL" -eq 0 ]
