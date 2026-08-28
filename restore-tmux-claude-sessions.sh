#!/usr/bin/env bash
# Replay a snapshot written by save-tmux-claude-sessions.sh: recreate tmux
# sessions/windows with their saved titles and resume the matching Claude
# Code session in each. A window that also had a Neovim session saved gets
# a second pane (a plain vertical split — the original split direction and
# proportions aren't reproduced) running `nvim -S <session file>`.
#
# Windows are recreated at their originally saved index when that index is
# free (the common case: a freshly created or empty session). If it's
# already taken by something else — e.g. adding onto a session you're
# still using — that window falls back to tmux's default placement instead
# of clobbering whatever's already there.
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

  while IFS=$'\t' read -r window_index window_name cwd session_id nvim_session_file; do
    if [ "$APPLY" -eq 0 ]; then
      if [ "$need_new_session" -eq 1 ]; then
        echo "[dry run] tmux new-session -d -s '$tmux_session' -n '$window_name' -c '$cwd'  (then move to index $window_index if needed)"
      else
        echo "[dry run] tmux new-window -t '$tmux_session:$window_index' -n '$window_name' -c '$cwd'  (falls back to default placement if $window_index is taken)"
      fi
      echo "[dry run]   -> claude --resume $session_id"
      if [ -n "$nvim_session_file" ]; then
        echo "[dry run]   -> split window, nvim -S '$nvim_session_file'"
      fi
      need_new_session=0
      continue
    fi

    if [ "$need_new_session" -eq 1 ]; then
      pane_id=$(tmux new-session -d -s "$tmux_session" -n "$window_name" -c "$cwd" -P -F '#{pane_id}')
      need_new_session=0
      actual_index=$(tmux display-message -p -t "$pane_id" '#{window_index}')
      if [ "$actual_index" != "$window_index" ]; then
        window_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
        if tmux move-window -s "$window_id" -t "$tmux_session:$window_index" 2>/dev/null; then
          :
        else
          echo "  ! wanted index $window_index but landed on $actual_index (already taken)" >&2
        fi
      fi
    else
      if pane_id=$(tmux new-window -t "$tmux_session:$window_index" -n "$window_name" -c "$cwd" -P -F '#{pane_id}' 2>/dev/null); then
        :
      else
        pane_id=$(tmux new-window -t "$tmux_session" -n "$window_name" -c "$cwd" -P -F '#{pane_id}')
        actual_index=$(tmux display-message -p -t "$pane_id" '#{window_index}')
        echo "  ! wanted index $window_index but it's taken — landed on $actual_index instead" >&2
      fi
    fi

    tmux send-keys -t "$pane_id" "claude --resume $session_id" Enter
    echo "Restored '$window_name' in session '$tmux_session' -> $session_id"

    if [ -n "$nvim_session_file" ]; then
      if [ ! -f "$nvim_session_file" ]; then
        echo "  ! nvim session file missing ($nvim_session_file) — skipping" >&2
      elif ! command -v nvim >/dev/null 2>&1; then
        echo "  ! nvim not found on PATH — skipping its session ($nvim_session_file)" >&2
      else
        nvim_pane_id=$(tmux split-window -h -t "$pane_id" -c "$cwd" -P -F '#{pane_id}')
        tmux send-keys -t "$nvim_pane_id" "nvim -S '$nvim_session_file'" Enter
        tmux select-pane -t "$pane_id"
        echo "  + restored nvim session alongside it"
      fi
    fi
  done < <(jq -r --arg s "$tmux_session" \
      '[.[] | select(.tmux_session == $s)] | sort_by(.window_index) | .[] | [.window_index, .window_name, .cwd, .session_id, (.nvim_session_file // "")] | @tsv' \
      "$STATE_FILE")
done <<< "$sessions"

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "This was a dry run. Rerun with --apply to actually do it."
fi
