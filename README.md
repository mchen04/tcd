# tcd

Small zsh + tmux setup that makes long-running AI CLI sessions (Claude Code,
Codex, etc.) easy to launch, find, and reattach to — including from your phone.

The name comes from `tcd` ("tmux cd"): jump to a tmux session by typing part of
its name instead of the full thing.

## What you get

- **`tcd [row|partial]`** — lists compact numbered rows with attachment, agent
  state, and age. Use a row number or name fragment to attach. Exact names win
  over partial matches, and `tcd -` returns to the previous session.
- **Phone-first launch commands** — `tcd cl [project]` and `tcd co [project]`
  start or attach Claude and Codex. Projects can be paths or short folder-name
  matches under configured project roots.
- **Remote Macs** — `tcd @host [command]` runs the same command through SSH.
  `tcd hosts` shows configured hosts and whether they answer.
- **`tcd close [partial]`** — the mirror image of attaching: kill sessions by
  partial name instead of memorizing the full one. `tcd close` (no argument)
  closes the session you're currently in; `tcd close zer` closes *every* session
  matching `zer` (handy for clearing out a project's agents at once); `tcd close
  all` closes everything. Closing kills the session's processes, so it lists what
  it's about to kill and asks for a one-key `y/N` confirmation — pass `-y` (or
  `-f`) to skip it. `kill`, `rm`, and `x` work as aliases for `close`.
- **Auto-named sessions** — `claude` and `codex` are wrapped so that when you run
  them outside tmux they launch *inside* a tmux session named after the current
  project (`<repo>-<program>-<hash>`). The path hash keeps same-named repos in
  different folders from colliding. Run them inside tmux and they behave normally.
- **`--yolo` shorthand** — `claude --yolo` expands to
  `claude --dangerously-skip-permissions`.
- **Session snapshots** — `.tmux.conf` sets up
  [tpm](https://github.com/tmux-plugins/tpm) +
  [resurrect](https://github.com/tmux-plugins/tmux-resurrect) +
  [continuum](https://github.com/tmux-plugins/tmux-continuum) to save layouts
  every five minutes. Automatic restore is off. Running processes do not
  survive a lost tmux server.
- **Install checks** — `tcd doctor` reports missing tools, shell setup, project
  roots, remote hosts, and local session count.

## Why

Running agents in named tmux sessions means you can close your laptop, reconnect
later (or SSH in from a phone) and pick the session back up with a short `tcd`
command instead of memorizing generated session names.

## Requirements

- **zsh** — `tcd.zsh` uses zsh-only syntax (`${(q)...}`, `${var:t}`); it will not
  work in bash.
- **tmux**
- `git`, `grep`, `sort`, `column` (standard on macOS/Linux).
- `claude` / `codex` CLIs are **optional** — their wrappers only activate if the
  CLI is installed.

## Install

```sh
git clone https://github.com/mchen04/tcd ~/tcd
cd ~/tcd
./install.sh
```

The installer will:
1. Append `source ~/tcd/tcd.zsh` to your `~/.zshrc` (idempotent).
2. Symlink `~/.tmux.conf` to this repo's copy (backing up any existing file).
3. Clone tpm if it's missing.

Then restart your shell, start tmux, and press `prefix + I` (capital `i`) once to
install the tmux plugins.

### Manual install

If you'd rather not run the script, just add this to your `~/.zshrc`:

```sh
source /path/to/tcd/tcd.zsh
```

and merge `.tmux.conf` into your own.

## Usage

```sh
tcd              # list all sessions
tcd 2            # attach to row 2
tcd zer          # attach/switch to the first session matching "zer"
tcd -            # return to the previous session
tcd cl pancake   # start or attach Claude in the Pancake project
tcd co pancake   # start or attach Codex in the Pancake project
tcd @mbp         # list sessions on a configured remote Mac
tcd doctor       # check the local setup
tcd close        # close the session you're in right now
tcd close zer    # close every session matching "zer" (asks to confirm)
tcd close -y zer # ...same, but skip the confirmation prompt
tcd close all    # close every session
claude           # outside tmux: opens a named session for this project
claude --yolo    # = claude --dangerously-skip-permissions
```

## Tests and safety

```sh
zsh tests/smoke.zsh
```

Tests must use the private socket helper in `tests/lib.zsh`. They must never run
an unsocketed destructive tmux command. The benchmark covers read-only list and
match performance; it does not close sessions.

## License

MIT
