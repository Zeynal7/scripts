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
#      - Window 0: claude code
#      - Window 1: lazygit

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
    # Create session with first window running claude code
    tmux new-session -d -s "$SESSION_NAME" -n "claude" -c "$WORKTREE_DIR" "claude --dangerously-skip-permissions; exec $SHELL"
    # Add second window running lazygit
    tmux new-window -t "$SESSION_NAME" -n "lazygit" -c "$WORKTREE_DIR" "lazygit; exec $SHELL"
    # Select the claude window by default
    tmux select-window -t "$SESSION_NAME:claude"
  fi

  SESSION_NUM=$((SESSION_NUM + 1))
  echo ""
done

echo "Done. $# tmux session(s) created for $# worktree(s)."
echo "Switch between sessions with: <prefix> + s"
echo "Attach to a session with: tmux attach -t <session-name>"
