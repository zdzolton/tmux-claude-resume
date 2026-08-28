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
# Always prints the plan first. Pass --apply to skip straight to applying
# (no plan, no prompt — for scripted/non-interactive use). Otherwise, if
# both stdin and stdout are a terminal, you're asked to confirm before
# anything is applied. If the target tmux session already exists, new
# windows are added to it (existing windows are left alone); otherwise the
# session is created first.
set -euo pipefail

STATE_FILE="${TMUX_CLAUDE_STATE_FILE:-$HOME/.tmux-claude-resume.json}"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--apply]"
      echo "  (no args)  print the restore plan, then ask before applying it"
      echo "             if attached to a terminal (otherwise just prints)"
      echo "  --apply    skip the plan and prompt, apply immediately"
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

# Color only when stdout is a terminal and the user hasn't opted out (NO_COLOR
# convention: https://no-color.org). Piping to a file or another program
# gets plain text either way.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_reset=$'\033[0m'
  c_bold=$'\033[1m'
  c_dim=$'\033[2m'
  c_green=$'\033[32m'
  c_yellow=$'\033[33m'
  c_cyan=$'\033[36m'
else
  c_reset='' c_bold='' c_dim='' c_green='' c_yellow='' c_cyan=''
fi

sessions=$(jq -r '[.[].tmux_session] | unique[]' "$STATE_FILE")

# Walks the saved sessions/windows once. mode="plan" only prints what would
# happen; mode="apply" does it. Run twice (plan, then apply) rather than
# branching mid-loop, since a dry run has to make no tmux calls at all.
process_sessions() {
  local mode="$1"

  while IFS= read -r tmux_session; do
    [ -z "$tmux_session" ] && continue

    # A purely numeric session name (e.g. "4") is ambiguous as a bare -t
    # target — tmux can read it as a window index in the current session
    # instead. Check existence via list-sessions (no -t at all) rather than
    # has-session, and resolve to the stable $<id> form below before doing
    # anything else with this session name.
    local session_exists=0
    if tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF "$tmux_session"; then
      session_exists=1
    fi
    local need_new_session
    need_new_session=$([ "$session_exists" -eq 1 ] && echo 0 || echo 1)

    local sid=""
    if [ "$session_exists" -eq 1 ] && [ "$mode" = "apply" ]; then
      sid=$(tmux list-sessions -F '#{session_name}	#{session_id}' 2>/dev/null \
        | awk -F'\t' -v s="$tmux_session" '$1==s{print $2; exit}')
    fi

    while IFS=$'\t' read -r window_index window_name cwd session_id nvim_session_file; do
      if [ "$mode" = "plan" ]; then
        if [ "$need_new_session" -eq 1 ]; then
          echo "${c_dim}[plan]${c_reset} tmux new-session -d -s '$tmux_session' -n '$window_name' -c '$cwd'  ${c_dim}(then move to index $window_index if needed)${c_reset}"
        else
          echo "${c_dim}[plan]${c_reset} tmux new-window -t '$tmux_session:$window_index' -n '$window_name' -c '$cwd'  ${c_dim}(falls back to default placement if $window_index is taken)${c_reset}"
        fi
        echo "${c_dim}[plan]${c_reset}   -> ${c_cyan}claude --resume $session_id${c_reset}"
        if [ -n "$nvim_session_file" ]; then
          echo "${c_dim}[plan]${c_reset}   -> split window, ${c_cyan}nvim -S '$nvim_session_file'${c_reset}"
        fi
        need_new_session=0
        continue
      fi

      local pane_id actual_index window_id
      if [ "$need_new_session" -eq 1 ]; then
        pane_id=$(tmux new-session -d -s "$tmux_session" -n "$window_name" -c "$cwd" -P -F '#{pane_id}')
        need_new_session=0
        # The session now definitely exists — resolve its stable id once,
        # from the pane we just created (always unambiguous), for every
        # later window in this session.
        sid=$(tmux display-message -p -t "$pane_id" '#{session_id}')
        actual_index=$(tmux display-message -p -t "$pane_id" '#{window_index}')
        if [ "$actual_index" != "$window_index" ]; then
          window_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
          if tmux move-window -s "$window_id" -t "$sid:$window_index" 2>/dev/null; then
            :
          else
            echo "${c_yellow}  ! wanted index $window_index but landed on $actual_index (already taken)${c_reset}" >&2
          fi
        fi
      else
        if pane_id=$(tmux new-window -t "$sid:$window_index" -n "$window_name" -c "$cwd" -P -F '#{pane_id}' 2>/dev/null); then
          :
        elif pane_id=$(tmux new-window -t "$sid" -n "$window_name" -c "$cwd" -P -F '#{pane_id}' 2>/dev/null); then
          actual_index=$(tmux display-message -p -t "$pane_id" '#{window_index}')
          echo "${c_yellow}  ! wanted index $window_index but it's taken — landed on $actual_index instead${c_reset}" >&2
        else
          echo "${c_yellow}  ! couldn't create a window for '$window_name' (session $session_id) — skipping it, continuing with the rest${c_reset}" >&2
          continue
        fi
      fi

      tmux send-keys -t "$pane_id" "claude --resume $session_id" Enter
      echo "${c_green}Restored${c_reset} '$window_name' in session '$tmux_session' -> $session_id"

      if [ -n "$nvim_session_file" ]; then
        if [ ! -f "$nvim_session_file" ]; then
          echo "${c_yellow}  ! nvim session file missing ($nvim_session_file) — skipping${c_reset}" >&2
        elif ! command -v nvim >/dev/null 2>&1; then
          echo "${c_yellow}  ! nvim not found on PATH — skipping its session ($nvim_session_file)${c_reset}" >&2
        else
          local nvim_pane_id
          nvim_pane_id=$(tmux split-window -h -t "$pane_id" -c "$cwd" -P -F '#{pane_id}')
          tmux send-keys -t "$nvim_pane_id" "nvim -S '$nvim_session_file'" Enter
          tmux select-pane -t "$pane_id"
          echo "${c_green}  + restored nvim session alongside it${c_reset}"
        fi
      fi
    done < <(jq -r --arg s "$tmux_session" \
        '[.[] | select(.tmux_session == $s)] | sort_by(.window_index) | .[] | [.window_index, .window_name, .cwd, .session_id, (.nvim_session_file // "")] | @tsv' \
        "$STATE_FILE")
  done <<< "$sessions"
}

if [ "$APPLY" -eq 1 ]; then
  process_sessions apply
  exit 0
fi

process_sessions plan
echo

if [ -t 0 ] && [ -t 1 ]; then
  printf '%sApply this plan now?%s [y/N] ' "$c_bold" "$c_reset"
  read -r reply
  case "$reply" in
    [Yy]|[Yy][Ee][Ss])
      echo
      process_sessions apply
      ;;
    *)
      echo "Not applying. Rerun with --apply when you're ready."
      ;;
  esac
else
  echo "This was a dry run. Rerun with --apply to actually do it."
fi
