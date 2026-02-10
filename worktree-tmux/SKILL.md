---
name: worktree-tmux
description: Automate git worktree creation and tmux session management for multi-branch development workflows. Use when the user wants to spin up worktrees with dedicated tmux sessions for claude code and lazygit per branch. Triggers on requests like "create worktrees", "set up branches for review", "open worktrees in tmux", or any workflow combining git worktrees with tmux sessions.
---

# Worktree + Tmux Launcher

Automates creating git worktrees and opening paired tmux sessions (Claude Code + lazygit) per branch.

## Usage

Run from inside a git repo, within a tmux session:

```bash
wt-launch.sh feat/auth feat/dashboard fix/login
```

This creates:
- A worktree per branch at `../<repo>-<branch>/`
- A tmux session per branch with two windows: `claude` (claude code) and `lazygit` (lazygit)

## Script

The launcher script is at `scripts/wt-launch.sh`. Copy it to somewhere on the user's `$PATH` (e.g. `~/.local/bin/`).

### Installation

```bash
cp scripts/wt-launch.sh ~/.local/bin/wt-launch
chmod +x ~/.local/bin/wt-launch
```

### Requirements

- `git`, `tmux`, `lazygit`, `claude` (Claude Code) must be on `$PATH`
- Must be run from within a git repository

### Behavior

- Reuses existing worktrees and tmux sessions (idempotent)
- Branch names with `/` are sanitized to `-` for tmux session names and directory names
- New branches are created with `-b` if they don't exist locally or remotely
- Worktrees are placed alongside the main repo: `../<repo>-<branch>/`
- Each session has two windows: `claude` (window 0) and `lazygit` (window 1)
- When claude code or lazygit exits, the shell stays open in the worktree directory

### Cleanup

Remove a worktree and its tmux session manually:

```bash
git worktree remove ../<repo>-<branch>
tmux kill-session -t <branch>
```
