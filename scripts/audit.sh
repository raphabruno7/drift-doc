#!/bin/bash
# Deterministic pre-pass for the drift-doc skill. Pure bash + git + awk/grep/sed
# (no Python) so the skill has no runtime dependency beyond what a git repo
# already implies. See test_audit.sh for the regression suite.
#
# Style constraint: avoids known span limits in static shell parsers used by
# skill security scanners (e.g. NVIDIA SkillSpector), so every line of this
# script gets inspected. Applies to comments too:
# - command substitutions go in unquoted plain assignments, never quoted
#   inline as an argument; pass the variable instead.
# - no literal parentheses or pipe characters inside double-quoted strings;
#   build those with printf -v.
# Re-scan after editing: skillspector scan . --no-llm
set -u

ROOT_ARG="${1:-.}"
ROOT=$(cd "$ROOT_ARG" 2>/dev/null && pwd -P)
if [ -z "$ROOT" ]; then
  echo '{"error":"root not found"}' >&2
  exit 1
fi

TMPDIR_DD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DD"' EXIT

IS_GIT_REPO="false"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IS_GIT_REPO="true"

json_escape() {
  # backslash/quote-escape + real newlines -> literal \n
  awk 'BEGIN{ORS=""} { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); if (NR>1) printf "\\n"; printf "%s", $0 }' <<< "$1"
}

stat_id() {
  stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1" 2>/dev/null
}

# --- doc discovery -----------------------------------------------------
find_doc_files() {
  local prune=( -iname ".git" -o -iname "node_modules" -o -iname ".venv" -o -iname "venv" -o -iname "dist" -o -iname "build" -o -iname "__pycache__" )
  {
    find "$ROOT" \( "${prune[@]}" \) -prune -o -type f \( -iname "CLAUDE.md" -o -iname "AGENTS.md" -o -iname "PLAN.md" -o -iname "system_prompt*" \) -print
    find "$ROOT" \( "${prune[@]}" \) -prune -o -type f -iname "README.md" -print | while IFS= read -r f; do
      rel="${f#"$ROOT"/}"
      case "$rel" in
        README.md|*/skills/*|*/agents/*|*/prompts/*) printf '%s\n' "$f" ;;
      esac
    done
    find "$ROOT" \( "${prune[@]}" \) -prune -o -type f -ipath "*/prompts/*.md" -print
  } 2>/dev/null | while IFS= read -r f; do
    id=$(stat_id "$f")
    printf '%s\t%s\n' "$id" "$f"
  done | awk -F'\t' '!seen[$1]++ {print $2}' | sort
}

# --- rename map (built once, whole repo) --------------------------------
RENAME_MAP="$TMPDIR_DD/renames.tsv"
: > "$RENAME_MAP"
if [ "$IS_GIT_REPO" = "true" ]; then
  git -C "$ROOT" log --all -M --diff-filter=R --name-status --format= 2>/dev/null | \
    awk -F'\t' '$1 ~ /^R/ && !seen[$2]++ { print $2"\t"$3 }' > "$RENAME_MAP"
fi

resolve_rename_chain() {
  local candidate="$1" current="$1" next found s
  local nl=$'\n'
  local seen_list="${nl}${candidate}${nl}"
  while true; do
    next=$(awk -F'\t' -v k="$current" '$1==k{print $2; exit}' "$RENAME_MAP")
    [ -z "$next" ] && break
    case "$seen_list" in *"${nl}${next}${nl}"*) break ;; esac
    current="$next"
    seen_list="${seen_list}${next}${nl}"
  done
  printf '%s' "$current"
}

# path_history: prints "renamed\t<new_path>" or "deleted\t<sha>\t<date>" or "none"
path_history() {
  local candidate="$1"
  local mapped final hist delline sha date
  mapped=$(awk -F'\t' -v k="$candidate" '$1==k{print $2; exit}' "$RENAME_MAP")
  if [ -n "$mapped" ]; then
    final=$(resolve_rename_chain "$candidate")
    if [ -e "$ROOT/$final" ]; then
      printf 'renamed\t%s\n' "$final"
      return
    fi
    # renamed but final name also gone -> fall through to deleted check
  fi
  hist=$(git -C "$ROOT" log --all --diff-filter=AD --name-status -- "$candidate" 2>/dev/null)
  if [ -z "$hist" ]; then
    printf 'none\n'
    return
  fi
  delline=$(git -C "$ROOT" log -1 --diff-filter=D --format='%h %ad' --date=short -- "$candidate" 2>/dev/null)
  if [ -n "$delline" ]; then
    sha=${delline%% *}; date=${delline#* }
    printf 'deleted\t%s\t%s\n' "$sha" "$date"
  else
    printf 'none\n'
  fi
}

# --- per-line candidate extraction (awk: first occurrence + context) ---
extract_candidates() {
  # stdin = file content; emits tok\tline\tcontext(\001-joined, POSIX octal not hex — mawk lacks \x) for path-shaped
  # backtick tokens and markdown link targets that are not URLs and not glob patterns.
  awk '
    function consider(tok, i) {
      if (tok ~ /^https?:\/\//) return
      if (tok ~ /[*?\[]/) return
      if (!(tok ~ /\// || tok ~ /\.[A-Za-z0-9_]+$/)) return
      if (tok in seen) return
      seen[tok] = 1
      order[++cnt] = tok
      linenum[tok] = i
    }
    { lines[NR] = $0 }
    END {
      n = NR
      for (i = 1; i <= n; i++) {
        s = lines[i]
        while (match(s, /`[^`[:space:]]+`/)) {
          consider(substr(s, RSTART + 1, RLENGTH - 2), i)
          s = substr(s, RSTART + RLENGTH)
        }
        # markdown link/image targets: ](target) — fragment dropped, schemes skipped
        s = lines[i]
        while (match(s, /\]\([^)[:space:]]+/)) {
          tok = substr(s, RSTART + 2, RLENGTH - 2)
          s = substr(s, RSTART + RLENGTH)
          sub(/#.*/, "", tok)
          if (tok == "" || tok ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) continue
          consider(tok, i)
        }
      }
      for (k = 1; k <= cnt; k++) {
        tok = order[k]; ln = linenum[tok]
        lo = ln - 2; if (lo < 1) lo = 1
        hi = ln + 2; if (hi > n) hi = n
        ctx = ""
        for (j = lo; j <= hi; j++) {
          ctx = ctx lines[j]
          if (j < hi) ctx = ctx "\001"
        }
        printf "%s\t%d\t%s\n", tok, ln, ctx
      }
    }
  '
}

# --- header field detection ---------------------------------------------
is_handoff_doc() {
  local file="$1" base_lower
  base_lower=$(basename "$file" | tr '[:upper:]' '[:lower:]')
  [ "$base_lower" = "plan.md" ] && { echo true; return; }
  grep -qE '^[[:space:]]*\**[Ss]tatus\**[[:space:]]*:' "$file" && { echo true; return; }
  grep -qi 'next steps' "$file" && { echo true; return; }
  echo false
}

# prints: has_status\thas_owner\thas_last_updated\tlast_updated_value
header_fields() {
  local file="$1" head40 has_status="false" has_owner="false" has_updated="false" uline updated_val=""
  head40=$(head -n 40 "$file")
  grep -qE '^[[:space:]]*\**[Ss]tatus\**[[:space:]]*:' <<< "$head40" && has_status="true"
  grep -qE '^[[:space:]]*\**[Oo]wner\**' <<< "$head40" && has_owner="true"
  uline=$(grep -iE '^[[:space:]]*\**last[_ -]?updated\**[[:space:]]*:' <<< "$head40" | head -1)
  if [ -n "$uline" ]; then
    has_updated="true"
    updated_val=$(sed -E 's/^[[:space:]]*\**[Ll]ast[_ -]?[Uu]pdated\**[[:space:]]*:[[:space:]]*//' <<< "$uline")
  fi
  printf '%s\t%s\t%s\t%s\n' "$has_status" "$has_owner" "$has_updated" "$updated_val"
}

# --- per-file check -------------------------------------------------------
# writes finding JSON objects (one per line, no trailing comma) to $FINDINGS_OUT
check_file() {
  local file="$1" rel candidates_raw missing_list="" existing_list=""
  rel="${file#"$ROOT"/}"
  FINDINGS_OUT="$TMPDIR_DD/findings.jsonl"
  : > "$FINDINGS_OUT"

  candidates_raw=$(extract_candidates < "$file")

  local doc_dir; doc_dir=$(dirname "$file")
  local line ctx_raw ctx tok p pre
  # p = tok with a leading ./ or / removed, the form git and the filesystem
  # accept; tok itself stays verbatim as old_text so the diff matches the doc.
  while IFS=$'\t' read -r tok line ctx_raw; do
    [ -z "$tok" ] && continue
    p=${tok#./}; p=${p#/}
    if [ -e "$doc_dir/$p" ] || [ -e "$ROOT/$p" ]; then
      existing_list="${existing_list}${p}"$'\n'
    else
      missing_list="${missing_list}${tok}"$'\t'"${line}"$'\t'"${ctx_raw}"$'\n'
    fi
  done <<< "$candidates_raw"

  # missing paths -> git history classification
  if [ "$IS_GIT_REPO" = "true" ] && [ -n "$missing_list" ]; then
    while IFS=$'\t' read -r tok line ctx_raw; do
      [ -z "$tok" ] && continue
      ctx=$(tr '\001' '\n' <<< "$ctx_raw")
      local kind data1 data2 hist_line e_tok e_new e_ctx e_ev
      p=${tok#./}; p=${p#/}; pre=${tok%"$p"}
      hist_line=$(path_history "$p")
      IFS=$'\t' read -r kind data1 data2 <<< "$hist_line"
      e_tok=$(json_escape "$tok"); e_ctx=$(json_escape "$ctx")
      case "$kind" in
        renamed)
          e_new=$(json_escape "$pre$data1"); e_ev=$(json_escape "git-confirmed rename to $data1")
          printf '{"type":"missing_path","directly_verified":true,"old_text":"%s","replacement_text":"%s","line":%s,"context":"%s","evidence":"%s"}\n' \
            "$e_tok" "$e_new" "$line" "$e_ctx" "$e_ev" >> "$FINDINGS_OUT"
          ;;
        deleted)
          printf -v e_ev 'deleted in %s (%s)' "$data1" "$data2"; e_ev=$(json_escape "$e_ev")
          printf '{"type":"missing_path","directly_verified":false,"old_text":"%s","replacement_text":null,"line":%s,"context":"%s","evidence":"%s"}\n' \
            "$e_tok" "$line" "$e_ctx" "$e_ev" >> "$FINDINGS_OUT"
          ;;
        *) : ;;  # never tracked -> not a real path reference, drop silently
      esac
    done <<< "$missing_list"
  fi

  # doc's own last commit (reused for header suggestion + staleness)
  local last sha="" last_date="" last_updated_ref=""
  if [ "$IS_GIT_REPO" = "true" ]; then
    last=$(git -C "$ROOT" log -1 --format='%H %ad' --date=short -- "$file" 2>/dev/null)
    if [ -n "$last" ]; then
      sha=${last%% *}; last_date=${last#* }
      printf -v last_updated_ref '%s (commit %s)' "$last_date" "${sha:0:8}"
    fi
  fi

  # handoff header
  local handoff; handoff=$(is_handoff_doc "$file")
  if [ "$handoff" = "true" ]; then
    local hs ho hu uv fields e_val
    fields=$(header_fields "$file")
    IFS=$'\t' read -r hs ho hu uv <<< "$fields"
    local missing_count=0
    [ "$hs" = "false" ] && missing_count=$((missing_count + 1))
    [ "$ho" = "false" ] && missing_count=$((missing_count + 1))
    [ "$hu" = "false" ] && missing_count=$((missing_count + 1))

    if [ "$missing_count" -eq 3 ]; then
      local block e_block
      local lu=$last_updated_ref; [ -z "$lu" ] && lu='[fill in]'
      printf -v block 'Status: [fill in — e.g. in-progress / blocked / done]\nLast updated: %s\nOwner/context: [fill in]' "$lu"
      e_block=$(json_escape "$block")
      printf '{"type":"missing_header","directly_verified":false,"suggested_block":"%s","evidence":"%s"}\n' \
        "$e_block" "no Status/Owner/Last updated fields found in first 40 lines" >> "$FINDINGS_OUT"
    else
      if [ "$hs" = "false" ]; then
        printf '{"type":"missing_header_field","directly_verified":false,"field":"Status","suggested_value":null,"evidence":"field absent from first 40 lines"}\n' >> "$FINDINGS_OUT"
      fi
      if [ "$ho" = "false" ]; then
        printf '{"type":"missing_header_field","directly_verified":false,"field":"Owner/context","suggested_value":null,"evidence":"field absent from first 40 lines"}\n' >> "$FINDINGS_OUT"
      fi
      if [ "$hu" = "false" ]; then
        if [ -n "$last_updated_ref" ]; then
          e_val=$(json_escape "$last_updated_ref")
          printf '{"type":"missing_header_field","directly_verified":false,"field":"Last updated","suggested_value":"%s","evidence":"field absent from first 40 lines"}\n' \
            "$e_val" >> "$FINDINGS_OUT"
        else
          printf '{"type":"missing_header_field","directly_verified":false,"field":"Last updated","suggested_value":null,"evidence":"field absent from first 40 lines"}\n' >> "$FINDINGS_OUT"
        fi
      fi
    fi
  fi

  # staleness pressure: scoped to referenced paths that exist; skip if doc is dirty
  if [ "$IS_GIT_REPO" = "true" ] && [ -n "$sha" ]; then
    local dirty; dirty=$(git -C "$ROOT" status --porcelain -- "$file" 2>/dev/null)
    if [ -z "$dirty" ]; then
      local -a scope=()
      if [ -n "$existing_list" ]; then
        local uniq_existing; uniq_existing=$(sort -u <<< "$existing_list")
        while IFS= read -r p; do [ -n "$p" ] && scope+=("$p"); done <<< "$uniq_existing"
      else
        local parent_rel; parent_rel=$(dirname "$rel")
        [ "$parent_rel" != "." ] && scope=("$parent_rel")
      fi
      if [ "${#scope[@]}" -gt 0 ]; then
        local commits_since
        commits_since=$(git -C "$ROOT" rev-list --count "${sha}..HEAD" -- "${scope[@]}" 2>/dev/null)
        if [ -n "$commits_since" ] && [ "$commits_since" -gt 0 ] 2>/dev/null; then
          local recent recent_json="[" first=1 ln e_ln e_date
          recent=$(git -C "$ROOT" log --oneline "${sha}..HEAD" -5 -- "${scope[@]}" 2>/dev/null)
          while IFS= read -r ln; do
            [ -z "$ln" ] && continue
            [ "$first" -eq 0 ] && recent_json="${recent_json},"
            e_ln=$(json_escape "$ln")
            recent_json="${recent_json}\"${e_ln}\""
            first=0
          done <<< "$recent"
          recent_json="${recent_json}]"
          e_date=$(json_escape "$last_date")
          printf '{"type":"staleness_pressure","directly_verified":false,"doc_last_commit_date":"%s","commits_since_in_same_dir":%s,"sample_recent_commits":%s}\n' \
            "$e_date" "$commits_since" "$recent_json" >> "$FINDINGS_OUT"
        fi
      fi
    fi
  fi
}

# --- main ------------------------------------------------------------------
DOCS_LIST="$TMPDIR_DD/docs.txt"
find_doc_files > "$DOCS_LIST"
DOCS_SCANNED=$(wc -l < "$DOCS_LIST" | tr -d ' ')

RESULTS_JSON="$TMPDIR_DD/results.jsonl"
: > "$RESULTS_JSON"
WITH_FINDINGS=0

while IFS= read -r f; do
  [ -z "$f" ] && continue
  check_file "$f"
  count=$(wc -l < "$FINDINGS_OUT" | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    WITH_FINDINGS=$((WITH_FINDINGS + 1))
    rel="${f#"$ROOT"/}"
    findings_arr=$(paste -sd',' "$FINDINGS_OUT")
    e_rel=$(json_escape "$rel")
    printf '{"file":"%s","findings":[%s]}\n' "$e_rel" "$findings_arr" >> "$RESULTS_JSON"
  fi
done < "$DOCS_LIST"

CLEAN_COUNT=$((DOCS_SCANNED - WITH_FINDINGS))
DOCS_JSON=$(paste -sd',' "$RESULTS_JSON")

E_ROOT=$(json_escape "$ROOT")
OUT="{\"root\":\"${E_ROOT}\",\"is_git_repo\":${IS_GIT_REPO},\"documents_scanned\":${DOCS_SCANNED},\"clean_count\":${CLEAN_COUNT},\"documents_with_findings\":[${DOCS_JSON}]"
if [ "$IS_GIT_REPO" = "false" ]; then
  OUT="${OUT},\"note\":\"not a git repo: path-history and staleness checks were skipped, not passed — clean_count does not mean verified clean\""
fi
OUT="${OUT}}"
printf '%s\n' "$OUT"
