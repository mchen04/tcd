# tcd

Small zsh + tmux setup that makes long-running AI CLI sessions (Claude Code,
Codex, etc.) easy to launch, find, and reattach to — including from your phone.

The name comes from `tcd` ("tmux cd"): jump to a tmux session by typing part of
its name instead of the full thing.

## What you get

- **`tcd [partial]`** — with no argument, lists your tmux sessions (attached ones
  marked `▸` and sorted first, with window count and creation time). With an
  argument, attaches to the first session whose name contains `partial`
  (case-insensitive). So `tcd zer` reattaches to `ZER-259-claude-579067`.
- **Auto-named sessions** — `claude` and `codex` are wrapped so that when you run
  them outside tmux they launch *inside* a tmux session named after the current
  project (`<repo>-<program>-<hash>`). The path hash keeps same-named repos in
  different folders from colliding. Run them inside tmux and they behave normally.
- **`--yolo` shorthand** — `claude --yolo` expands to
  `claude --dangerously-skip-permissions`.
- **Auto save/restore** — `.tmux.conf` sets up
  [tpm](https://github.com/tmux-plugins/tpm) +
  [resurrect](https://github.com/tmux-plugins/tmux-resurrect) +
  [continuum](https://github.com/tmux-plugins/tmux-continuum) so sessions
  (including `claude`/`codex` processes) survive reboots, and windows are named
  after their directory rather than the running process.

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
tcd            # list all sessions
tcd zer        # attach/switch to the first session matching "zer"
claude         # outside tmux: opens a named session for this project
claude --yolo  # = claude --dangerously-skip-permissions
```

## License

MIT
