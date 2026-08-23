# Shared isolated-tmux harness for the tcd test suite.
#
# SAFETY CONTRACT (the reason this file exists):
# tmux picks its server from $TMUX before it looks at $TMUX_TMPDIR, so a test
# running inside tmux that says `tmux kill-server` kills the *caller's* server.
# That happened once. Every tmux call from a test therefore goes through tmux_()
# below, which is hard-wired to a private -S socket, and $TMUX is unset the
# moment this file is sourced. Tests must never call bare `tmux`.

setopt extendedglob

typeset -g TCD_REPO_DIR="${${(%):-%x}:A:h:h}"
typeset -g TCD_REAL_TMUX="$(whence -p tmux)"
# TCD_LIB_FILE lets tests/mutate.zsh load a deliberately broken copy.
typeset -g TCD_LIB="${TCD_LIB_FILE:-$TCD_REPO_DIR/tcd.zsh}"
[[ -n "$TCD_REAL_TMUX" ]] || { print -u2 -r -- "tmux not on PATH"; exit 1 }

# Drop the inherited client handle so nothing can fall through to the real server.
unset TMUX TMUX_PANE

typeset -g TCD_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tcd-test.XXXXXX")"
TCD_TEST_TMP="${TCD_TEST_TMP:A}"   # resolved, so paths compare equal to :A results
chmod 700 "$TCD_TEST_TMP"
export TMUX_TMPDIR="$TCD_TEST_TMP"
mkdir -p "$TMUX_TMPDIR/tmux-$UID"
chmod 700 "$TMUX_TMPDIR/tmux-$UID"
typeset -g TCD_SOCKET="$TMUX_TMPDIR/tmux-$UID/default"
typeset -g TCD_TMUX_SOCKET="$TCD_SOCKET"

# The only sanctioned way to talk to tmux from a test.
tmux_() { "$TCD_REAL_TMUX" -S "$TCD_SOCKET" "$@" }

# Source tcd.zsh with the AI CLIs stubbed (so the claude/codex wrappers always
# get defined, installed or not). TCD_TMUX_SOCKET keeps all calls private.
tcd_load() {
  local stub_bin="$TCD_TEST_TMP/bin"
  mkdir -p "$stub_bin"
  local prog
  for prog in claude codex ssh mosh; do
    printf '%s\n' '#!/bin/sh' \
      "printf 'STUB $prog'; for a in \"\$@\"; do printf ' [%s]' \"\$a\"; done; echo" \
      '# A long-running mode lets tests watch a real process inside a pane.' \
      '[ "${1:-}" = "--sleep" ] && while :; do sleep 1; done' \
      'exit 0' \
      > "$stub_bin/$prog"
    chmod +x "$stub_bin/$prog"
  done
  path=( "$stub_bin" $path )
  typeset -g TCD_STUB_BIN="$stub_bin"

  # Config lives in the private temp dir so the caller's real config (hosts,
  # project dirs) never leaks into a test.
  export XDG_CONFIG_HOME="$TCD_TEST_TMP/config"
  mkdir -p "$XDG_CONFIG_HOME/tcd"
  [[ -n "${TCD_TEST_CONFIG:-}" ]] && print -r -- "$TCD_TEST_CONFIG" > "$XDG_CONFIG_HOME/tcd/config.zsh"

  source "$TCD_LIB"
}

tcd_harness_cleanup() {
  tmux_ kill-server 2>/dev/null || true
  [[ -n "$TCD_TEST_TMP" && -d "$TCD_TEST_TMP" ]] && rm -rf "$TCD_TEST_TMP"
  return 0
}

# Assert the harness itself is safe. Called at suite start; fails loudly.
tcd_assert_isolated() {
  [[ -z "${TMUX:-}" ]] || { print -u2 -r -- "REFUSING TO RUN: \$TMUX is set ($TMUX)"; exit 1 }
  [[ "$TMUX_TMPDIR" == "$TCD_TEST_TMP" ]] || { print -u2 -r -- "fallback root escaped temp dir"; exit 1 }
  [[ "$TCD_SOCKET" == "$TCD_TEST_TMP/tmux-$UID/default" ]] || { print -u2 -r -- "socket escaped temp dir"; exit 1 }
  # A private server must start out empty; if it already has sessions we are
  # almost certainly pointed at somebody else's socket.
  local existing
  existing="$(tmux_ ls 2>/dev/null)" || true
  [[ -z "$existing" ]] || { print -u2 -r -- "REFUSING TO RUN: private socket already has sessions:\n$existing"; exit 1 }
}

# --- assertions ------------------------------------------------------------

typeset -g TCD_TESTS_RUN=0
typeset -g TCD_TESTS_FAILED=0

ok() {
  (( TCD_TESTS_RUN++ ))
  print -r -- "  ok   $1"
}

not_ok() {
  (( TCD_TESTS_RUN++ ))
  (( TCD_TESTS_FAILED++ ))
  print -u2 -r -- "  FAIL $1"
  [[ -n "${2:-}" ]] && print -u2 -r -- "       $2"
  return 0
}

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    not_ok "$1" "expected: [$2]
       actual:   [$3]"
  fi
}

assert_contains() {
  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then
    ok "$1"
  else
    not_ok "$1" "[$2] does not contain [$3]"
  fi
}

assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    ok "$1"
  else
    not_ok "$1" "[$2] unexpectedly contains [$3]"
  fi
}

assert_true() {
  # assert_true <label> <command...>
  local label="$1"; shift
  if "$@"; then ok "$label"; else not_ok "$label" "command failed: $*"; fi
}

assert_false() {
  local label="$1"; shift
  if "$@"; then not_ok "$label" "command unexpectedly succeeded: $*"; else ok "$label"; fi
}

assert_status() {
  # assert_status <label> <expected-rc> <command...>
  local label="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}
