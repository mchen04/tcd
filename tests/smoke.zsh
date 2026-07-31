#!/usr/bin/env zsh
set -eu
setopt extendedglob

repo_dir="${0:A:h:h}"
real_tmux="$(whence -p tmux)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tcd-smoke.XXXXXX")"
chmod 700 "$test_tmp"

# The test must never touch the tmux server the caller is sitting in: tmux reads
# $TMUX to pick a server, which silently overrides $TMUX_TMPDIR, so running this
# from inside tmux made `kill-server` kill the caller's own session. Talk to a
# private socket explicitly and drop the inherited client handle.
unset TMUX
socket="$test_tmp/socket"
tm() { "$real_tmux" -S "$socket" "$@" }

cleanup() {
  tm kill-server 2>/dev/null || true
  rm -rf "$test_tmp"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -r -- "FAIL: $*"
  exit 1
}

source "$repo_dir/tcd.zsh"

# Project-derived names stay stable, sanitized, and program-specific.
name="$(_ai_tmux_project_session_name claude)"
[[ "$name" == tcd-claude-[0-9]## ]] || fail "unexpected session name: $name"

# Exercise real tmux lifecycle operations on an isolated server.
tm new-session -d -s 'smoke[1]' -n shell
tm new-session -d -s smoke1 -n shell

listing="$(
  unfunction tmux 2>/dev/null || true
  tmux() { "$real_tmux" -S "$socket" "$@" }
  _tcd_list
)"
[[ "$listing" == *'smoke[1]'* ]] || fail "session list omitted smoke[1]"
[[ "$listing" == *'smoke1'* ]] || fail "session list omitted smoke1"

# Mock only the client-selection boundary so attach can be checked without
# replacing the current terminal client.
typeset -ga tmux_call
tmux() {
  if [[ "$1" == ls ]]; then
    print -r -- 'smoke1'
    print -r -- 'smoke[1]'
    return 0
  fi
  tmux_call=("$@")
}

TMUX='test-client' tcd 'smoke[1]'
[[ "${(j: :)tmux_call}" == 'switch-client -t =smoke[1]' ]] || \
  fail "literal attach selected the wrong session: ${(j: :)tmux_call}"

# Wrapper commands preserve spaces and rewrite Claude's convenience flag.
unset TMUX
claude --yolo 'two words'
[[ "${tmux_call[1]}" == new-session ]] || fail "Claude wrapper skipped tmux"
[[ "${tmux_call[5]}" == *'--dangerously-skip-permissions'* ]] || \
  fail "Claude wrapper did not rewrite --yolo"
[[ "${tmux_call[5]}" == *'two\ words'* ]] || fail "Claude wrapper lost argument quoting"

codex 'two words'
[[ "${tmux_call[1]}" == new-session ]] || fail "Codex wrapper skipped tmux"
[[ "${tmux_call[5]}" == *'two\ words'* ]] || fail "Codex wrapper lost argument quoting"

# Closing a literal partial must not also close the regex-lookalike session.
(
  unfunction tmux
  tmux() { "$real_tmux" -S "$socket" "$@" }
  _tcd_close -y 'smoke[1]'
)
tm has-session -t '=smoke1' || \
  fail "literal close killed smoke1"
if tm has-session -t '=smoke[1]' 2>/dev/null; then
  fail "literal close left smoke[1] running"
fi

print -r -- 'PASS: tcd smoke test'
