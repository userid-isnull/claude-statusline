#!/bin/bash
# Worktree rendering: line 2 shows the dir the session was registered to,
# line 3 shows the active linked worktree as a path relative to it.
#
# Fixtures are real repos with real `git worktree add` layouts, one per
# structure observed across the fleet (central pool, flat pool, sibling
# suffix dirs, pools nested inside the main tree, out-of-tree scratchpads).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"

WT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sl-wt-XXXXXX")
HOME_FIXTURE="$WT_ROOT/home"
OUTSIDE="$WT_ROOT/outside"
mkdir -p "$HOME_FIXTURE/repos" "$OUTSIDE"

cleanup_wt() { rm -rf "$WT_ROOT"; }
trap 'cleanup_wt; _test_cleanup' EXIT

# A repo with one commit, quiet and identity-independent.
make_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$path"
}

add_wt() { # repo, worktree path, branch
  git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1
}

# Payload for a session registered at $1 with cwd $2.
wt_payload() {
  build_payload \
    '.context_window.used_percentage=5' \
    '.context_window.context_window_size=1000000' \
    '.session_id="wt-session"' \
    ".workspace.project_dir=\"$1\"" \
    ".workspace.current_dir=\"$2\""
}

# Run with HOME pinned at the fixture so ~-abbreviation is deterministic.
invoke_home() {
  printf '%s' "$1" | env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
    HOME="$HOME_FIXTURE" \
    STATUSLINE_NOW_EPOCH="$NOW" STATUSLINE_SSH_PROBE_PROC=0 \
    bash "$STATUSLINE"
}
wt_row() { line_n 2 "$1" | strip_ansi; }
ws_row() { line_n 1 "$1" | strip_ansi; }

# --- S1: central pool, repo-namespaced (fleet convention) ----------------
REPO="$HOME_FIXTURE/repos/proj"
make_repo "$REPO" >/dev/null
add_wt "$REPO" "$HOME_FIXTURE/repos/.worktrees/proj/feat/deep/name" feat/deep/name

start_test "S1 worktree row is relative to the repo's main checkout"
out=$(invoke_home "$(wt_payload "$REPO" "$HOME_FIXTURE/repos/.worktrees/proj/feat/deep/name")")
assert_match '\.\./\.worktrees/proj/feat/deep/name' "$(wt_row "$out")"

start_test "S1 workspace row shows registered dir ~-abbreviated, no branch icon"
ws=$(ws_row "$out")
assert_match '~/repos/proj' "$ws"
assert_no_match 'feat/deep/name' "$ws"

start_test "S1 emits exactly three rows"
assert_eq 3 "$(printf '%s\n' "$out" | grep -c .)" "row count"

# --- S2: central pool, flat (no repo subdir) -----------------------------
add_wt "$REPO" "$HOME_FIXTURE/repos/.worktrees/flatwt" flatwt

start_test "S2 flat pool renders one level up"
out=$(invoke_home "$(wt_payload "$REPO" "$HOME_FIXTURE/repos/.worktrees/flatwt")")
assert_eq '../.worktrees/flatwt' "$(printf '%s' "$(wt_row "$out")" | sed 's/^ *[^ ]* //')" "flat pool path"

# --- S3: sibling <repo>-<suffix> directory -------------------------------
add_wt "$REPO" "$HOME_FIXTURE/repos/proj-covers" covers

start_test "S3 sibling suffix dir renders as ../proj-covers"
out=$(invoke_home "$(wt_payload "$REPO" "$HOME_FIXTURE/repos/proj-covers")")
assert_match '\.\./proj-covers$' "$(wt_row "$out")"

start_test "S3 sibling prefix does not swallow the repo name (component boundary)"
assert_no_match '\.\./-covers' "$(wt_row "$out")"

# --- S4: pool nested inside the main tree --------------------------------
add_wt "$REPO" "$REPO/.claude/worktrees/agent-x" agent-x

start_test "S4 in-tree worktree renders as a ./ descendant"
out=$(invoke_home "$(wt_payload "$REPO" "$REPO/.claude/worktrees/agent-x")")
assert_match '\./\.claude/worktrees/agent-x' "$(wt_row "$out")"

# --- S5: outside $HOME entirely (scratchpad worktrees) -------------------
add_wt "$REPO" "$OUTSIDE/scratch/wr1" wr1

start_test "S5 out-of-home worktree keeps an explicit ../ chain"
out=$(invoke_home "$(wt_payload "$REPO" "$OUTSIDE/scratch/wr1")")
row=$(wt_row "$out")
assert_match '\.\./\.\./outside/scratch/wr1' "$row"
assert_no_match '~' "$row"

# --- ~ shortening: worktree under $HOME, far from the session dir --------
DEEP="$HOME_FIXTURE/repos/proj/a/b/c/d/e"
mkdir -p "$DEEP"
add_wt "$REPO" "$HOME_FIXTURE/wt" plainwt

start_test "worktree under HOME uses ~/... when shorter than the ../ chain"
out=$(invoke_home "$(wt_payload "$DEEP" "$HOME_FIXTURE/wt")")
assert_match '~/wt$' "$(wt_row "$out")"

start_test "relative form wins when it is the shorter rendering"
out=$(invoke_home "$(wt_payload "$REPO" "$HOME_FIXTURE/repos/proj-covers")")
assert_no_match '~/repos/proj-covers' "$(wt_row "$out")"

SIBLING_HOME="${HOME_FIXTURE}-other"
add_wt "$REPO" "$SIBLING_HOME/wt" sibling-home

start_test "HOME textual prefix without path boundary is not ~-abbreviated"
out=$(invoke_home "$(wt_payload "$REPO" "$SIBLING_HOME/wt")")
assert_match 'home-other/wt$' "$(wt_row "$out")"
assert_no_match '~' "$(wt_row "$out")"

# --- cwd deeper inside the worktree --------------------------------------
mkdir -p "$HOME_FIXTURE/repos/proj-covers/sub"

start_test "cwd inside the worktree still resolves the worktree root"
out=$(invoke_home "$(wt_payload "$REPO" "$HOME_FIXTURE/repos/proj-covers/sub")")
assert_match '\.\./proj-covers$' "$(wt_row "$out")"

start_test "cwd-differs segment is suppressed in worktree sessions"
assert_no_match '> \./' "$(ws_row "$out")"

# --- detached HEAD in a worktree -----------------------------------------
git -C "$HOME_FIXTURE/repos/proj-covers" -c advice.detachedHead=false checkout -q --detach HEAD

start_test "detached HEAD in a worktree still reports the worktree"
out=$(invoke_home "$(wt_payload "$REPO" "$HOME_FIXTURE/repos/proj-covers")")
assert_match '\.\./proj-covers' "$(wt_row "$out")"

# --- main working tree: unchanged two-row output -------------------------
start_test "main tree emits two rows with branch, no worktree row"
out=$(invoke_home "$(wt_payload "$REPO" "$REPO")")
assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "row count"
ws=$(ws_row "$out")
assert_match 'proj .* main' "$ws"
assert_no_match '~/repos/proj' "$ws"

# --- non-git directory ---------------------------------------------------
start_test "non-git dir emits two rows and no worktree row"
out=$(invoke_home "$(wt_payload "$WT_ROOT" "$WT_ROOT")")
assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "row count"

# --- submodule checkout is not a worktree --------------------------------
ORIGIN_SRC="$OUTSIDE/submodule-src"
make_repo "$ORIGIN_SRC" >/dev/null
git -C "$REPO" -c protocol.file.allow=always submodule add -q "$ORIGIN_SRC" sub >/dev/null 2>&1

start_test "submodule checkout renders two rows, no worktree row"
out=$(invoke_home "$(wt_payload "$REPO/sub" "$REPO/sub")")
assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "row count"

# --- session launched inside the worktree --------------------------------
start_test "session registered inside the worktree anchors line 2 on the main tree"
out=$(invoke_home "$(wt_payload "$HOME_FIXTURE/repos/.worktrees/proj/feat/deep/name" \
  "$HOME_FIXTURE/repos/.worktrees/proj/feat/deep/name")")
assert_eq '~/repos/proj | wt-session' "$(ws_row "$out")" "workspace row"

start_test "session launched inside the worktree still names the worktree"
assert_match '\.\./\.worktrees/proj/feat/deep/name' "$(wt_row "$out")"

start_test "worktree row never degrades to a bare dot"
assert_no_match '^ *[^ ]* \.$' "$(wt_row "$out")"

test_summary
