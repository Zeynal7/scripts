#!/usr/bin/env bash
# wt-launch.sh — Create git worktrees and open tmux sessions with claude code + lazygit
#
# Usage:
#   wt-launch.sh <branch1> [branch2] [branch3] ...
#
# Must be run from inside a git repository (main clone).
# Creates worktrees under ../<repo-name>-<branch> relative to the repo root.
# For each branch:
#   1. Creates a worktree (or reuses existing) for the branch
#   2. Creates a tmux session named after the branch with two windows:
#      - Window 1 (claude): left pane = claude code, right pane = shell (for make output)
#      - Window 2 (lazygit): lazygit
#   3. Runs make sequentially (to avoid Tuist conflicts) and moves Xcode to workspace

set -euo pipefail

# --- Validation ---

if [ $# -eq 0 ]; then
  echo "Usage: wt-launch.sh <branch1> [branch2] ..."
  echo ""
  echo "Creates git worktrees and tmux sessions with claude code + lazygit."
  exit 1
fi

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not inside a git repository."
  exit 1
fi

command -v lazygit &>/dev/null || { echo "Error: lazygit not found. Install with: brew install lazygit"; exit 1; }
command -v claude &>/dev/null || { echo "Error: claude (Claude Code) not found."; exit 1; }

# --- Setup ---

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
WORKTREE_BASE="$(dirname "$REPO_ROOT")"

# Count existing tmux sessions to determine starting number
SESSION_NUM=$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')

# Arrays to collect build info for sequential execution (bash 3.x compatible)
BUILD_DIRS=""
BUILD_WORKSPACES=""
BUILD_SESSIONS=""
BUILD_COUNT=0

for BRANCH in "$@"; do
  # Sanitize branch name for filesystem/tmux (replace / with -)
  SAFE_BRANCH="${BRANCH//\//-}"
  WORKTREE_DIR="${WORKTREE_BASE}/${REPO_NAME}-${SAFE_BRANCH}"

  # Derive a short readable name from the branch
  # e.g. "bugfix/ABBI-1381-pending-icon-position" -> "ABBI-1381 Pending Icon Position"
  SHORT_NAME=$(echo "$SAFE_BRANCH" \
    | sed -E 's/^(bugfix|task|feature|hotfix|epic)-//' \
    | sed -E 's/^([A-Z]+-[0-9]+)-/\1 /' \
    | sed 's/-/ /g' \
    | awk '{for(i=1;i<=NF;i++) if(i==1) printf "%s",$i; else printf " %s",toupper(substr($i,1,1)) substr($i,2)}')

  # Extract Jira ticket ID from branch (e.g., ABBI-1381 or DCT-46934)
  JIRA_ID=""
  if [[ "$BRANCH" =~ ([A-Z]+-[0-9]+) ]]; then
    JIRA_ID="${BASH_REMATCH[1]}"
  fi

  # --- Create or reuse worktree ---
  if [ -d "$WORKTREE_DIR" ]; then
    echo "► Worktree already exists: $WORKTREE_DIR"
  else
    # Check if branch exists locally or remotely
    if git show-ref --verify --quiet "refs/heads/${BRANCH}" 2>/dev/null; then
      echo "► Creating worktree for local branch: $BRANCH"
      git worktree add "$WORKTREE_DIR" "$BRANCH"
    elif git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}" 2>/dev/null; then
      echo "► Creating worktree for remote branch: origin/$BRANCH"
      git worktree add "$WORKTREE_DIR" "$BRANCH"
    else
      echo "► Creating worktree with new branch: $BRANCH"
      git worktree add "$WORKTREE_DIR" -b "$BRANCH"
    fi
  fi

  # --- Create tmux session ---
  SESSION_NAME="${SESSION_NUM}) ${SHORT_NAME}"

  # Check if a session for this branch already exists (by matching the short name)
  if tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qF "$SHORT_NAME"; then
    echo "  tmux session for '$SHORT_NAME' already exists, skipping."
  else
    echo "  Creating tmux session: $SESSION_NAME"

    # Create session with first window - claude code with auto-planning prompt
    CLAUDE_PROMPT="Start planning based on the Jira task ${JIRA_ID}. Read CLAUDE.md for instructions."
    tmux new-session -d -s "$SESSION_NAME" -n "claude" -c "$WORKTREE_DIR" \
      "claude --dangerously-skip-permissions '${CLAUDE_PROMPT}'; exec \$SHELL"

    # Split the claude window horizontally (right pane) - shell for build output
    tmux split-window -t "$SESSION_NAME:claude" -h -c "$WORKTREE_DIR"

    # Focus the left pane (claude) - use .left instead of .0 for reliability
    tmux select-pane -t "$SESSION_NAME:claude.left" 2>/dev/null || tmux select-pane -t "$SESSION_NAME:claude" -L 2>/dev/null || true

    # Add second window running lazygit
    tmux new-window -t "$SESSION_NAME" -n "lazygit" -c "$WORKTREE_DIR" "lazygit; exec $SHELL"

    # Select the claude window by default
    tmux select-window -t "$SESSION_NAME:claude"

    # Collect build info for sequential execution
    BUILD_COUNT=$((BUILD_COUNT + 1))
    BUILD_DIRS="${BUILD_DIRS}${WORKTREE_DIR}|"
    BUILD_WORKSPACES="${BUILD_WORKSPACES}${SESSION_NUM}|"
    BUILD_SESSIONS="${BUILD_SESSIONS}${SESSION_NAME}|"
  fi

  SESSION_NUM=$((SESSION_NUM + 1))
  echo ""
done

echo "Done. $# tmux session(s) created for $# worktree(s)."

# --- Run builds sequentially to avoid Tuist conflicts ---
if [ "$BUILD_COUNT" -gt 0 ]; then
  echo ""
  echo "Starting sequential builds in background..."

  # Create build script (bash 3.x compatible)
  BUILD_SCRIPT=$(mktemp)
  cat > "$BUILD_SCRIPT" << 'BUILDEOF'
#!/bin/bash
# Parse pipe-delimited arguments
DIRS_STR="$1"
WORKSPACES_STR="$2"
SESSIONS_STR="$3"

# Convert to arrays using tr and read (bash 3.x compatible)
OLD_IFS="$IFS"
IFS='|'
set -f
DIRS=($DIRS_STR)
WORKSPACES=($WORKSPACES_STR)
SESSIONS=($SESSIONS_STR)
set +f
IFS="$OLD_IFS"

# Get count (subtract 1 for trailing delimiter)
count=$((${#DIRS[@]} - 1))

for i in $(seq 0 $((count - 1))); do
  dir="${DIRS[$i]}"
  workspace="${WORKSPACES[$i]}"
  session="${SESSIONS[$i]}"

  [ -z "$dir" ] && continue

  name=$(basename "$dir")

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Building: $name → Workspace $workspace"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Get current Xcode window IDs before build
  XCODE_BEFORE=$(aerospace list-windows --all 2>/dev/null | grep -i 'Xcode' | awk '{print $1}' | sort)

  # Run make in the session's right pane
  tmux send-keys -t "${session}:claude.right" "cd '$dir' && make" Enter

  # Wait for a new Xcode window to appear
  echo "Waiting for Xcode to open..."
  XCODE_WIN=""
  for attempt in $(seq 1 120); do
    sleep 2
    XCODE_AFTER=$(aerospace list-windows --all 2>/dev/null | grep -i 'Xcode' | awk '{print $1}' | sort)

    # Find new window ID (in AFTER but not in BEFORE)
    for win in $XCODE_AFTER; do
      if ! echo "$XCODE_BEFORE" | grep -q "^${win}$"; then
        XCODE_WIN="$win"
        break
      fi
    done

    if [ -n "$XCODE_WIN" ]; then
      sleep 2  # Give Xcode a moment to fully load
      aerospace move-node-to-workspace --window-id "$XCODE_WIN" "$workspace" 2>/dev/null || true
      echo "✓ Moved Xcode ($XCODE_WIN) to workspace $workspace"

      osascript -e 'tell application "Xcode" to set the active scheme of the active workspace document to (scheme "IBAMobileBank-Test" of the active workspace document)' 2>/dev/null || true
      echo "✓ Switched to IBAMobileBank-Test scheme"
      break
    fi
  done

  if [ -z "$XCODE_WIN" ]; then
    echo "⚠ Timeout waiting for Xcode: $name"
  fi

  echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "All builds complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
BUILDEOF
  chmod +x "$BUILD_SCRIPT"

  # Run builds in a new tmux session
  tmux new-session -d -s "Build Runner" -n "builds" \
    "bash '$BUILD_SCRIPT' '$BUILD_DIRS' '$BUILD_WORKSPACES' '$BUILD_SESSIONS'; exec \$SHELL"

  echo "Build Runner session started. Attach with: tmux attach -t 'Build Runner'"
fi

echo ""
echo "Switch between sessions with: <prefix> + s"
echo "Attach to a session with: tmux attach -t <session-name>"
