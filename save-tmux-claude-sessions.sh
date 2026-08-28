#!/usr/bin/env bash
# Snapshot every live, interactive Claude Code session running inside tmux.
#
# Claude Code writes one state file per running process at
# ~/.claude/sessions/<pid>.json. Each file already carries the session ID,
# cwd, and a "tmux" field ("<session>:<window_id>.<pane_id>") when the
# process was started inside tmux. This script cross-references those files
# against live tmux windows and writes a single JSON snapshot that
# restore-tmux-claude-sessions.sh can later replay.
#
# If a window also has a Neovim pane, its buffers/splits/cwd are captured
# too, via Neovim's own RPC server (no plugin or config change required —
# every modern Neovim exposes one automatically). Unsaved edits are not
# captured; :mksession only knows about what's on disk.
set -euo pipefail

STATE_FILE="${TMUX_CLAUDE_STATE_FILE:-$HOME/.tmux-claude-resume.json}"
CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions"
NVIM_SESSION_DIR="${TMUX_CLAUDE_NVIM_SESSION_DIR:-$HOME/.tmux-claude-resume-nvim}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed or not on PATH." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not on PATH." >&2
  exit 1
fi

# Walk a pane's process tree (a few levels deep) looking for an nvim
# process. Neovim is normally a direct child of the pane's shell, but this
# tolerates one or two wrapper processes in between.
# Every Neovim instance auto-starts an RPC server socket whose filename
# embeds its own pid, so it's discoverable without --listen or a plugin.
find_nvim_socket_for_pid() {
  local pid="$1" sock
  sock=$(find "${TMPDIR:-/tmp}nvim.$(whoami)" -maxdepth 2 -name "nvim.${pid}.0" 2>/dev/null | head -1)
  if [ -z "$sock" ]; then
    # Fallback for layouts that don't match the default $TMPDIR convention.
    sock=$(lsof -a -p "$pid" -U 2>/dev/null | awk '{print $NF}' | grep "nvim\.${pid}\.[0-9]*$" | head -1)
  fi
  [ -n "$sock" ] && echo "$sock"
}

# Walk a pane's process tree (string-based queue, not a bash array — macOS
# ships bash 3.2, which errors on `set -u` + an empty array expansion)
# looking for a Neovim RPC socket. A plain `nvim` process's own listening
# socket usually belongs not to itself but to an `nvim --embed` child it
# spawns internally, so every process named nvim in the subtree gets
# checked, not just the first one found.
find_nvim_socket_in_tree() {
  local queue="$1" depth=0 pid comm sock children
  while [ -n "$queue" ] && [ "$depth" -lt 4 ]; do
    children=""
    for pid in $queue; do
      comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
      if [ "${comm##*/}" = "nvim" ]; then
        sock=$(find_nvim_socket_for_pid "$pid") || true
        if [ -n "$sock" ]; then
          echo "$sock"
          return 0
        fi
      fi
      children="$children $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
    done
    queue="$children"
    depth=$((depth + 1))
  done
  return 1
}

# Ask a running Neovim to write its own session file, synchronously (the
# RPC round-trip blocks until mksession has actually finished writing).
save_nvim_session() {
  local sock="$1" dest="$2"
  nvim --server "$sock" --remote-expr "execute('mksession! ' . fnameescape('$dest'))" >/dev/null 2>&1
  [ -f "$dest" ]
}

tmp_entries="$(mktemp)"
trap 'rm -f "$tmp_entries"' EXIT

shopt -s nullglob
found_any=0
for f in "$CLAUDE_SESSIONS_DIR"/*.json; do
  found_any=1
  pid=$(jq -r '.pid // empty' "$f")
  kind=$(jq -r '.kind // empty' "$f")
  tmux_field=$(jq -r '.tmux // empty' "$f")
  session_id=$(jq -r '.sessionId // empty' "$f")
  cwd=$(jq -r '.cwd // empty' "$f")

  [ -z "$pid" ] && continue
  [ "$kind" != "interactive" ] && continue
  [ -z "$tmux_field" ] && continue

  # Skip stale session files left behind by a process that died without
  # cleaning up (e.g. kill -9). ps liveness isn't a perfect guard against
  # PID reuse, but it's good enough for a same-boot snapshot.
  if ! ps -p "$pid" >/dev/null 2>&1; then
    echo "Skipping pid $pid (session $session_id): not running" >&2
    continue
  fi

  # tmux field shape: <tmux_session_name>:<window_id>.<pane_id>
  # tmux session names can't contain ':' or '.', so splitting on the
  # first occurrence of each is safe.
  tmux_session="${tmux_field%%:*}"
  rest="${tmux_field#*:}"
  window_id="${rest%%.*}"

  info=$(tmux display-message -p -t "$window_id" '#{window_index}|#{window_name}' 2>/dev/null) || {
    echo "Skipping pid $pid (session $session_id): tmux window $window_id not found" >&2
    continue
  }
  window_index="${info%%|*}"
  window_name="${info#*|}"

  nvim_session_file=""
  for other_pane_pid in $(tmux list-panes -t "$window_id" -F '#{pane_pid}' 2>/dev/null); do
    nvim_sock=$(find_nvim_socket_in_tree "$other_pane_pid") || continue
    mkdir -p "$NVIM_SESSION_DIR"
    candidate="$NVIM_SESSION_DIR/$session_id.vim"
    if save_nvim_session "$nvim_sock" "$candidate"; then
      nvim_session_file="$candidate"
    else
      echo "Found nvim in window $window_id but it didn't respond to :mksession — skipping its session" >&2
    fi
    break
  done

  jq -n \
    --arg tmux_session "$tmux_session" \
    --argjson window_index "$window_index" \
    --arg window_name "$window_name" \
    --arg cwd "$cwd" \
    --arg session_id "$session_id" \
    --arg nvim_session_file "$nvim_session_file" \
    '{tmux_session: $tmux_session, window_index: $window_index, window_name: $window_name, cwd: $cwd, session_id: $session_id}
     + (if $nvim_session_file != "" then {nvim_session_file: $nvim_session_file} else {} end)' \
    >> "$tmp_entries"
done
shopt -u nullglob

if [ "$found_any" -eq 0 ]; then
  echo "No files in $CLAUDE_SESSIONS_DIR — is Claude Code running?" >&2
  exit 1
fi

tmp_state="$(mktemp)"
jq -s 'sort_by(.tmux_session, .window_index)' "$tmp_entries" > "$tmp_state"
mv "$tmp_state" "$STATE_FILE"

count=$(jq 'length' "$STATE_FILE")
echo "Saved $count session(s) to $STATE_FILE"
