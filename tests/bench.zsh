#!/usr/bin/env zsh
# Stress + timing harness. Creates N sessions on a private tmux socket and times
# the two read-only hot paths: list and match (what `tcd <partial>` does before
# it hands off to the terminal). Benchmarks must not run destructive commands.
#
# Usage: zsh tests/bench.zsh [count ...]     (default: 10 100 500)
#
# Never touches the caller's tmux server -- see tests/lib.zsh for the contract.
# No `set -e`: in zsh a failing command substitution poisons the assignment's
# exit status, and `tmux ls` against an empty server legitimately returns 1.
set -u
zmodload zsh/datetime

source "${${(%):-%x}:A:h}/lib.zsh"
trap tcd_harness_cleanup EXIT INT TERM
tcd_assert_isolated

tcd_load

# Baseline trees have no _tcd_match; measure the inline pipeline they ship with
# so before/after numbers compare the code that actually runs.
if ! (( ${+functions[_tcd_match]} )); then
  _tcd_match() {
    local match
    match="$(_tcd_tmux ls -F '#{session_name}' 2>/dev/null | grep -iF -- "$1" | head -1)"
    [[ -n "$match" ]] || return 1
    print -r -- "$match"
  }
fi

# tcd.zsh predating the _tcd_tmux indirection calls bare `tmux`; shadowing it
# keeps even that tree pinned to the private socket.
tmux() { "$TCD_REAL_TMUX" -S "$TCD_SOCKET" "$@" }

time_it() {
  # time_it <label> <reps> <command...>
  local label="$1" reps="$2"; shift 2
  local start end i
  start=$EPOCHREALTIME
  for (( i = 1; i <= reps; i++ )); do "$@" >/dev/null 2>&1 || true; done
  end=$EPOCHREALTIME
  printf '  %-12s %8.2f ms/op  (%d reps)\n' "$label" $(( (end - start) * 1000.0 / reps )) "$reps"
}

bench_round() {
  local n="$1" start i live
  print -r -- ""
  print -r -- "--- $n sessions ---"

  start=$EPOCHREALTIME
  for (( i = 1; i <= n; i++ )); do
    tmux_ new-session -d -s "bench-$i" 2>/dev/null || true
  done
  printf '  %-12s %8.2f ms total (setup)\n' create $(( (EPOCHREALTIME - start) * 1000 ))

  live="$(tmux_ ls 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$live" == "$n" ]] || { print -u2 -r -- "  STRESS FAIL: wanted $n sessions, have $live"; return 1 }
  print -r -- "  live sessions: $live"

  time_it list 20 _tcd_list
  time_it match-first 50 _tcd_match "bench-1"
  time_it match-last 50 _tcd_match "bench-$n"
  time_it match-miss 50 _tcd_match "zzzz-no-such"

}

print -r -- "tcd bench  (socket: $TCD_SOCKET)"
for n in ${@:-10 100 500}; do
  bench_round "$n"
done

print -r -- ""
print -r -- "bench complete"
