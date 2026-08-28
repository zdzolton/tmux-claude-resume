# tmux-claude-resume

Snapshot every Claude Code session running in tmux, so a reboot doesn't cost
you your open work. Save the state, reboot, then recreate the same tmux
windows — titles, working directories, and each Claude session resumed with
full history — with one command.

## How it works

Claude Code writes a state file per running process, at
`~/.claude/sessions/<pid>.json`. Each file carries the session ID, the
working directory, and (when the process was started inside tmux) a `tmux`
field pointing at the exact window and pane. `save-tmux-claude-sessions.sh`
reads those files, keeps only the ones whose process is still alive, and
writes the result to one state file: `~/.tmux-claude-resume.json`

`restore-tmux-claude-sessions.sh` reads that state file and, for each
session in it, creates (or reuses) the named tmux session, adds a window
with the saved title and working directory, and sends
`claude --resume <session-id>` into it. It tries to recreate each window at
its originally saved index; if that index is already taken (e.g. you're
adding onto a session you're still using), it falls back to tmux's default
placement instead of clobbering whatever's there, and prints a warning.

### Neovim

If a window also has a Neovim pane, its open buffers and splits get saved
too, and restored alongside Claude as a second pane. This needs no Neovim
config change — every modern Neovim exposes an RPC socket automatically,
which the save script discovers from the pane's process tree (by pid) and
uses to trigger `:mksession!` in place. Restore then runs
`nvim -S <session file>` in a plain vertical split next to Claude (the
original split direction/proportions aren't reproduced — see the layout
question in Known limitations if you want that instead).

**`:mksession` does not capture unsaved edits** — only which files are
open, cursor position, folds, and splits. A buffer with uncommitted changes
reloads as the on-disk version. `:terminal` buffers inside Neovim also
don't meaningfully survive a reload.

## Prerequisites

- **macOS.** Autosave uses launchd, and Neovim socket discovery's fast path
  assumes macOS's `$TMPDIR` layout (it falls back to `lsof`, but that's
  only been exercised on macOS too). Not tested on Linux.
- **tmux** and **jq** on `PATH`.
- **Claude Code CLI**, a version that writes `~/.claude/sessions/<pid>.json`
  with a `tmux` field and supports `--resume <session-id>` (built against
  2.1.250; older versions may not write that file).
- The system `bash` (`/bin/bash`) and `lsof` — both ship with macOS, no
  install needed. The scripts deliberately avoid bash 4+ features (macOS
  ships bash 3.2) so they run correctly without Homebrew bash.
- **Neovim** — optional, only needed for the Neovim session capture
  feature. No plugin or config change required.

## Install

Both scripts are plain bash. They need `tmux` and `jq` on `PATH`:

```
chmod +x save-tmux-claude-sessions.sh restore-tmux-claude-sessions.sh
```

### Autosave (recommended)

A launchd agent runs the save script every 5 minutes and once at login, so
the state file survives a crash or forced restart, not just a planned
shutdown. It's already installed on this machine at
`~/Library/LaunchAgents/local.tmux-claude-resume.save.plist`

Useful commands:

```bash
# check status
launchctl print gui/$(id -u)/local.tmux-claude-resume.save

# stop it
launchctl bootout gui/$(id -u)/local.tmux-claude-resume.save

# reload after editing the plist
launchctl bootout gui/$(id -u)/local.tmux-claude-resume.save
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.tmux-claude-resume.save.plist
```

Logs (stdout and stderr, combined) go to
`~/Library/Logs/tmux-claude-resume-save.log`

To change the interval, edit the `StartInterval` value (seconds) in the
plist, then reload as shown above.

If you'd rather not run a background job at all, skip the launchd agent and
just run `save-tmux-claude-sessions.sh` by hand before a planned reboot.

## Usage

**Save** (automatic via launchd, or run manually any time):

```bash
./save-tmux-claude-sessions.sh
```

Prints how many sessions it found and where it wrote them.

**Restore**, after a reboot — always check the plan first:

```bash
./restore-tmux-claude-sessions.sh          # dry run, prints the plan
./restore-tmux-claude-sessions.sh --apply  # actually create windows + resume
```

A tmux session name that already exists is not clobbered — new windows are
added to it. A session name that doesn't exist yet is created fresh.

**Manual list**, when you know exactly what you want back instead of relying
on the last autosave: write `~/.tmux-claude-resume.json` yourself, or hand
Claude a list of (window title, cwd, session ID) rows and let it build the
file for you. Format:

```json
[
  {
    "tmux_session": "0",
    "window_index": 0,
    "window_name": "some window title",
    "cwd": "/absolute/path/to/project",
    "session_id": "uuid-from-claude"
  }
]
```

`window_index` is the tmux window number restore will try to recreate the
window at (falling back to default placement if it's taken).

## Known limitations

- Only top-level interactive sessions are captured; subagent/background
  sessions have no `tmux` field and are skipped, which is intentional.
- Restoring a Neovim session always uses a plain vertical split, not the
  original layout. If you want faithful layout reproduction later, tmux's
  `window_layout` string would need to be captured at save time and
  reapplied with `select-layout` at restore time — not implemented yet.
- If Neovim's own swapfile from a prior (uncleanly-shut-down) instance is
  still on disk, `nvim -S` on restore will show its usual swap-file
  recovery prompt. That's normal Neovim behavior, not a bug in this tool.
- A tmux session literally named with digits only (e.g. `"0"`) is handled
  correctly, but is a known tmux target-parsing gotcha — the restore script
  resolves to the stable `$<id>` form internally to avoid it. If you hack on
  the script, keep using that resolution rather than the plain session name.
- If a window's Claude process died without cleaning up its
  `~/.claude/sessions/<pid>.json` file, and something else reuses that PID
  before the next save, that stale entry could in theory be picked up. Low
  risk in practice, not specifically guarded against.
- The [claude-tmux-namer](https://github.com/cosgroveb/claude-tmux-namer)
  plugin renames windows based on live conversation content, so a restored
  title is a starting point — it will likely be renamed again after that
  session's next response.
- Only one Neovim pane per window is captured. If a window has two Neovim
  panes, the save script stops at whichever one it finds first (in tmux's
  pane-index order) and silently skips the other — not implemented, since
  it's an uncommon layout and restore already can't reproduce true pane
  layout even for a single Neovim pane.
