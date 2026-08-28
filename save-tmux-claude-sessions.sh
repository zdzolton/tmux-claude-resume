#!/usr/bin/env bash
# Snapshot every live, interactive Claude Code session running inside tmux.
#
# Claude Code writes one state file per running process at
# ~/.claude/sessions/<pid>.json. Each file already carries the session ID,
# cwd, and a "tmux" field ("<session>:<window_id>.<pane_id>") when the
# process was started inside tmux. This script cross-references those files
# against live tmux windows and writes a single JSON snapshot that
# restore-tmux-claude-sessions.sh can later replay.
set -euo pipefail

STATE_FILE="${TMUX_CLAUDE_STATE_FILE:-$HOME/.tmux-claude-resume.json}"
CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed or not on PATH." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not on PATH." >&2
  exit 1
fi

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

  jq -n \
    --arg tmux_session "$tmux_session" \
    --argjson window_index "$window_index" \
    --arg window_name "$window_name" \
    --arg cwd "$cwd" \
    --arg session_id "$session_id" \
    '{tmux_session: $tmux_session, window_index: $window_index, window_name: $window_name, cwd: $cwd, session_id: $session_id}' \
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
