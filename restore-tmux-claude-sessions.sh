#!/usr/bin/env bash
# Replay a snapshot written by save-tmux-claude-sessions.sh: recreate tmux
# sessions/windows with their saved titles and resume the matching Claude
# Code session in each.
#
# Defaults to a dry run — pass --apply to actually create windows and start
# Claude. If the target tmux session already exists, new windows are added
# to it (existing windows are left alone); otherwise the session is created
# first.
set -euo pipefail

STATE_FILE="${TMUX_CLAUDE_STATE_FILE:-$HOME/.tmux-claude-resume.json}"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--apply]"
      echo "  (no args)  print the restore plan without changing anything"
      echo "  --apply    actually create the tmux windows and resume Claude"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not installed or not on PATH." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not on PATH." >&2
  exit 1
fi
if [ ! -f "$STATE_FILE" ]; then
  echo "No state file at $STATE_FILE — run save-tmux-claude-sessions.sh first." >&2
  exit 1
fi

sessions=$(jq -r '[.[].tmux_session] | unique[]' "$STATE_FILE")

while IFS= read -r tmux_session; do
  [ -z "$tmux_session" ] && continue

  session_exists=0
  tmux has-session -t "$tmux_session" 2>/dev/null && session_exists=1
  need_new_session=$([ "$session_exists" -eq 1 ] && echo 0 || echo 1)

  while IFS=$'\t' read -r window_name cwd session_id; do
    if [ "$APPLY" -eq 0 ]; then
      if [ "$need_new_session" -eq 1 ]; then
        echo "[dry run] tmux new-session -d -s '$tmux_session' -n '$window_name' -c '$cwd'"
      else
        echo "[dry run] tmux new-window -t '$tmux_session' -n '$window_name' -c '$cwd'"
      fi
      echo "[dry run]   -> claude --resume $session_id"
      need_new_session=0
      continue
    fi

    if [ "$need_new_session" -eq 1 ]; then
      tmux new-session -d -s "$tmux_session" -n "$window_name" -c "$cwd"
      need_new_session=0
    else
      # A plain session name is ambiguous when it's purely numeric (tmux's
      # target parser can read it as a window index in the current session
      # instead of a session name). Resolve to the stable $<id> form first.
      session_target=$(tmux display-message -p -t "$tmux_session" '#{session_id}')
      tmux new-window -t "$session_target" -n "$window_name" -c "$cwd"
    fi

    # Send into whichever window/pane tmux just made active — right after
    # creation that's always the one we just made. Resolve the same way.
    session_target=$(tmux display-message -p -t "$tmux_session" '#{session_id}')
    tmux send-keys -t "$session_target" "claude --resume $session_id" Enter
    echo "Restored '$window_name' in session '$tmux_session' -> $session_id"
  done < <(jq -r --arg s "$tmux_session" \
      '[.[] | select(.tmux_session == $s)] | sort_by(.window_index) | .[] | [.window_name, .cwd, .session_id] | @tsv' \
      "$STATE_FILE")
done <<< "$sessions"

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "This was a dry run. Rerun with --apply to actually do it."
fi
