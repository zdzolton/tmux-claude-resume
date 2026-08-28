# tmux-claude-resume

This file gives guidance for working on this repo's code. See `README.md`
for what the tool does and how to use it.

## Critical: never test tmux commands against the real server

Always test tmux changes on a separate tmux server. Never reuse a session
name on the real server, even one that looks safely unique.

**Why this rule exists:** during development, a test tried to isolate
itself by renaming a throwaway session to `"0"`. That rename failed
because the real, live session was already named `"0"` — but the test
script kept running anyway and ended with `tmux kill-session -t 0`, which
killed the real session mid-use. A same-server name collision made that
possible. A separate server makes it impossible.

**How to test safely:** point a shimmed `tmux` at an isolated server.

```bash
mkdir -p /tmp/tmux-isolated-test-bin
cat > /tmp/tmux-isolated-test-bin/tmux <<'EOF'
#!/bin/bash
exec /opt/homebrew/bin/tmux -L tmux-claude-resume-devtest "$@"
EOF
chmod +x /tmp/tmux-isolated-test-bin/tmux
export PATH="/tmp/tmux-isolated-test-bin:$PATH"
```

Run the scripts normally after that — every `tmux` call goes to the
isolated server, so nothing can touch your real session regardless of what
names the test uses. Tear down with
`/opt/homebrew/bin/tmux -L tmux-claude-resume-devtest kill-server` when
done, and remove the shim directory.

Also: check the exit code and output of one command before running a later
destructive one in the same batch. Don't assume a prior step succeeded.

## Implementation gotchas

**macOS ships bash 3.2.** `#!/usr/bin/env bash` resolves to whatever's
first on `PATH`, which may still be 3.2. Under `set -u`, bash 3.2 throws
`unbound variable` when expanding an empty array (`"${arr[@]}"`). Don't use
bash arrays for anything that can end up empty — use a space- or
newline-delimited string and word-split instead. See `find_nvim_socket_in_tree`
in `save-tmux-claude-sessions.sh` for the pattern.

**A purely numeric tmux session name (e.g. `"0"`) is ambiguous as a bare
`-t` target.** tmux's target parser can read a bare number as a window
index in the current session instead of a session name, which silently
creates or targets the wrong thing. Always resolve to a stable, unambiguous
form before using session names as targets:
- `#{session_id}` (`$<n>`) for a session
- `#{window_id}` (`@<n>`) for a window
- `#{pane_id}` (`%<n>`) for a pane, captured directly from creation via
  `-P -F '#{pane_id}'` — prefer this over re-resolving "the current pane of
  the session" later, since it can't drift.

**Modern Neovim's outer TUI process doesn't hold its own RPC socket.** It
spawns an `nvim --embed` child that does. Socket discovery has to walk the
whole process subtree looking for any `nvim`-named process with a
reachable socket, not just check the first match found.
