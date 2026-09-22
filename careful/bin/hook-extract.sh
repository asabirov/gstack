#!/usr/bin/env bash
# hook-extract.sh — SHARED JSON helpers for gstack PreToolUse hooks.
# Sourced (never executed) by careful/bin/check-careful.sh and
# freeze/bin/check-freeze.sh via a path relative to each hook script.
#
# ONE copy on purpose. These two hooks previously carried separate extractor
# copies; the escaped-quote truncation bug got fixed in careful's copy while
# freeze silently kept the broken one. Any future parsing fix lands here and
# reaches both hooks by construction.

# gstack_hook_extract_field PAYLOAD FIELD
#   Prints tool_input.FIELD when PAYLOAD is valid JSON and the field is a
#   string ("" when absent or non-string). Returns 1 when no parser is
#   available or the payload is not parseable JSON — the CALLER decides the
#   polarity for that case (careful asks, freeze denies).
#
#   python3 is tried first because it ships with macOS and most Linux distros
#   and is reliably on PATH in a hook environment; node is the fallback.
gstack_hook_extract_field() {
  _ghef_payload="$1"
  _ghef_field="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$_ghef_payload" | python3 -c 'import sys,json
field = sys.argv[1]
d = json.loads(sys.stdin.read())
c = d.get("tool_input", {}).get(field, "")
sys.stdout.write(c if isinstance(c, str) else "")' "$_ghef_field" 2>/dev/null && return 0
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$_ghef_payload" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const c=(j&&j.tool_input&&j.tool_input[process.argv[1]])||"";process.stdout.write(typeof c==="string"?c:"")}catch(e){process.exit(3)}})' "$_ghef_field" 2>/dev/null && return 0
  fi
  return 1
}

# gstack_hook_json_string TEXT
#   Prints TEXT as a JSON string literal (surrounding quotes included),
#   encoding quotes, backslashes, control characters and newlines. Never build
#   hook JSON with printf/sed interpolation: a path containing a quote or a
#   newline produces malformed JSON, and Claude Code silently ignores the
#   whole decision — a deny that no-ops exactly when it matters.
gstack_hook_json_string() {
  _ghjs_text="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$_ghjs_text" | python3 -c 'import sys,json; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null && return 0
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$_ghjs_text" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))' 2>/dev/null && return 0
  fi
  # Last-resort fallback (no parser on PATH): strip to a safe charset so the
  # envelope stays valid JSON even if the message loses characters.
  printf '"%s"' "$(printf '%s' "$_ghjs_text" | tr -cd 'a-zA-Z0-9 ._/:@=+-' )"
}

# gstack_hook_decision DECISION REASON
#   Emits the full PreToolUse hookSpecificOutput envelope with REASON safely
#   JSON-encoded. DECISION is "ask" or "deny". The decision MUST be nested
#   under hookSpecificOutput — Claude Code ignores a top-level
#   permissionDecision, which silently no-ops the block.
gstack_hook_decision() {
  _ghd_decision="$1"
  _ghd_reason="$2"
  _ghd_encoded=$(gstack_hook_json_string "$_ghd_reason")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$_ghd_decision" "$_ghd_encoded"
}

# gstack_hook_state_dir [OVERRIDE]
#   Prints the gstack state directory, or refuses when there isn't one.
#   OVERRIDE is the caller's own env
#   override, already expanded and possibly empty: careful reads GSTACK_HOME and
#   freeze reads CLAUDE_PLUGIN_DATA, and that difference stays with the callers.
#
#     rc 0 — the path is authoritative: OVERRIDE, or "$HOME/.gstack".
#     rc 1 — HOME is unset or empty and no OVERRIDE was given. Nothing is
#            printed, because there is no directory honest enough to name.
#
#   rc 1 means REFUSE, not "use something else". Two fallbacks were weighed and
#   rejected. A computed scratch path (${TMPDIR:-/tmp}/.gstack) is a predictable
#   name in a world-writable directory: another local user can pre-plant it as a
#   symlink and collect the analytics appends. The passwd home that bash's `~`
#   falls back to is the operator's REAL directory, which is wrong in a different
#   way — a process whose environment deliberately has no HOME (a container, a
#   sandbox, this repo's own suite) would start reading and writing the invoking
#   user's state behind its back, and the suite's "never touch the operator's
#   ~/.gstack" invariant would go with it.
#
#   So the honest answer is to say there is no state directory and let each
#   caller's tier decide: careful asks, freeze denies, the logger drops the
#   record. A hook that cannot log must still be able to deny: logging is what
#   gets dropped, never the verdict. The cost is that on a HOME-less machine
#   careful asks on every command and freeze denies every write — loud, which is
#   the point, but see the PR discussion if that trade needs revisiting.
#
#   Resolving HOME lives HERE and nowhere else. These hooks run under
#   `set -euo pipefail`, where a bare $HOME deref on a machine with HOME unset
#   aborts the script before any verdict reaches stdout — and Claude Code treats
#   a PreToolUse hook that exits non-zero and non-2 as non-blocking, so every
#   deny and every ask became a silent allow. Four separate "$HOME/.gstack"
#   expressions is how that happened; one function is why it cannot come back.
gstack_hook_state_dir() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    printf '%s/.gstack' "$HOME"
    return 0
  fi
  return 1
}

# gstack_hook_log_fire SKILL PATTERN
#   Append a hook_fire analytics record (pattern name only, never command
#   content). Respects GSTACK_HOME so tests never pollute the operator's real
#   analytics file. Best-effort: failures never affect the hook decision.
gstack_hook_log_fire() {
  # No state directory (HOME unset and no GSTACK_HOME) means no analytics. The
  # `|| return 0` is load-bearing: the callers run under `set -e`, and this
  # logger fires BEFORE the decision is printed on both the deny path and every
  # ask path, so any non-zero status leaving this function silences the verdict.
  _ghlf_base=$(gstack_hook_state_dir "${GSTACK_HOME:-}") || return 0
  _ghlf_dir="$_ghlf_base/analytics"
  mkdir -p "$_ghlf_dir" 2>/dev/null || true
  # Fields are JSON-encoded (a repo basename can carry quotes/backslashes) —
  # same rule this file states for decisions: never raw-interpolate into JSON.
  _ghlf_repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")
  printf '{"event":"hook_fire","skill":%s,"pattern":%s,"ts":"%s","repo":%s}\n' \
    "$(gstack_hook_json_string "$1")" \
    "$(gstack_hook_json_string "$2")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(gstack_hook_json_string "$_ghlf_repo")" >> "$_ghlf_dir/skill-usage.jsonl" 2>/dev/null || true
  # Explicit, not incidental: this function runs BEFORE the verdict is printed,
  # so under `set -e` any non-zero status it returns silences the verdict. Every
  # statement above already ends in `|| true`, and this makes that structural
  # rather than a property of the last line anyone happens to add.
  return 0
}
