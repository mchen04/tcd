#!/usr/bin/env zsh
# tcd test suite. Every tmux call goes to a private socket -- see tests/lib.zsh.
#
#   zsh tests/run.zsh
#
# No `set -e`: a failing assertion should report and continue, and in zsh a
# command substitution that exits non-zero poisons the enclosing assignment.
set -u
setopt extendedglob

source "${${(%):-%x}:A:h}/lib.zsh"
trap tcd_harness_cleanup EXIT INT TERM
tcd_assert_isolated
# Hosts and project dirs come from a private config so the caller's real
# config can never leak in. The projects tree is created further down.
TCD_TEST_CONFIG="TCD_HOSTS=(mini mbp)
TCD_PROJECT_DIRS=(\"$TCD_TEST_TMP/projects\")"
tcd_load
export COLUMNS=80

section() { print -r -- ""; print -r -- "== $1" }

# Reset the private server between sections so each starts from a known state.
reset_server() {
  tmux_ kill-server 2>/dev/null || true
  local waited=0
  while tmux_ ls >/dev/null 2>&1 && (( waited < 50 )); do
    (( waited++ ))
  done
}

# Record what tcd asks tmux to do instead of doing it. Restores on `untrap`.
typeset -ga TMUX_CALL=()
# Read-only queries still hit the private socket so matching sees real
# sessions; only the commands that would seize the terminal get recorded.
capture_tmux() {
  TMUX_CALL=()
  _tcd_tmux() {
    case "$1" in
      ls|display-message|has-session) "$TCD_REAL_TMUX" -S "$TCD_SOCKET" "$@"; return ;;
    esac
    TMUX_CALL=( "$@" )
    return 0
  }
}
real_tmux_again() {
  _tcd_tmux() { "$TCD_REAL_TMUX" -S "$TCD_SOCKET" "$@" }
}

# Wait until the listing shows <state> for <session> (process scans race
# with session start-up).
wait_state() {
  local session="$1" want="$2" i line
  for (( i = 0; i < 40; i++ )); do
    for line in ${(f)"$(_tcd_rows)"}; do
      [[ "${line%%$'\t'*}" == "$session" ]] || continue
      line="${line#*$'\t'*$'\t'}"
      [[ "${line%%$'\t'*}" == "$want" ]] && return 0
    done
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------------------
section 'harness safety'
# ---------------------------------------------------------------------------
assert_eq 'TMUX is unset inside the suite' '' "${TMUX:-}"
assert_contains 'socket lives in the private temp dir' "$TCD_SOCKET" "$TCD_TEST_TMP"
assert_eq 'bare tmux fallback is private' "$TCD_TEST_TMP" "$TMUX_TMPDIR"
assert_eq 'config is the private one' 'mini mbp' "${(j: :)TCD_HOSTS}"
assert_contains 'project dirs are the private ones' "${TCD_PROJECT_DIRS[1]}" "$TCD_TEST_TMP"

# A declared socket must beat an inherited client route after TCD loads.
route_socket="$TCD_TEST_TMP/route-socket"
decoy_socket="$TCD_TEST_TMP/decoy-socket"
"$TCD_REAL_TMUX" -S "$decoy_socket" new-session -d -s decoy-sentinel
decoy_pid="$("$TCD_REAL_TMUX" -S "$decoy_socket" display-message -p '#{pid}')"
decoy_pane="$("$TCD_REAL_TMUX" -S "$decoy_socket" display-message -p '#{pane_id}')"
(
  TCD_TMUX_SOCKET="$route_socket"
  export TMUX="$decoy_socket,$decoy_pid,${decoy_pane#%}"
  export TMUX_PANE="$decoy_pane"
  source "$TCD_LIB"
  _tcd_tmux new-session -d -s route-probe
)
route_hit=0 decoy_hit=0
"$TCD_REAL_TMUX" -S "$route_socket" has-session -t '=route-probe' 2>/dev/null && route_hit=1
"$TCD_REAL_TMUX" -S "$decoy_socket" has-session -t '=route-probe' 2>/dev/null && decoy_hit=1
assert_eq 'declared socket survives source' '1' "$route_hit"
assert_eq 'inherited TMUX cannot seize the route' '0' "$decoy_hit"
"$TCD_REAL_TMUX" -S "$route_socket" kill-server 2>/dev/null || true
"$TCD_REAL_TMUX" -S "$decoy_socket" kill-server 2>/dev/null || true

# Both directions of the safety claim: no test file may name a destructive tmux
# command without going through a socketed helper.
bad_calls="$(grep -nE '(^|[^_a-zA-Z"])tmux[[:space:]]+(kill-server|kill-session)' \
             "$TCD_REPO_DIR"/tests/*.zsh 2>/dev/null \
             | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" || true
assert_eq 'no unsocketed destructive tmux call in tests/' '' "$bad_calls"

# ---------------------------------------------------------------------------
section 'session name derivation'
# ---------------------------------------------------------------------------
# The repo dir is not always named "tcd" -- a git worktree gets its own folder
# name -- so the expectation is derived, not hard-coded.
repo_slug="${TCD_REPO_DIR:t}"
name="$(_ai_tmux_project_session_name claude)"
assert_true 'name is <repo>-claude-<hash>' eval "[[ \"$name\" == $repo_slug-claude-[0-9]## ]]"
codex_name="$(_ai_tmux_project_session_name codex)"
assert_true 'name is program-specific' eval "[[ \"$codex_name\" == $repo_slug-codex-[0-9]## ]]"

# Same folder name in two different paths must not collide.
mkdir -p "$TCD_TEST_TMP/a/Proj Name" "$TCD_TEST_TMP/b/Proj Name"
n1="$(cd "$TCD_TEST_TMP/a/Proj Name" && _ai_tmux_project_session_name claude)"
n2="$(cd "$TCD_TEST_TMP/b/Proj Name" && _ai_tmux_project_session_name claude)"
assert_contains 'spaces are sanitized out of the name' "$n1" 'Proj-Name-claude-'
assert_true 'same-named dirs get different hashes' eval "[[ \"$n1\" != \"$n2\" ]]"
n3="$(_ai_tmux_project_session_name claude "$TCD_TEST_TMP/a/Proj Name")"
assert_eq 'an explicit dir gives the same name as cd-ing there' "$n1" "$n3"
n4="$(_ai_tmux_project_session_name claude "$TCD_REPO_DIR/tests")"
assert_eq 'a subdir of a repo names the repo root' "$name" "$n4"

# ---------------------------------------------------------------------------
section 'listing'
# ---------------------------------------------------------------------------
reset_server
out="$(_tcd_list)"; rc=$?
assert_contains 'empty server lists nothing gracefully' "$out" 'no tmux sessions'
assert_contains 'empty server says how to start one' "$out" 'tcd cl <project>'
assert_eq 'empty list returns 1' '1' "$rc"

tmux_ new-session -d -s 'smoke[1]'
tmux_ new-session -d -s smoke1
tmux_ new-session -d -s Alpha
out="$(_tcd_list)"
assert_contains 'lists smoke[1]' "$out" 'smoke[1]'
assert_contains 'lists smoke1' "$out" 'smoke1'
assert_contains 'a plain shell shows as idle' "$out" 'idle'
first_line="${out%%$'\n'*}"
assert_contains 'sorts case-insensitively (Alpha first)' "$first_line" 'Alpha'
assert_true 'rows are numbered from 1' eval "[[ \"$first_line\" == ' 1 '* ]]"
assert_contains 'rows carry a compact age' "$first_line" 's'
print -r -- "$out" | sed 's/^/    | /'

# Multiple windows are flagged compactly.
tmux_ new-window -t '=Alpha'
out="$(_tcd_list)"
assert_contains 'extra windows show as Nw' "${out%%$'\n'*}" '2w'
tmux_ kill-window -t '=Alpha:1'

# Age formatting.
assert_eq 'age: seconds' '45s' "$(_tcd_age 955 1000)"
assert_eq 'age: minutes' '12m' "$(_tcd_age 280 1000)"
assert_eq 'age: hours' '3h' "$(_tcd_age 0 11000)"
assert_eq 'age: days' '2d' "$(_tcd_age 0 200000)"
assert_eq 'age: garbage is ?' '?' "$(_tcd_age abc 1000)"

# Narrow terminal: every row fits, names are truncated with an ellipsis.
tmux_ new-session -d -s 'a-very-long-session-name-that-will-not-fit-on-a-phone'
out="$(COLUMNS=36 _tcd_list)"
longest=0
for line in ${(f)out}; do (( ${#line} > longest )) && longest=${#line}; done
assert_true "rows fit in 36 columns (longest $longest)" eval "(( $longest <= 36 ))"
assert_contains 'long names are truncated with …' "$out" '…'
out="$(COLUMNS=200 _tcd_list)"
assert_contains 'wide terminals show the full name' "$out" 'a-very-long-session-name-that-will-not-fit-on-a-phone'
assert_eq 'COLUMNS is honoured' '36' "$(COLUMNS=36 _tcd_cols)"
assert_true 'zero COLUMNS falls back to a positive width' eval "[[ \"$(COLUMNS=0 _tcd_cols </dev/null)\" == <1-> ]]"
tmux_ kill-session -t '=a-very-long-session-name-that-will-not-fit-on-a-phone'

# ---------------------------------------------------------------------------
section 'status detection'
# ---------------------------------------------------------------------------
assert_eq 'classify: bare claude' 'claude' "$(_tcd_classify 'claude --yolo')"
assert_eq 'classify: native versioned binary' 'claude' "$(_tcd_classify '2.1.241 --dangerously-skip-permissions')"
assert_eq 'classify: versions path' 'claude' "$(_tcd_classify '/Users/x/.local/share/claude/versions/2.1.241')"
assert_eq 'classify: node codex' 'codex' "$(_tcd_classify 'node /Users/x/.nvm/versions/node/v20/bin/codex --yolo')"
assert_eq 'classify: bare codex' 'codex' "$(_tcd_classify 'codex resume --last')"
assert_status 'classify: a shell is neither' 1 _tcd_classify '-zsh'
assert_status 'classify: vim is neither' 1 _tcd_classify 'vim notes.md'
assert_status 'classify: an arg mentioning codex is not codex' 1 _tcd_classify 'vim codex-notes.md'

# Started by the wrapper: the start command names the program.
tmux_ new-session -d -s started-claude "$TCD_STUB_BIN/claude --sleep"
assert_true 'a session started on claude reports claude' wait_state started-claude claude

# Started from a shell: only the live process tree knows what runs.
tmux_ new-session -d -s shell-codex
tmux_ send-keys -t '=shell-codex:' "exec $TCD_STUB_BIN/codex --sleep" Enter
assert_true 'codex launched from a shell is found in the process tree' wait_state shell-codex codex

# Something else in the foreground is named, not hidden.
tmux_ new-session -d -s shell-sleep
tmux_ send-keys -t '=shell-sleep:' "exec sleep 300" Enter
assert_true 'a foreground non-agent command is named' wait_state shell-sleep sleep

reset_server

# ---------------------------------------------------------------------------
section 'matching'
# ---------------------------------------------------------------------------
tmux_ new-session -d -s 'smoke[1]'
tmux_ new-session -d -s smoke1
tmux_ new-session -d -s Alpha
tmux_ new-session -d -s Beta
assert_eq 'literal match ignores glob metacharacters' 'smoke[1]' "$(_tcd_match 'smoke[1]')"
assert_eq 'case-insensitive substring match' 'Alpha' "$(_tcd_match alph)"
assert_status 'no match returns 1' 1 _tcd_match 'zzz-nope'

# Row numbers select from the same order the listing prints.
assert_eq 'row 1 is Alpha' 'Alpha' "$(_tcd_nth 1)"
assert_eq 'row 2 is Beta' 'Beta' "$(_tcd_nth 2)"
assert_eq 'tcd <n> resolves a row number' 'Beta' "$(_tcd_match 2)"
assert_status 'a row past the end fails' 1 _tcd_match 9
assert_status 'row 0 fails' 1 _tcd_nth 0

# A session literally named like a number beats the row number.
tmux_ new-session -d -s 2
assert_eq 'exact numeric name wins over row number' '2' "$(_tcd_match 2)"
tmux_ kill-session -t '=2'

# Exact name beats a substring hit on a longer name.
tmux_ new-session -d -s web
tmux_ new-session -d -s webapp
assert_eq 'exact name wins over longer substring match' 'web' "$(_tcd_match web)"
assert_eq 'substring still reaches the longer name' 'webapp' "$(_tcd_match webap)"
tmux_ kill-session -t '=web'
assert_eq 'without the exact session, substring matches' 'webapp' "$(_tcd_match web)"
tmux_ kill-session -t '=webapp'

# ---------------------------------------------------------------------------
section 'attach'
# ---------------------------------------------------------------------------
capture_tmux
TMUX='fake-client' tcd 'smoke[1]'
assert_eq 'inside tmux, attach switches the client' 'switch-client -t =smoke[1]' "${(j: :)TMUX_CALL}"
real_tmux_again

capture_tmux
_tcd_attach 'smoke1'
assert_eq 'outside tmux, attach attaches' 'attach -t =smoke1' "${(j: :)TMUX_CALL}"
TMUX_CALL=()
tcd 1
assert_eq 'tcd 1 attaches to row 1' 'attach -t =Alpha' "${(j: :)TMUX_CALL}"
real_tmux_again

capture_tmux
TMUX='fake-client' _tcd_last
assert_eq 'tcd - switches to the last session inside tmux' 'switch-client -l' "${(j: :)TMUX_CALL}"
TMUX_CALL=()
_tcd_last
assert_eq 'tcd - attaches outside tmux' 'attach' "${(j: :)TMUX_CALL}"
real_tmux_again

out="$(tcd zzz-nope 2>&1)"; rc=$?
assert_contains 'no-match prints the partial' "$out" 'no tmux session matching: zzz-nope'
assert_contains 'no-match falls back to the listing' "$out" 'smoke1'
assert_eq 'no-match returns 1' '1' "$rc"

out="$(tcd --help)"
assert_contains 'help documents close' "$out" 'tcd close <n|part>'
assert_contains 'help documents the aliases' "$out" 'kill, rm and x are aliases'
assert_contains 'help documents remote hosts' "$out" 'tcd @host'
assert_eq 'tcd help is the same text' "$out" "$(tcd help)"
# Ages advance between the two calls, so the volatile column is dropped: the
# claim is that `tcd ls` routes to the listing, not that a clock stood still.
no_age() { sed 's/ [0-9][0-9]*[smhd]$//' }
assert_eq 'tcd ls lists' "$(_tcd_list | no_age)" "$(tcd ls | no_age)"

# ---------------------------------------------------------------------------
section 'close'
# ---------------------------------------------------------------------------
# Literal close must not take the regex-lookalike's neighbour with it.
out="$(_tcd_close -y 'smoke[1]')"
assert_eq 'close reports the session it killed' 'closed: smoke[1]' "$out"
assert_true 'literal close spared smoke1' tmux_ has-session -t '=smoke1'
assert_false 'literal close killed smoke[1]' tmux_ has-session -t '=smoke[1]'

# Partial matching many.
reset_server
tmux_ new-session -d -s proj-claude-1
tmux_ new-session -d -s proj-codex-2
tmux_ new-session -d -s other
out="$(_tcd_close -y proj)"
assert_contains 'close <partial> killed the first match' "$out" 'closed: proj-claude-1'
assert_contains 'close <partial> killed the second match' "$out" 'closed: proj-codex-2'
assert_true 'close <partial> spared the non-match' tmux_ has-session -t '=other'

# Row numbers and several targets at once.
tmux_ new-session -d -s num-a
tmux_ new-session -d -s num-b
# rows: 1 num-a, 2 num-b, 3 other
out="$(_tcd_close -y 2)"
assert_eq 'close <n> closes exactly that row' 'closed: num-b' "$out"
assert_true 'close <n> spared its neighbours' tmux_ has-session -t '=num-a'
out="$(_tcd_close -y num-a other)"
assert_contains 'close accepts several targets (1)' "$out" 'closed: num-a'
assert_contains 'close accepts several targets (2)' "$out" 'closed: other'
tmux_ new-session -d -s other

# Aliases and every force flag.
for alias_name in close kill rm x; do
  tmux_ new-session -d -s "alias-$alias_name"
  tcd "$alias_name" -y "alias-$alias_name" >/dev/null
  assert_false "alias '$alias_name' closes" tmux_ has-session -t "=alias-$alias_name"
done
for flag in -y --yes -f --force; do
  tmux_ new-session -d -s "flag-test"
  _tcd_close "$flag" flag-test >/dev/null
  assert_false "flag '$flag' skips confirmation" tmux_ has-session -t '=flag-test'
done

# Confirmation prompt: no tty here, so `read -q` fails => abort, nothing killed.
out="$(_tcd_close other 2>&1 </dev/null)"; rc=$?
assert_contains 'unconfirmed close lists the target first' "$out" 'close 1 session(s):'
assert_contains 'unconfirmed close names the target' "$out" '  other'
assert_contains 'unconfirmed close shows what the target runs' "$out" '(idle)'
assert_contains 'unconfirmed close aborts' "$out" 'aborted'
assert_eq 'aborted close returns 1' '1' "$rc"
assert_true 'aborted close killed nothing' tmux_ has-session -t '=other'

# The confirmation names the agent that would die.
tmux_ new-session -d -s busy "$TCD_STUB_BIN/claude --sleep"
wait_state busy claude
out="$(_tcd_close busy 2>&1 </dev/null)"
assert_contains 'confirmation warns about a running claude' "$out" 'busy  (claude)'
assert_true 'the running claude survived the aborted close' tmux_ has-session -t '=busy'
tmux_ kill-session -t '=busy'

# No match / nothing to close.
out="$(_tcd_close -y zzz-nope 2>&1)"; rc=$?
assert_contains 'close with no match explains' "$out" 'no tmux session matching: zzz-nope'
assert_eq 'close with no match returns 1' '1' "$rc"

# No args, outside tmux.
out="$(_tcd_close 2>&1 </dev/null)"; rc=$?
assert_contains 'close with no args outside tmux refuses' "$out" 'not inside a tmux session'
assert_eq 'close with no args outside tmux returns 1' '1' "$rc"

# No args, inside tmux: closes the session the caller is in.
_tcd_tmux() {
  if [[ "$1" == display-message ]]; then print -r -- 'other'; return 0; fi
  "$TCD_REAL_TMUX" -S "$TCD_SOCKET" "$@"
}
out="$(TMUX='fake-client' _tcd_close -y 2>&1)"
assert_eq 'close with no args inside tmux closes the current session' 'closed: other' "$out"
assert_false 'current session is gone' tmux_ has-session -t '=other'
real_tmux_again

# close all.
reset_server
tmux_ new-session -d -s all-1
tmux_ new-session -d -s all-2
out="$(_tcd_close -y all)"
assert_contains 'close all closes the first' "$out" 'closed: all-1'
assert_contains 'close all closes the second' "$out" 'closed: all-2'
assert_eq 'nothing survives close all' '' "$(_tcd_names)"

out="$(_tcd_close -y all 2>&1)"; rc=$?
assert_contains 'close all on an empty server says so' "$out" 'no tmux sessions to close'
assert_eq 'close all on an empty server returns 1' '1' "$rc"

# A kill that does not take effect must be reported as a failure, not a success.
tmux_ new-session -d -s survivor
_tcd_tmux() {
  if [[ "$1" == kill-session ]]; then return 0; fi   # pretend the kill worked
  "$TCD_REAL_TMUX" -S "$TCD_SOCKET" "$@"
}
out="$(_tcd_close -y survivor 2>&1)"; rc=$?
assert_eq 'a session that survives is reported failed' 'failed to close: survivor' "$out"
assert_eq 'a failed close returns 1' '1' "$rc"
real_tmux_again
tmux_ kill-session -t '=survivor'

# ---------------------------------------------------------------------------
section 'claude / codex wrappers'
# ---------------------------------------------------------------------------
capture_tmux
claude --yolo 'two words'
assert_eq 'claude wrapper opens a session' 'new-session' "${TMUX_CALL[1]}"
assert_contains 'claude wrapper rewrites --yolo' "${TMUX_CALL[5]}" '--dangerously-skip-permissions'
assert_not_contains 'no bare --yolo survives' "${TMUX_CALL[5]}" '--yolo'
assert_contains 'claude wrapper preserves quoting' "${TMUX_CALL[5]}" 'two\ words'

claude --yolo --yolo
assert_eq 'every --yolo is rewritten' \
  'claude --dangerously-skip-permissions --dangerously-skip-permissions' "${TMUX_CALL[5]}"

claude -p --yolo --model opus
assert_eq '--yolo is rewritten in place among other flags' \
  'claude -p --dangerously-skip-permissions --model opus' "${TMUX_CALL[5]}"

claude --yolo-ish
assert_eq 'only the exact --yolo flag is rewritten' 'claude --yolo-ish' "${TMUX_CALL[5]}"

codex 'two words'
assert_eq 'codex wrapper opens a session' 'new-session' "${TMUX_CALL[1]}"
assert_contains 'codex wrapper preserves quoting' "${TMUX_CALL[5]}" 'two\ words'
codex --yolo
assert_eq 'codex passes --yolo through untouched' 'codex --yolo' "${TMUX_CALL[5]}"

# Inside tmux the wrapper must run the program directly, not nest a session.
TMUX_CALL=()
out="$(TMUX='fake-client' claude hello)"
assert_eq 'inside tmux claude runs directly' 'STUB claude [hello]' "$out"
assert_eq 'inside tmux claude does not call tmux' '' "${(j: :)TMUX_CALL}"

# tmux absent: fall back to running the program.
_tcd_have_tmux() { return 1 }
TMUX_CALL=()
out="$(claude hello)"
assert_eq 'without tmux claude still runs' 'STUB claude [hello]' "$out"
assert_eq 'without tmux no tmux call is made' '' "${(j: :)TMUX_CALL}"
out="$(tcd 2>&1)"; rc=$?
assert_contains 'without tmux, tcd explains' "$out" 'tcd: tmux not found'
assert_eq 'without tmux, tcd returns 1' '1' "$rc"
_tcd_have_tmux() { command -v tmux >/dev/null 2>&1 }
real_tmux_again

# ---------------------------------------------------------------------------
section 'project lookup'
# ---------------------------------------------------------------------------
P="$TCD_TEST_TMP/projects"
mkdir -p "$P/Apps/zerg" "$P/Apps/zergai-web" "$P/Tools/skills" "$P/Apps/Other/deep/nested" "$P/dup" "$P/Apps/dup"
assert_eq 'no project means the current dir' "$PWD" "$(_tcd_find_project '')"
assert_eq 'a path is used as-is' "$P/Apps/zerg" "$(_tcd_find_project "$P/Apps/zerg")"
assert_eq 'exact folder name wins over a longer substring hit' "$P/Apps/zerg" "$(_tcd_find_project zerg)"
assert_eq 'exact match is case-insensitive' "$P/Apps/zerg" "$(_tcd_find_project ZERG)"
assert_eq 'substring finds the only candidate' "$P/Apps/zergai-web" "$(_tcd_find_project gai)"
assert_eq 'depth-3 folders are found' "$P/Apps/Other/deep" "$(_tcd_find_project deep)"
assert_status 'depth-4 folders are out of reach' 1 _tcd_find_project nested
assert_eq 'the shallower of two exact matches wins' "$P/dup" "$(_tcd_find_project dup 2>/dev/null)"
out="$(_tcd_find_project ls 2>&1)"; rc=$?
assert_eq 'an ambiguous substring returns 2' '2' "$rc"
assert_contains 'an ambiguous substring lists the candidates' "$out" 'Tools/skills'
assert_status 'an unknown project returns 1' 1 _tcd_find_project zzz-nope

# ---------------------------------------------------------------------------
section 'tcd cl / tcd co'
# ---------------------------------------------------------------------------
reset_server
capture_tmux
tcd cl zerg --yolo
zerg_name="$(_ai_tmux_project_session_name claude "$P/Apps/zerg")"
assert_eq 'cl starts a new session' 'new-session' "${TMUX_CALL[1]}"
assert_eq 'cl names the session after the project' "$zerg_name" "${TMUX_CALL[3]}"
assert_eq 'cl starts in the project dir' "$P/Apps/zerg" "${TMUX_CALL[5]}"
assert_eq 'cl rewrites --yolo' 'claude --dangerously-skip-permissions' "${TMUX_CALL[6]}"

TMUX_CALL=()
tcd co zerg resume --last
assert_eq 'co starts codex' 'codex resume --last' "${TMUX_CALL[6]}"
assert_contains 'co uses the codex name' "${TMUX_CALL[3]}" '-codex-'

TMUX_CALL=()
tcd cl
assert_eq 'cl with no project uses the current dir' "$PWD" "${TMUX_CALL[5]}"
TMUX_CALL=()
tcd cl -c
assert_eq 'a leading flag is not a project' "$PWD" "${TMUX_CALL[5]}"
assert_eq 'the flag reaches claude' 'claude -c' "${TMUX_CALL[6]}"

TMUX_CALL=()
TMUX='fake-client' tcd cl zerg
assert_eq 'inside tmux, cl creates detached then switches' 'switch-client' "${TMUX_CALL[1]}"

out="$(tcd cl zzz-nope 2>&1)"; rc=$?
assert_contains 'unknown project explains' "$out" "no project or session matching 'zzz-nope'"
assert_contains 'unknown project says where it looked' "$out" 'looked under:'
assert_eq 'unknown project returns 1' '1' "$rc"
out="$(tcd cl ls 2>&1)"; rc=$?
assert_eq 'ambiguous project returns 2' '2' "$rc"
assert_contains 'ambiguous project lists candidates' "$out" 'matches several projects'
real_tmux_again

# An existing session is attached, never duplicated.
tmux_ new-session -d -s "$zerg_name"
capture_tmux
tcd cl zerg --yolo >/dev/null
assert_eq 'cl attaches to the existing session' "attach -t =$zerg_name" "${(j: :)TMUX_CALL}"
out="$(tcd cl zerg --yolo)"
assert_contains 'cl says the args were ignored' "$out" 'args ignored'
out="$(tcd cl zerg)"
assert_eq 'no warning without args' '' "$out"
# A session partial that is not a folder still works, and only for the program.
TMUX_CALL=()
tcd cl "${zerg_name[1,8]}"
assert_eq 'cl <session-partial> attaches' "attach -t =$zerg_name" "${(j: :)TMUX_CALL}"
TMUX_CALL=()
out="$(tcd co "${zerg_name[1,8]}" 2>&1)"; rc=$?
assert_eq 'co does not attach to a claude session' '1' "$rc"
TMUX_CALL=()
tcd cl 1
assert_eq 'cl <row-number> attaches' "attach -t =$zerg_name" "${(j: :)TMUX_CALL}"
real_tmux_again
reset_server

# Program missing: a PATH with tmux and claude but no codex at all.
mkdir -p "$TCD_TEST_TMP/nobin"
ln -sf "$TCD_REAL_TMUX" "$TCD_TEST_TMP/nobin/tmux"
ln -sf "$TCD_STUB_BIN/claude" "$TCD_TEST_TMP/nobin/claude"
path_save=( $path )
path=( "$TCD_TEST_TMP/nobin" )
hash -r
capture_tmux
out="$(tcd co 2>&1)"; rc=$?
assert_contains 'missing program explains' "$out" 'codex is not installed'
assert_eq 'missing program returns 1' '1' "$rc"
assert_eq 'missing program starts nothing' '' "${(j: :)TMUX_CALL}"
real_tmux_again
path=( $path_save ); hash -r

# ---------------------------------------------------------------------------
section 'remote hosts'
# ---------------------------------------------------------------------------
out="$(tcd @mini 2 </dev/null)"
assert_contains 'remote dispatch goes through ssh' "$out" 'STUB ssh'
assert_contains 'remote dispatch names the host' "$out" '[mini]'
assert_contains 'remote dispatch runs tcd in a login shell' "$out" '[-lic]'
assert_contains 'remote dispatch forwards the command, quoted for the far shell' "$out" '[tcd\ 2]'
assert_not_contains 'no tty requested without a terminal' "$out" '[-t]'

out="$(tcd @mini cl zerg 'two words' </dev/null)"
assert_contains 'remote args survive a second level of quoting' "$out" '[tcd\ cl\ zerg\ two\\\ words]'

out="$(tcd mini </dev/null)"
assert_contains 'a configured host name works without @' "$out" '[mini]'
assert_contains 'bare host lists remotely' "$out" '[tcd]'

tmux_ new-session -d -s mini-claude-1
capture_tmux
tcd mini
assert_eq 'a local session beats a host name' 'attach -t =mini-claude-1' "${(j: :)TMUX_CALL}"
real_tmux_again
tmux_ kill-session -t '=mini-claude-1'

out="$(TCD_REMOTE=mosh tcd @mbp </dev/null)"
assert_contains 'TCD_REMOTE=mosh uses mosh' "$out" 'STUB mosh'

out="$(tcd notahost 2>&1)"; rc=$?
assert_contains 'an unconfigured name is just a missing session' "$out" 'no tmux session matching: notahost'

out="$(tcd hosts)"
assert_contains 'hosts lists each configured host' "$out" 'mini'
assert_contains 'hosts lists the second host' "$out" 'mbp'
assert_contains 'hosts reports the stub as up' "$out" 'up'
out="$(TCD_HOSTS=() tcd hosts 2>&1)"; rc=$?
assert_contains 'no hosts explains how to add one' "$out" 'TCD_HOSTS=(mini mbp)'
assert_eq 'no hosts returns 1' '1' "$rc"

# ssh failures get a hint instead of a bare exit code.
print -r -- '#!/bin/sh
exit 255' > "$TCD_STUB_BIN/ssh"
out="$(tcd @mini 2>&1 </dev/null)"; rc=$?
assert_eq 'unreachable host propagates 255' '255' "$rc"
assert_contains 'unreachable host gets a hint' "$out" 'could not reach mini'
assert_contains 'hint mentions Tailscale' "$out" 'Tailscale'
printf '%s\n' '#!/bin/sh' "printf 'STUB ssh'; for a in \"\$@\"; do printf ' [%s]' \"\$a\"; done; echo" > "$TCD_STUB_BIN/ssh"

# ---------------------------------------------------------------------------
section 'doctor'
# ---------------------------------------------------------------------------
fake_home="$TCD_TEST_TMP/home"
mkdir -p "$fake_home"
out="$(HOME="$fake_home" tcd doctor 2>&1)"; rc=$?
assert_contains 'doctor reports tmux' "$out" 'ok    tmux'
assert_contains 'doctor reports claude' "$out" 'ok    claude installed'
assert_contains 'doctor flags a missing source line' "$out" 'FAIL  ~/.zshrc does not source tcd.zsh'
assert_contains 'doctor flags a missing tmux.conf' "$out" 'FAIL  ~/.tmux.conf missing'
assert_contains 'doctor checks hosts' "$out" 'mini'
assert_eq 'doctor returns 1 when something fails' '1' "$rc"

print -r -- 'source /x/tcd.zsh' > "$fake_home/.zshrc"
ln -s "$TCD_REPO_DIR/.tmux.conf" "$fake_home/.tmux.conf"
out="$(HOME="$fake_home" tcd doctor 2>&1)"; rc=$?
assert_contains 'doctor sees the source line' "$out" 'ok    ~/.zshrc sources tcd.zsh'
assert_contains 'doctor sees the symlink' "$out" 'ok    ~/.tmux.conf ->'
assert_not_contains 'doctor is clean' "$out" 'FAIL'
assert_eq 'doctor returns 0 when clean' '0' "$rc"

# ---------------------------------------------------------------------------
section 'config and login list'
# ---------------------------------------------------------------------------
assert_eq 'TCD_REMOTE defaults to ssh' 'ssh' "$TCD_REMOTE"
out="$(XDG_CONFIG_HOME="$TCD_TEST_TMP/none" zsh -c "source $TCD_LIB; print -r -- \${#TCD_HOSTS} \${TCD_PROJECT_DIRS[1]}")"
assert_eq 'without a config: no hosts, ~/Projects' "0 $HOME/Projects" "$out"

reset_server
tmux_ new-session -d -s login-demo
# A real login shell cannot have _tcd_tmux overridden before its rc file runs,
# so point tmux's default socket at the private server via TMUX_TMPDIR (which
# tmux honours whenever $TMUX is unset) and give the shell its own rc dir.
login_home="$TCD_TEST_TMP/login"
mkdir -p "$login_home/tt/tmux-$UID"
chmod 700 "$login_home/tt/tmux-$UID"
ln -s "$TCD_SOCKET" "$login_home/tt/tmux-$UID/default"
print -r -- "source '$TCD_LIB'" > "$login_home/.zshrc"
login_shell() { ZDOTDIR="$login_home" TMUX_TMPDIR="$login_home/tt" SSH_CONNECTION='1 2 3 4' "$@" zsh -ic 'true' 2>/dev/null }
out="$(login_shell env TCD_LOGIN_LIST=1)"
assert_contains 'TCD_LOGIN_LIST=1 lists on an ssh login shell' "$out" 'login-demo'
out="$(login_shell env)"
assert_not_contains 'login list is off by default' "$out" 'login-demo'
out="$(login_shell env TCD_LOGIN_LIST=1 TMUX=fake-client)"
assert_not_contains 'login list stays quiet inside tmux' "$out" 'login-demo'

# ---------------------------------------------------------------------------
section 'live view (offline parts)'
# ---------------------------------------------------------------------------
reset_server
tmux_ new-session -d -s Alpha
tmux_ new-session -d -s beta

# The whole point of the live view: its body is the listing, not a second
# implementation of it. Ages tick, so the volatile column is dropped.
frame="$(LINES=24 _tcd_live_frame)"
body="${frame%$'\n'*}"
assert_eq 'a frame body is exactly the normal listing' \
  "$(_tcd_list | no_age)" "$(print -r -- "$body" | no_age)"
assert_eq 'the last line is the footer' 'live · q quit' "${frame##*$'\n'}"
assert_contains 'the footer names the quit key' "$frame" 'q quit'

# Columns, ordering, truncation and status all come along for free, but assert
# them through the live path too so a future short-cut cannot skip them.
assert_true 'live rows are numbered from the same order' \
  eval "[[ \"\${frame%%\$'\n'*}\" == ' 1 '*Alpha* ]]"
tmux_ new-session -d -s a-very-long-session-name-that-will-not-fit-on-a-phone
narrow="$(COLUMNS=36 LINES=24 _tcd_live_frame)"
longest=0
for line in ${(f)narrow}; do (( ${#line} > longest )) && longest=${#line}; done
assert_true "live rows fit in 36 columns (longest $longest)" eval "(( $longest <= 36 ))"
assert_contains 'live truncates long names too' "$narrow" '…'
tmux_ kill-session -t '=a-very-long-session-name-that-will-not-fit-on-a-phone'

tmux_ new-session -d -s live-agent "$TCD_STUB_BIN/claude --sleep"
wait_state live-agent claude
assert_contains 'live shows the same agent status' "$(LINES=24 _tcd_live_frame)" 'claude'
tmux_ kill-session -t '=live-agent'

# Height: a frame never exceeds the terminal, so it cannot scroll itself away.
for h in 1 2 3 6 24; do
  n=$(print -rl -- "$(LINES=$h _tcd_live_frame)" | wc -l | tr -d ' ')
  assert_true "a frame fits in $h lines (got $n)" eval "(( $n <= $h ))"
done
for i in 1 2 3 4 5 6 7 8; do tmux_ new-session -d -s "fill-$i"; done
short="$(LINES=6 _tcd_live_frame)"
assert_eq 'a clamped frame is exactly the terminal height' '6' "$(print -rl -- "$short" | wc -l | tr -d ' ')"
assert_contains 'a clamped frame says how many rows are hidden' "$short" ' more'
assert_eq 'the footer survives clamping' 'live · q quit' "${short##*$'\n'}"
for i in 1 2 3 4 5 6 7 8; do tmux_ kill-session -t "=fill-$i"; done

# An empty server keeps the same message -- and the same failure status -- so
# the live view still tells a new user how to start something.
reset_server
empty="$(LINES=24 _tcd_live_frame)"; rc=$?
assert_contains 'an empty server still explains itself' "$empty" 'no tmux sessions'
assert_contains 'an empty server still offers a next step' "$empty" 'tcd cl <project>'
assert_eq 'an empty frame reports the empty status' '1' "$rc"

# Redraw shape: home, overwrite each line, erase its tail, erase the rest.
# No clear-screen and no trailing newline -- that is what makes it flicker-free
# and stops a full-height frame from scrolling the terminal by one line.
drawn="$(_tcd_live_draw $'aa\nbb')"
# A command substitution strips trailing newlines, so anything asserted about
# the end of a frame needs a sentinel to survive the capture.
raw="$(_tcd_live_draw $'aa\nbb'; print -rn -- '|END')"
assert_true 'a redraw homes the cursor first' eval "[[ \"\$drawn\" == \$'\\e[H'* ]]"
assert_contains 'a redraw erases each line it writes' "$drawn" $'aa\e[K'
assert_contains 'a redraw separates lines with CR LF' "$drawn" $'\e[K\r\nbb'
tail="${raw%|END}"
assert_true 'a redraw erases below the last line' eval "[[ \"\$tail\" == *\$'\\e[J' ]]"
assert_not_contains 'a redraw never clears the screen' "$drawn" $'\e[2J'
assert_true 'a redraw emits no trailing newline' eval "[[ \"\${tail: -1}\" != \$'\n' ]]"

# Refresh interval: small by default, and never 0 (which would spin the CPU).
assert_eq 'the default interval is 2s' '2' "$(_tcd_live_secs)"
assert_eq 'a zero interval is clamped up' '0.2' "$(TCD_LIVE_INTERVAL=0 _tcd_live_secs)"
assert_eq 'a huge interval is clamped down' '60' "$(TCD_LIVE_INTERVAL=900 _tcd_live_secs)"
assert_eq 'a nonsense interval falls back' '2' "$(TCD_LIVE_INTERVAL=abc _tcd_live_secs)"
assert_eq 'a fractional interval is kept' '0.5' "$(TCD_LIVE_INTERVAL=0.5 _tcd_live_secs)"

# Without a terminal there is nothing to draw on and no key to read.
out="$(_tcd_live </dev/null 2>&1)"; rc=$?
assert_contains 'live without a tty explains itself' "$out" 'needs a terminal'
assert_eq 'live without a tty returns 1' '1' "$rc"
assert_not_contains 'live without a tty writes no escape codes' "$out" $'\e['
# Restoring when nothing was set up must be a no-op, not an escape-code burst.
unset _TCD_LIVE_TTY _TCD_LIVE_ON
assert_eq 'restoring an inactive live view emits nothing' '' "$(_tcd_live_restore)"

# Dispatch, help and completion.
_tcd_live() { print -r -- 'LIVE-CALLED' }
assert_eq 'tcd --live runs the live view' 'LIVE-CALLED' "$(tcd --live)"
unfunction _tcd_live
source "$TCD_LIB"
assert_contains 'help documents --live' "$(tcd help)" 'tcd --live'
comp="$(typeset -f _tcd_completion)"
assert_contains 'completion offers --live' "$comp" '--live'

# ---------------------------------------------------------------------------
section 'live view (running in a pane)'
# ---------------------------------------------------------------------------
# The live view only exists on a terminal, so it is exercised on one: a pane of
# the same private tmux server the rest of the suite uses. The pane is the tty;
# capture-pane is what the user would be looking at.
reset_server
live_dir="$TCD_TEST_TMP/live"
mkdir -p "$live_dir"

# The driver records the terminal state around the call so the test can prove
# every bit of it came back, then parks so the pane outlives the live view.
cat > "$live_dir/drive.zsh" <<EOF
export TCD_TMUX_SOCKET="$TCD_SOCKET"
export TCD_LIVE_INTERVAL=0.3
export COLUMNS=80 LINES=12
source "$TCD_LIB"
# Descendants of this shell, so the test can prove the live view leaves none.
kids() { command ps -axo ppid= | tr -d ' ' | grep -cx \$\$ }
command stty -g > "$live_dir/stty.before"
kids > "$live_dir/kids.before"
print -rn -- 'NORMAL-SCREEN-MARKER'
tcd --live
print -r -- \$? > "$live_dir/rc"
command stty -g > "$live_dir/stty.after"
kids > "$live_dir/kids.after"
print -rn -- 'LIVE-VIEW-RETURNED'
while :; do sleep 1; done
EOF

live_start() {   # live_start <session>
  rm -f "$live_dir"/{rc,stty.before,stty.after,kids.before,kids.after}
  tmux_ new-session -d -s "$1" -x 80 -y 12 "zsh -f '$live_dir/drive.zsh'"
}
live_pane() { tmux_ capture-pane -p -t "=$1:" 2>/dev/null }
live_fmt()  { tmux_ display-message -p -t "=$1:" "$2" 2>/dev/null }
# Poll rather than sleep a fixed time: the frame lands when it lands.
live_wait() {    # live_wait <session> <needle>
  local i
  for (( i = 0; i < 80; i++ )); do
    [[ "$(live_pane "$1")" == *"$2"* ]] && return 0
    sleep 0.1
  done
  return 1
}
live_wait_gone() {
  local i
  for (( i = 0; i < 80; i++ )); do
    [[ "$(live_pane "$1")" != *"$2"* ]] && return 0
    sleep 0.1
  done
  return 1
}
live_wait_file() {
  local i
  for (( i = 0; i < 80; i++ )); do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}
# The age column of the row naming <needle>, digits only.
live_age() {
  local line
  for line in ${(f)"$(live_pane "$1")"}; do
    [[ "$line" == *"$2"* ]] || continue
    line="${line##* }"
    print -r -- "${line%[smhd]}"
    return 0
  done
  return 1
}

live_start live-host
assert_true 'the live view paints a first frame' live_wait live-host 'live · q quit'
assert_true 'the live view lists its own session' live_wait live-host 'live-host'
assert_eq 'the live view runs on the alternate screen' '1' "$(live_fmt live-host '#{alternate_on}')"
assert_eq 'the live view hides the cursor' '0' "$(live_fmt live-host '#{cursor_flag}')"
assert_not_contains 'the alternate screen hides what was on the terminal' \
  "$(live_pane live-host)" 'NORMAL-SCREEN-MARKER'

# Refresh: nobody touches the keyboard for any of this.
tmux_ new-session -d -s live-added
assert_true 'a new session appears by itself' live_wait live-host 'live-added'
tmux_ kill-session -t '=live-added'
assert_true 'a closed session disappears by itself' live_wait_gone live-host 'live-added'

# Status and attachment changes show up the same way.
tmux_ new-session -d -s live-agent "$TCD_STUB_BIN/claude --sleep"
assert_true 'a session that starts an agent turns from idle to claude' live_wait live-host 'claude'
tmux_ kill-session -t '=live-agent'
assert_true 'the agent row goes when its session does' live_wait_gone live-host 'claude'

# Attachment: a client attaching flips the marker column of that row.
tmux_ new-session -d -s live-attached
live_wait live-host 'live-attached'
# A real client on a real terminal -- another pane of the same private server.
# It goes through a script file because the nested quoting of an inline pane
# command is what silently breaks here.
cat > "$live_dir/client.zsh" <<EOF
unset TMUX TMUX_PANE
"$TCD_REAL_TMUX" -S "$TCD_SOCKET" attach -t '=live-attached'
while :; do sleep 1; done
EOF
tmux_ new-session -d -s live-client -x 80 -y 12 "zsh -f '$live_dir/client.zsh'"
assert_true 'attaching a client shows the ▸ marker' live_wait live-host '▸ live-attached'
tmux_ kill-session -t '=live-client'
assert_true 'detaching clears the marker' live_wait_gone live-host '▸ live-attached'
tmux_ kill-session -t '=live-attached'

# Ages advance on their own. A quiet session is used because the live view's
# own pane keeps its session busy.
tmux_ new-session -d -s live-clock
live_wait live-host 'live-clock'
age_first="$(live_age live-host live-clock)"
sleep 4
age_later="$(live_age live-host live-clock)"
assert_true "ages advance without input ($age_first -> $age_later)" \
  eval "[[ \"$age_first\" == <-> && \"$age_later\" == <-> ]] && (( $age_later > $age_first ))"
tmux_ kill-session -t '=live-clock'

# Redrawing must not scroll: on the alternate screen nothing reaches history.
assert_eq 'many redraws add nothing to the scrollback' '0' "$(live_fmt live-host '#{history_size}')"

# q quits, and every piece of terminal state comes back.
tmux_ send-keys -t '=live-host:' 'q'
assert_true 'q ends the live view' live_wait_file "$live_dir/rc"
assert_eq 'q exits 0' '0' "$(cat "$live_dir/rc")"
assert_eq 'q leaves the alternate screen' '0' "$(live_fmt live-host '#{alternate_on}')"
assert_eq 'q restores the cursor' '1' "$(live_fmt live-host '#{cursor_flag}')"
assert_eq 'q restores the tty modes exactly' "$(cat "$live_dir/stty.before")" "$(cat "$live_dir/stty.after")"
assert_contains 'the terminal is back as it was' "$(live_pane live-host)" 'NORMAL-SCREEN-MARKER'
assert_contains 'control returns to the caller' "$(live_pane live-host)" 'LIVE-VIEW-RETURNED'
assert_eq 'the live view leaves no process behind' \
  "$(cat "$live_dir/kids.before")" "$(cat "$live_dir/kids.after")"
tmux_ kill-session -t '=live-host'

# Ctrl-C is the other way out, and must clean up just as completely.
live_start live-int
assert_true 'the live view paints before the interrupt' live_wait live-int 'live · q quit'
assert_eq 'the interrupt case starts on the alternate screen' '1' "$(live_fmt live-int '#{alternate_on}')"
tmux_ send-keys -t '=live-int:' C-c
assert_true 'Ctrl-C ends the live view' live_wait_file "$live_dir/rc"
assert_eq 'Ctrl-C exits 130' '130' "$(cat "$live_dir/rc")"
assert_eq 'Ctrl-C leaves the alternate screen' '0' "$(live_fmt live-int '#{alternate_on}')"
assert_eq 'Ctrl-C restores the cursor' '1' "$(live_fmt live-int '#{cursor_flag}')"
assert_eq 'Ctrl-C restores the tty modes exactly' "$(cat "$live_dir/stty.before")" "$(cat "$live_dir/stty.after")"
assert_contains 'Ctrl-C hands the terminal back' "$(live_pane live-int)" 'LIVE-VIEW-RETURNED'
assert_eq 'Ctrl-C leaves no process behind' \
  "$(cat "$live_dir/kids.before")" "$(cat "$live_dir/kids.after")"
tmux_ kill-session -t '=live-int'
reset_server

# ---------------------------------------------------------------------------
print -r -- ""
if (( TCD_TESTS_FAILED )); then
  print -u2 -r -- "FAILED: $TCD_TESTS_FAILED of $TCD_TESTS_RUN assertions"
  exit 1
fi
print -r -- "PASS: $TCD_TESTS_RUN assertions"
exit 0
