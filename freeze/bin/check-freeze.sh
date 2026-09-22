#!/usr/bin/env bash
# check-freeze.sh — PreToolUse hook for /freeze skill
# Reads JSON from stdin, checks if file_path is within the freeze boundary.
# Returns a PreToolUse hookSpecificOutput with permissionDecision "deny" to block,
# or {} to allow. The decision MUST be nested under hookSpecificOutput — Claude
# Code ignores a top-level permissionDecision, which silently no-ops the block.
#
# Polarity: freeze is a DENY-tier hook, so an unreadable payload DENIES
# (fail closed). A payload that parses but has no file_path is a non-file
# tool — allow. This is the opposite edge-handling from careful's ask-tier
# and intentionally so: /guard runs both, and a boundary that fails open is
# not a boundary.
set -euo pipefail

# Read stdin
INPUT=$(cat)

# Shared JSON helpers (extractor + encoder) — one copy for careful AND freeze.
# freeze previously carried its own grep-first extractor which truncated at
# escaped quotes and failed OPEN; the shared file kills that drift class.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=careful/bin/hook-extract.sh
# Freeze is deny-tier: if its own helpers are missing/broken (partial install,
# mid-upgrade state), the boundary must fail CLOSED — inline JSON, since the
# encoder we would normally use lives in the file that just failed to load.
# NOTE: bash treats `.` on a MISSING file as fatal in non-interactive shells
# (an if-guard cannot catch it) — the existence check must come first.
_HOOK_HELPER="$_HOOK_DIR/../../careful/bin/hook-extract.sh"
if [ ! -f "$_HOOK_HELPER" ] || ! . "$_HOOK_HELPER" 2>/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[freeze] Hook helpers unavailable (broken install?) - blocked, fail closed. Reinstall gstack or run /unfreeze."}}\n'
  exit 0
fi

# Locate the freeze directory state file. The shared helper resolves the state
# directory in one place; when it cannot (HOME unset, no CLAUDE_PLUGIN_DATA) the
# boundary file is unreadable, and freeze is the DENY tier. An unreadable
# boundary denies — the alternative is the "no freeze file, allow everything"
# branch below silently absorbing a machine that simply has no HOME.
set +e
STATE_DIR=$(gstack_hook_state_dir "${CLAUDE_PLUGIN_DATA:-}")
STATE_RC=$?
set -e
if [ "$STATE_RC" -ne 0 ]; then
  gstack_hook_decision deny "[freeze] Neither CLAUDE_PLUGIN_DATA nor HOME names a directory, so the freeze boundary state could not be located. Blocked (fail closed). Give this process a HOME, or set CLAUDE_PLUGIN_DATA to the gstack state directory that /freeze wrote to."
  exit 0
fi
FREEZE_FILE="$STATE_DIR/freeze-dir.txt"

# If no freeze file exists, allow everything (not yet configured)
if [ ! -f "$FREEZE_FILE" ]; then
  echo '{}'
  exit 0
fi

# First line, trimmed of LEADING/TRAILING whitespace only. The previous
# `tr -d '[:space:]'` deleted INTERNAL spaces too, so a boundary like
# "~/My Project/src" could never match anything — every edit denied (or the
# mangled path accidentally allowed the wrong tree).
# Existence is not readability, and `set -o pipefail` makes the pipeline below
# non-zero when `head` cannot open the file — which under `set -e` killed the
# script at rc=1 with no verdict on stdout, the same silent allow this file
# exists to prevent, reachable with HOME set and a root-owned state file.
if [ ! -r "$FREEZE_FILE" ]; then
  gstack_hook_decision deny "[freeze] The freeze boundary file exists but cannot be read ($FREEZE_FILE). Blocked (fail closed). Fix its permissions, or run /unfreeze."
  exit 0
fi
set +e
FREEZE_DIR=$(head -n 1 "$FREEZE_FILE" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
READ_RC=$?
set -e
if [ "$READ_RC" -ne 0 ]; then
  gstack_hook_decision deny "[freeze] The freeze boundary file could not be read ($FREEZE_FILE). Blocked (fail closed). Reinstall gstack or run /unfreeze."
  exit 0
fi
# A literal leading ~ in the state file never matches absolute tool paths
# (tilde is not expanded from variables) — expand it here.
# HOME is checked before it is dereferenced: an unset HOME here would abort the
# script under `set -u` with no verdict on stdout, which Claude Code reads as
# non-blocking. Reachable when CLAUDE_PLUGIN_DATA supplies the state directory
# but HOME is still absent.
case "$FREEZE_DIR" in
  "~"|"~/"*)
    if [ -z "${HOME:-}" ]; then
      gstack_hook_decision deny "[freeze] The freeze boundary is stored as a ~ path and HOME is unset, so it cannot be resolved. Blocked (fail closed). Re-run /freeze with an absolute path, or run /unfreeze."
      exit 0
    fi
    case "$FREEZE_DIR" in
      "~/"*) FREEZE_DIR="$HOME/${FREEZE_DIR#\~/}" ;;
      "~") FREEZE_DIR="$HOME" ;;
    esac
    ;;
esac

# If freeze dir is empty, allow
if [ -z "$FREEZE_DIR" ]; then
  echo '{}'
  exit 0
fi

# Extract file_path from tool_input with the shared real-JSON parser.
set +e
FILE_PATH=$(gstack_hook_extract_field "$INPUT" file_path)
EXTRACT_RC=$?
set -e

# Unparseable payload (or no parser available): DENY. A boundary hook that
# allows what it cannot read is not a boundary.
if [ "$EXTRACT_RC" -ne 0 ] && [ -n "$INPUT" ]; then
  gstack_hook_decision deny "[freeze] Could not parse the tool payload to check the freeze boundary. Blocked (fail closed). Freeze boundary: $FREEZE_DIR"
  exit 0
fi

# Parsed fine but no file_path field: a non-file tool payload — allow.
if [ -z "$FILE_PATH" ]; then
  echo '{}'
  exit 0
fi

# Resolve file_path to absolute if it isn't already
case "$FILE_PATH" in
  /*) ;; # already absolute
  *)
    FILE_PATH="$(pwd)/$FILE_PATH"
    ;;
esac

# Normalize: remove double slashes and trailing slash
FILE_PATH=$(printf '%s' "$FILE_PATH" | sed 's|/\+|/|g;s|/$||')

# Resolve symlinks and .. sequences (POSIX-portable, works on macOS).
# The FULL path is resolved, including the FINAL component: the previous
# version resolved only the parent directory, so an in-boundary symlink
# pointing at an out-of-boundary target sailed through the check while the
# actual write landed outside the boundary. A final component that is a
# symlink is followed (bounded, cycle-safe) so the TARGET gets checked; a
# final component that does not exist yet (new file) has nothing to follow
# and parent resolution is the correct behavior.
_resolve_path() {
  local _p="$1" _dir _base _tgt _i=0
  while [ -L "$_p" ] && [ "$_i" -lt 40 ]; do
    _tgt=$(readlink "$_p" 2>/dev/null) || break
    case "$_tgt" in
      /*) _p="$_tgt" ;;
      *) _p="$(dirname "$_p")/$_tgt" ;;
    esac
    _i=$((_i + 1))
  done
  _dir="$(dirname "$_p")"
  _base="$(basename "$_p")"
  _dir="$(cd "$_dir" 2>/dev/null && pwd -P || printf '%s' "$_dir")"
  printf '%s/%s' "$_dir" "$_base"
}
FILE_PATH=$(_resolve_path "$FILE_PATH")
FREEZE_DIR=$(_resolve_path "$FREEZE_DIR")

# Check: does the file path start with the freeze directory?
case "$FILE_PATH" in
  "${FREEZE_DIR}/"*|"${FREEZE_DIR}")
    # Inside freeze boundary — allow
    echo '{}'
    ;;
  *)
    # Outside freeze boundary — deny
    # Log hook fire event (shared helper respects GSTACK_HOME)
    # `|| true`: the logger runs BEFORE the deny is printed, so a non-zero status
    # from it would abort the script under `set -e` and lose the verdict.
    gstack_hook_log_fire freeze boundary_deny || true

    # The reason is JSON-encoded by the shared helper. Never interpolate paths
    # into hand-built JSON: a path containing a quote or newline produced
    # malformed JSON here, and the deny silently no-oped.
    gstack_hook_decision deny "[freeze] Blocked: $FILE_PATH is outside the freeze boundary ($FREEZE_DIR). Only edits within the frozen directory are allowed."
    ;;
esac
