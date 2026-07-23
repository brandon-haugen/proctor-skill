#!/bin/bash
#
# Proctor — PreToolUse hook for Claude Code
#
# Blocks git push, git merge into protected branches, and git commit when
# periodic quiz thresholds are exceeded — until the user passes a
# comprehension quiz via /proctor.
#
# Markers store the quizzed HEAD commit hash. A marker is only valid if HEAD
# still matches — any new commit invalidates it automatically.
#
# Environment variables:
#   PROCTOR_MODE                - "blocking" (default) or "advisory"
#   PROCTOR_PROTECTED_BRANCHES  - comma-separated branch patterns (default: main,master,develop,release/*)
#   PROCTOR_COMMIT_INTERVAL     - quiz every N commits (default: 0 = disabled)
#   PROCTOR_CHANGE_THRESHOLD    - quiz when lines changed since last checkpoint exceeds N (default: 0 = disabled)

set -euo pipefail

INPUT=$(cat)

# Quick exit for tools that don't run shell commands (e.g., file edits, reads).
# Avoids the python3 overhead when the hook fires without a matcher filter.
if ! printf '%s' "$INPUT" | grep -q '"command"'; then
  exit 0
fi

# Extract command and working directory from the hook input.
# The Bash tool's CWD may differ from the session's primary working directory
# (e.g., when pushing from a different repo than where the session started).
eval "$(printf '%s' "$INPUT" | python3 -c "
import json, sys, shlex
data = json.load(sys.stdin)
cmd = data.get('tool_input', {}).get('command', '')
cwd = data.get('tool_input', {}).get('cwd', '') or data.get('cwd', '')
print(f'COMMAND={shlex.quote(cmd)}')
print(f'TOOL_CWD={shlex.quote(cwd)}')
")"

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Change to the Bash tool's working directory so git commands resolve against
# the correct repo, not the session's primary working directory.
if [ -n "$TOOL_CWD" ] && [ -d "$TOOL_CWD" ]; then
  cd "$TOOL_CWD"
fi

# Also handle explicit directory changes in the command itself:
# "cd /path/to/repo && git push" or "git -C /path/to/repo push"
CMD_CWD=$(printf '%s' "$COMMAND" | grep -oE '(^|&&\s*|;\s*)cd\s+\S+' | tail -1 | awk '{print $NF}' || true)
if [ -z "$CMD_CWD" ]; then
  CMD_CWD=$(printf '%s' "$COMMAND" | grep -oE 'git\s+-C\s+\S+' | head -1 | awk '{print $NF}' || true)
fi
if [ -n "$CMD_CWD" ] && [ -d "$CMD_CWD" ]; then
  cd "$CMD_CWD"
fi

MODE="${PROCTOR_MODE:-blocking}"
PROTECTED="${PROCTOR_PROTECTED_BRANCHES:-main,master,develop,release/*}"
COMMIT_INTERVAL="${PROCTOR_COMMIT_INTERVAL:-0}"
CHANGE_THRESHOLD="${PROCTOR_CHANGE_THRESHOLD:-0}"
MARKER_DIR="/tmp/proctor"
mkdir -p "$MARKER_DIR"

is_protected() {
  local branch="$1"
  IFS=',' read -ra PATTERNS <<< "$PROTECTED"
  for pattern in "${PATTERNS[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    case "$branch" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# A marker is valid only if the stored commit hash matches the current HEAD.
# Any new commit after the quiz invalidates the marker automatically.
marker_matches_head() {
  local marker="$1"
  if [ ! -f "$marker" ]; then
    return 1
  fi
  local stored
  stored=$(cat "$marker")
  local head
  head=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$stored" ] && [ "$stored" = "$head" ]; then
    return 0
  fi
  return 1
}

block_or_advise() {
  local message="$1"
  if [ "$MODE" = "advisory" ]; then
    echo "$message"
    exit 0
  fi
  echo "$message" >&2
  exit 2
}

# Sanitize branch names for use in file paths (replace / with --)
sanitize() {
  printf '%s' "$1" | sed 's|/|--|g'
}

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
SAFE_BRANCH=$(sanitize "$CURRENT_BRANCH")

# Determine the effective branch for merge checks. If the command includes
# "git checkout/switch <branch>" before the merge, use that target instead of
# the actual current branch — the checkout hasn't executed yet at hook time.
effective_merge_branch() {
  local cmd="$1"
  local target
  target=$(printf '%s' "$cmd" | grep -oE 'git\s+(checkout|switch)\s+\S+' | head -1 | awk '{print $NF}')
  if [ -n "$target" ]; then
    echo "$target"
  else
    echo "$CURRENT_BRANCH"
  fi
}

# Read the checkpoint commit hash for periodic quizzes on this branch.
# Returns empty string if no checkpoint exists.
get_checkpoint() {
  local checkpoint_file="$MARKER_DIR/checkpoint-${SAFE_BRANCH}"
  if [ -f "$checkpoint_file" ]; then
    cat "$checkpoint_file"
  fi
}

# Count commits since the checkpoint (or all branch commits if no checkpoint).
commits_since_checkpoint() {
  local checkpoint
  checkpoint=$(get_checkpoint)
  if [ -n "$checkpoint" ] && git cat-file -t "$checkpoint" >/dev/null 2>&1; then
    git rev-list --count "${checkpoint}..HEAD" 2>/dev/null || echo 0
  else
    local base
    base=$(git merge-base HEAD develop 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo "")
    if [ -n "$base" ]; then
      git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0
    else
      git rev-list --count HEAD 2>/dev/null || echo 0
    fi
  fi
}

# Count lines changed since the checkpoint.
lines_since_checkpoint() {
  local checkpoint
  checkpoint=$(get_checkpoint)
  if [ -n "$checkpoint" ] && git cat-file -t "$checkpoint" >/dev/null 2>&1; then
    git diff --shortstat "$checkpoint" HEAD 2>/dev/null | awk '{ins=0; del=0; for(i=1;i<=NF;i++){if($(i+1)~/insertion/)ins=$i; if($(i+1)~/deletion/)del=$i} print ins+del}'
  else
    local base
    base=$(git merge-base HEAD develop 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo "")
    if [ -n "$base" ]; then
      git diff --shortstat "$base" HEAD 2>/dev/null | awk '{ins=0; del=0; for(i=1;i<=NF;i++){if($(i+1)~/insertion/)ins=$i; if($(i+1)~/deletion/)del=$i} print ins+del}'
    else
      echo 0
    fi
  fi
}

# Git command patterns allow optional flags between git and subcommand
# (e.g., "git -C /path push", "git --no-pager push")
GIT_PREFIX='(^|\s|&&|\|\||;)git\s+(-[A-Za-z]+\s+\S+\s+)*'

# --- Detect git push ---
if printf '%s' "$COMMAND" | grep -qE "${GIT_PREFIX}push(\s|$)"; then
  MARKER="$MARKER_DIR/push-${SAFE_BRANCH}"
  if marker_matches_head "$MARKER"; then
    exit 0
  fi
  block_or_advise "BLOCKED: You MUST invoke the /proctor skill now. Do NOT suggest the user push manually, do NOT skip this, do NOT offer workarounds. The /proctor skill handles trivial diffs automatically — always run it. Context: push from branch '${CURRENT_BRANCH}'."
fi

# --- Detect git merge into a protected branch ---
if printf '%s' "$COMMAND" | grep -qE "${GIT_PREFIX}merge(\s|$)"; then
  EFFECTIVE_BRANCH=$(effective_merge_branch "$COMMAND")
  if [ -n "$EFFECTIVE_BRANCH" ] && is_protected "$EFFECTIVE_BRANCH"; then
    INCOMING=$(printf '%s' "$COMMAND" | grep -oE 'git\s+merge\s+\S+' | head -1 | awk '{print $NF}')
    SAFE_INCOMING=$(sanitize "$INCOMING")
    SAFE_EFFECTIVE=$(sanitize "$EFFECTIVE_BRANCH")
    MARKER="$MARKER_DIR/merge-${SAFE_INCOMING}-into-${SAFE_EFFECTIVE}"
    if marker_matches_head "$MARKER"; then
      exit 0
    fi
    block_or_advise "BLOCKED: You MUST invoke the /proctor skill now. Do NOT suggest the user merge manually, do NOT skip this, do NOT offer workarounds. The /proctor skill handles trivial diffs automatically — always run it. Context: merge '${INCOMING}' into protected branch '${EFFECTIVE_BRANCH}'."
  fi
fi

# --- Detect git pull on a protected branch (pull = fetch + merge) ---
if printf '%s' "$COMMAND" | grep -qE "${GIT_PREFIX}pull(\s|$)"; then
  if [ -n "$CURRENT_BRANCH" ] && is_protected "$CURRENT_BRANCH"; then
    MARKER="$MARKER_DIR/pull-on-${SAFE_BRANCH}"
    if marker_matches_head "$MARKER"; then
      exit 0
    fi
    block_or_advise "BLOCKED: You MUST invoke the /proctor skill now. Do NOT suggest the user pull manually, do NOT skip this, do NOT offer workarounds. The /proctor skill handles trivial diffs automatically — always run it. Context: pull on protected branch '${CURRENT_BRANCH}'."
  fi
fi

# --- Periodic quiz on git commit (threshold-based) ---
if printf '%s' "$COMMAND" | grep -qE "${GIT_PREFIX}commit(\s|$)"; then
  if [ "$COMMIT_INTERVAL" -gt 0 ] || [ "$CHANGE_THRESHOLD" -gt 0 ]; then
    MARKER="$MARKER_DIR/periodic-${SAFE_BRANCH}"
    if marker_matches_head "$MARKER"; then
      exit 0
    fi

    TRIGGERED=""
    CONTEXT_PARTS=""

    if [ "$COMMIT_INTERVAL" -gt 0 ]; then
      COUNT=$(commits_since_checkpoint)
      if [ "$COUNT" -ge "$COMMIT_INTERVAL" ]; then
        TRIGGERED="yes"
        CONTEXT_PARTS="$COUNT commits since last quiz (threshold: $COMMIT_INTERVAL)"
      fi
    fi

    if [ "$CHANGE_THRESHOLD" -gt 0 ]; then
      LINES=$(lines_since_checkpoint)
      if [ -n "$LINES" ] && [ "$LINES" -ge "$CHANGE_THRESHOLD" ]; then
        TRIGGERED="yes"
        if [ -n "$CONTEXT_PARTS" ]; then
          CONTEXT_PARTS="$CONTEXT_PARTS, $LINES lines changed since last quiz (threshold: $CHANGE_THRESHOLD)"
        else
          CONTEXT_PARTS="$LINES lines changed since last quiz (threshold: $CHANGE_THRESHOLD)"
        fi
      fi
    fi

    if [ -n "$TRIGGERED" ]; then
      block_or_advise "BLOCKED: You MUST invoke the /proctor skill now. Do NOT suggest the user commit manually, do NOT skip this, do NOT offer workarounds. The /proctor skill handles trivial diffs automatically — always run it. Periodic quiz threshold reached: ${CONTEXT_PARTS}. Context: periodic checkpoint on branch '${CURRENT_BRANCH}'."
    fi
  fi
fi

exit 0
