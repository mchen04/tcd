# tcd — tmux convenience for running AI CLIs in named, restorable sessions,
# built to be driven from a phone: short commands, numbered lists, narrow output.
# Source this from your ~/.zshrc:   source /path/to/tcd/tcd.zsh
#
# Requires: zsh + tmux. The claude()/codex() wrappers are optional and only
# kick in if those CLIs are installed.
#
# Optional config, sourced if present: ~/.config/tcd/config.zsh
#   TCD_HOSTS=(mini mbp)          ssh hosts reachable as `tcd @mini` / `tcd mini`
#   TCD_PROJECT_DIRS=(~/Projects) where `tcd cl <proj>` looks for project folders
#   TCD_REMOTE=ssh                or mosh: how `tcd @host` connects
#   TCD_LOGIN_LIST=1              list sessions when an ssh login lands in a shell

zmodload zsh/datetime 2>/dev/null

typeset -ga TCD_HOSTS TCD_PROJECT_DIRS
(( ${#TCD_PROJECT_DIRS} )) || TCD_PROJECT_DIRS=( "$HOME/Projects" )
: ${TCD_REMOTE:=ssh}
: ${TCD_PROJECT_DEPTH:=3}

_tcd_config_file="${XDG_CONFIG_HOME:-$HOME/.config}/tcd/config.zsh"
[[ -r "$_tcd_config_file" ]] && source "$_tcd_config_file"

# Every tmux call in this file goes through this one function. Production talks
# to the default server; the test suite overrides _tcd_tmux to point at a
# private -S socket, which is the only reason the tests can be trusted not to
# kill the caller's sessions. `command` skips any user alias or function named
# tmux.
_tcd_tmux() { command tmux "$@" }

_tcd_have_tmux() { command -v tmux >/dev/null 2>&1 }

# Is a real executable (not a wrapper function) on PATH?
_tcd_have_bin() { whence -p "$1" >/dev/null 2>&1 }

# All session names, one per line. Returns 1 when there is no server or no
# session, so callers can branch without inspecting output.
_tcd_names() {
  local raw
  raw="$(_tcd_tmux ls -F '#{session_name}' 2>/dev/null)" || true
  [[ -n "$raw" ]] || return 1
  print -r -- "$raw"
}

# ---------------------------------------------------------------------------
# AI CLIs: run from named tmux sessions when launched normally.
# ---------------------------------------------------------------------------

# Derive a stable session name from a project (repo root, else the dir itself).
# Defaults to the current directory.
_ai_tmux_project_session_name() {
  local program="$1" dir="${2:-$PWD}"
  local project_dir
  project_dir="$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || print -r -- "${dir:A}")"
  local project="${project_dir:t}"

  if [[ -z "$project" ]]; then
    project="${USER:-home}"
  fi

  project="${project//[^A-Za-z0-9_.-]/-}"

  # Disambiguate repos that share a folder name (e.g. ~/LoLdle vs ~/Downloads/LoLdle)
  # by appending a short hash of the full path. Without this, `tmux new-session -A`
  # attaches a second terminal to the first repo's session instead of starting fresh.
  local path_hash
  path_hash="$(print -r -- "$project_dir" | cksum)"
  path_hash="${path_hash%% *}"
  path_hash="${path_hash: -6}"
  print -r -- "${project}-${program}-${path_hash}"
}

# Build a shell command line from argv, preserving every argument exactly.
_tcd_cmdline() {
  local out="${(q)1}" arg
  shift
  for arg in "$@"; do out+=" ${(q)arg}"; done
  print -r -- "$out"
}

# Launch $program inside a named tmux session (or just run it if already in tmux
# or tmux is unavailable).
_ai_tmux_session() {
  local session_name="$1"
  local program="$2"
  shift 2

  if [[ -n "${TMUX:-}" ]] || ! _tcd_have_tmux; then
    command "$program" "$@"
    return
  fi

  _tcd_tmux new-session -A -s "$session_name" "$(_tcd_cmdline "$program" "$@")"
}

# Rewrite the convenience flag `--yolo` -> `--dangerously-skip-permissions`.
_tcd_claude_args() {
  local a
  for a in "$@"; do
    if [[ "$a" == "--yolo" ]]; then
      print -r -- "--dangerously-skip-permissions"
    else
      print -r -- "$a"
    fi
  done
}

# Wrap `claude` so it always runs in a per-project tmux session.
if _tcd_have_bin claude; then
  claude() {
    local -a args=( ${(f)"$(_tcd_claude_args "$@")"} )
    _ai_tmux_session "$(_ai_tmux_project_session_name claude)" claude "${args[@]}"
  }
fi

# Wrap `codex` the same way.
if _tcd_have_bin codex; then
  codex() {
    _ai_tmux_session "$(_ai_tmux_project_session_name codex)" codex "$@"
  }
fi

# ---------------------------------------------------------------------------
# Listing. One tmux call plus one `ps` call, formatted with zsh builtins to fit
# a phone-width terminal:
#
#    1 ▸ ZER-309-codex-309061   codex   3m
#    2   tcd-claude-579067      idle    2h
#
# The number is stable for as long as the set of sessions does not change, so
# `tcd 2` attaches to row 2. Status is the agent actually running in the
# session (claude/codex/other command) or `idle` when only a shell is left.
# ---------------------------------------------------------------------------

# Terminal width: honour COLUMNS, fall back to tput, then 80.
_tcd_cols() {
  local c="${COLUMNS:-}"
  [[ "$c" == <1-> ]] || c="$(tput cols 2>/dev/null)"
  [[ "$c" == <1-> ]] || c=80
  print -r -- "$c"
}

# Compact relative age: 45s, 12m, 3h, 2d.
_tcd_age() {
  local then="$1" now="${2:-$EPOCHSECONDS}" d
  [[ "$then" == <0-> ]] || { print -r -- '?'; return }
  (( d = now - then ))
  (( d < 0 )) && d=0
  if   (( d < 60 ));     then print -r -- "${d}s"
  elif (( d < 3600 ));   then print -r -- "$(( d / 60 ))m"
  elif (( d < 86400 ));  then print -r -- "$(( d / 3600 ))h"
  else                        print -r -- "$(( d / 86400 ))d"
  fi
}

# Process tree snapshot for agent detection. Claude's native binary shows up in
# tmux as its version number ("2.1.241") and Codex as "node", so
# pane_current_command alone cannot tell what an agent session is running.
typeset -gA _TCD_PS_CHILDREN _TCD_PS_ARGS
_tcd_ps_scan() {
  _TCD_PS_CHILDREN=() _TCD_PS_ARGS=()
  local line pid ppid args
  for line in ${(f)"$(command ps -axo pid=,ppid=,args= 2>/dev/null)"}; do
    line="${line## #}"
    pid="${line%% *}";  line="${line#* }"; line="${line## #}"
    ppid="${line%% *}"; args="${line#* }"
    [[ "$pid" == <0-> && "$ppid" == <0-> ]] || continue
    _TCD_PS_ARGS[$pid]="$args"
    _TCD_PS_CHILDREN[$ppid]+="$pid "
  done
}

# Classify one command line as claude / codex; returns 1 for anything else.
# Looks at the first two words so both "claude --yolo" and
# "node /.../bin/codex --yolo" (or "/bin/sh /.../bin/claude") are recognised.
_tcd_classify() {
  local -a toks=( ${=1} )
  local t
  for t in "${(@)toks[1,2]}"; do
    case "${t:t}" in
      claude|<0->.<0->.<0->*) print -r -- claude; return 0 ;;
      codex) print -r -- codex; return 0 ;;
    esac
    [[ "$t" == *claude/versions/* ]] && { print -r -- claude; return 0 }
  done
  return 1
}

# What is the pane running? The pane process itself (an exec'd agent), then
# up to three levels of descendants.
_tcd_agent_of_pid() {
  local pid="$1" depth="${2:-0}" c prog
  (( depth > 3 )) && return 1
  if (( depth == 0 )) && prog="$(_tcd_classify "${_TCD_PS_ARGS[$pid]:-}")"; then print -r -- "$prog"; return 0; fi
  for c in ${=${_TCD_PS_CHILDREN[$pid]:-}}; do
    if prog="$(_tcd_classify "${_TCD_PS_ARGS[$c]}")"; then print -r -- "$prog"; return 0; fi
    if prog="$(_tcd_agent_of_pid "$c" $(( depth + 1 )))"; then print -r -- "$prog"; return 0; fi
  done
  return 1
}

# Session status from its start command, then the live process tree, then the
# foreground command. Shells mean nothing is running: `idle`.
_tcd_status() {
  local start="$1" current="$2" pid="$3" prog
  prog="$(_tcd_classify "${start//\"/}")" 2>/dev/null && { print -r -- "$prog"; return }
  (( ${+_TCD_PS_ARGS[$pid]} )) && prog="$(_tcd_agent_of_pid "$pid")" && { print -r -- "$prog"; return }
  case "$current" in
    ''|zsh|bash|sh|fish|-zsh|-bash|login) print -r -- idle ;;
    *) _tcd_classify "$current" 2>/dev/null || print -r -- "${current:t}" ;;
  esac
}

# Ordered session rows, one per line: name<TAB>attached<TAB>status<TAB>age<TAB>windows.
# Attached sessions first, then case-insensitive by name. This is the single
# source of truth for row numbers.
_tcd_rows() {
  local raw
  raw="$(_tcd_tmux ls -F $'#{?session_attached,0,1}\t#{session_windows}\t#{session_activity}\t#{pane_pid}\t#{pane_current_command}\t#{pane_start_command}\t#{session_name}' 2>/dev/null)" || true
  [[ -n "$raw" ]] || return 1

  _tcd_ps_scan
  local -A rows=()
  local line flag windows activity pid current start name rest
  for line in ${(f)raw}; do
    flag="${line%%$'\t'*}";     rest="${line#*$'\t'}"
    windows="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    activity="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    pid="${rest%%$'\t'*}";      rest="${rest#*$'\t'}"
    current="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
    start="${rest%%$'\t'*}"
    # The name is last so a tab inside the start command cannot shift it; it
    # follows the known count of leading fields.
    name="${line#*$'\t'*$'\t'*$'\t'*$'\t'*$'\t'*$'\t'}"
    rows[${flag}${(L)name}]="${name}"$'\t'"${flag}"$'\t'"$(_tcd_status "$start" "$current" "$pid")"$'\t'"$(_tcd_age "$activity")"$'\t'"${windows}"
  done
  local key
  for key in ${(ko)rows}; do print -r -- "${rows[$key]}"; done
}

_tcd_list() {
  local rows
  if ! rows="$(_tcd_rows)"; then
    print -r -- "no tmux sessions"
    print -r -- "start one:  tcd cl <project>   (claude)   tcd co <project>   (codex)"
    return 1
  fi

  local -a names=() marks=() stats=() ages=()
  local line name flag state age windows namewidth=0 statwidth=4
  for line in ${(f)rows}; do
    name="${line%%$'\t'*}";   line="${line#*$'\t'}"
    flag="${line%%$'\t'*}";   line="${line#*$'\t'}"
    state="${line%%$'\t'*}"; line="${line#*$'\t'}"
    age="${line%%$'\t'*}";    windows="${line#*$'\t'}"
    (( windows > 1 )) && state+=" ${windows}w"
    names+=( "$name" ); marks+=( "${${flag/0/▸}/1/ }" ); stats+=( "$state" ); ages+=( "$age" )
    (( ${#name}   > namewidth )) && namewidth=${#name}
    (( ${#status} > statwidth )) && statwidth=${#status}
  done

  # Fit the row in the terminal: "NN M NAME  STATUS  AGE". Truncate the name
  # with an ellipsis rather than wrapping, which is unreadable on a phone.
  local cols fixed maxname
  cols="$(_tcd_cols)"
  (( fixed = 2 + 1 + 1 + 1 + 2 + statwidth + 2 + 3 ))
  (( maxname = cols - fixed ))
  (( maxname < 8 )) && maxname=8
  (( namewidth > maxname )) && namewidth=$maxname

  local i shown
  for (( i = 1; i <= ${#names}; i++ )); do
    shown="$names[i]"
    (( ${#shown} > namewidth )) && shown="${shown[1,namewidth-1]}…"
    printf '%2d %s %-*s  %-*s  %s\n' "$i" "$marks[i]" "$namewidth" "$shown" "$statwidth" "$stats[i]" "$ages[i]"
  done
}

# ---------------------------------------------------------------------------
# Matching.
# ---------------------------------------------------------------------------

# Session name for row number N of the listing, or failure.
_tcd_nth() {
  local n="$1" rows i=0 line
  [[ "$n" == <1-> ]] || return 1
  rows="$(_tcd_rows)" || return 1
  for line in ${(f)rows}; do
    (( ++i == n )) && { print -r -- "${line%%$'\t'*}"; return 0 }
  done
  return 1
}

# Best single match for a partial name, printed on stdout; returns 1 for none.
# Matching is literal (never a regex) because session names contain [ and ].
# Order: exact name, exact case-insensitive name, row number, then the first
# case-insensitive substring hit. A session whose name is a prefix of another
# therefore stays reachable by typing it in full.
_tcd_match() {
  local needle="$1" lneedle="${1:l}" raw n
  raw="$(_tcd_names)" || return 1
  local -a names=( ${(f)raw} )

  for n in $names; do [[ "$n" == "$needle" ]]          && { print -r -- "$n"; return 0 } done
  for n in $names; do [[ "${n:l}" == "$lneedle" ]]     && { print -r -- "$n"; return 0 } done
  [[ "$needle" == <1-> ]] && _tcd_nth "$needle" && return 0
  for n in $names; do [[ "${n:l}" == *"$lneedle"* ]]   && { print -r -- "$n"; return 0 } done
  return 1
}

# Every session matching a partial, for `tcd close`. A row number selects
# exactly that row.
_tcd_match_all() {
  local lneedle="${1:l}" raw n
  raw="$(_tcd_names)" || return 1
  local -a out=()
  for n in ${(f)raw}; do [[ "$n" == "$1" ]] && { print -r -- "$n"; return 0 } done
  [[ "$1" == <1-> ]] && _tcd_nth "$1" && return 0
  for n in ${(f)raw}; do [[ "${n:l}" == *"$lneedle"* ]] && out+=( "$n" ); done
  (( ${#out} )) || return 1
  print -rl -- "${out[@]}"
}

# The client-facing half of attach, kept separate so tests can exercise
# matching without replacing the terminal's tmux client.
# Switching to the session you are already in is a no-op in tmux, so the
# already-here case needs no special handling.
_tcd_attach() {
  if [[ -n "${TMUX:-}" ]]; then
    _tcd_tmux switch-client -t "=$1"
  else
    _tcd_tmux attach -t "=$1"
  fi
}

_tcd_last() {
  if [[ -n "${TMUX:-}" ]]; then
    _tcd_tmux switch-client -l 2>/dev/null && return 0
  else
    _tcd_tmux attach 2>/dev/null && return 0
  fi
  print -r -- "tcd: no previous session"
  return 1
}

# ---------------------------------------------------------------------------
# Starting agents: `tcd cl [project] [args...]`, `tcd co [project] [args...]`.
#
# The project is a path, or a partial folder name searched under
# TCD_PROJECT_DIRS (exact basename wins, then case-insensitive substring). With
# no project the current directory is used. If that project already has a
# session for the program, you are attached to it instead of starting a second
# agent; args are then ignored and you are told so.
# ---------------------------------------------------------------------------

# Candidate project directories, one per line.
_tcd_project_dirs() {
  local root
  local -a found=()
  for root in "${TCD_PROJECT_DIRS[@]}"; do
    root="${~root}"
    [[ -d "$root" ]] || continue
    found+=( "$root" )
    found+=( "$root"/*(/N) )
    (( TCD_PROJECT_DEPTH >= 2 )) && found+=( "$root"/*/*(/N) )
    (( TCD_PROJECT_DEPTH >= 3 )) && found+=( "$root"/*/*/*(/N) )
  done
  (( ${#found} )) || return 1
  print -rl -- "${found[@]}"
}

# Resolve a project argument to a directory. Prints the directory; on an
# ambiguous partial prints the candidates to stderr and returns 2; on no match
# returns 1.
_tcd_find_project() {
  local q="$1" lq="${1:l}" dirs d
  [[ -z "$q" ]] && { print -r -- "$PWD"; return 0 }
  [[ -d "${~q}" ]] && { print -r -- "${${~q}:A}"; return 0 }

  dirs="$(_tcd_project_dirs)" || return 1
  local -a exact=() sub=()
  for d in ${(f)dirs}; do
    [[ "${d:t}" == "$q" ]] && exact+=( "$d" )
    [[ "${d:t:l}" == "$lq" ]] && exact+=( "$d" )
    [[ "${d:t:l}" == *"$lq"* ]] && sub+=( "$d" )
  done
  exact=( ${(u)exact} ); sub=( ${(u)sub} )
  (( ${#exact} == 1 )) && { print -r -- "${exact[1]}"; return 0 }
  (( ${#exact} == 0 && ${#sub} == 1 )) && { print -r -- "${sub[1]}"; return 0 }
  # Several exact hits: prefer the shallowest when it is alone at that depth.
  # Several substring hits are always ambiguous; guessing would start an
  # agent in the wrong repo.
  local -a hits=( "${exact[@]}" )
  if (( ${#hits} )); then
    local -a shallow=()
    local mindepth=999 depth
    for d in "${hits[@]}"; do depth=${#${(s:/:)d}}; (( depth < mindepth )) && mindepth=$depth; done
    for d in "${hits[@]}"; do (( ${#${(s:/:)d}} == mindepth )) && shallow+=( "$d" ); done
    (( ${#shallow} == 1 )) && { print -r -- "${shallow[1]}"; return 0 }
  else
    hits=( "${sub[@]}" )
  fi
  (( ${#hits} == 0 )) && return 1
  print -u2 -r -- "tcd: '$q' matches several projects:"
  for d in "${hits[@]}"; do print -u2 -r -- "  ${d/#$HOME/~}"; done
  return 2
}

# Start (or attach to) a program's session for a project directory.
_tcd_launch() {
  local program="$1" dir="$2"; shift 2
  local name
  name="$(_ai_tmux_project_session_name "$program" "$dir")"

  if _tcd_tmux has-session -t "=$name" 2>/dev/null; then
    (( $# )) && print -r -- "tcd: $name is already running; attaching (args ignored)"
    _tcd_attach "$name"
    return
  fi

  local cmdline
  cmdline="$(_tcd_cmdline "$program" "$@")"
  if [[ -n "${TMUX:-}" ]]; then
    _tcd_tmux new-session -d -s "$name" -c "$dir" "$cmdline" && _tcd_tmux switch-client -t "=$name"
  else
    _tcd_tmux new-session -s "$name" -c "$dir" "$cmdline"
  fi
}

# tcd cl/co front door. First arg is the project unless it starts with '-'.
_tcd_agent() {
  local program="$1"; shift
  if ! _tcd_have_bin "$program"; then
    print -u2 -r -- "tcd: $program is not installed on this machine"
    return 1
  fi
  local proj='' dir rc
  if (( $# )) && [[ "$1" != -* ]]; then proj="$1"; shift; fi

  if [[ -n "$proj" ]]; then
    dir="$(_tcd_find_project "$proj")"; rc=$?
    if (( rc == 2 )); then
      return 2
    elif (( rc != 0 )); then
      # Not a folder: maybe it names an existing session for this program.
      local sess
      if sess="$(_tcd_match "$proj")" && [[ "$sess" == *-${program}-* ]]; then
        _tcd_attach "$sess"
        return
      fi
      print -u2 -r -- "tcd: no project or session matching '$proj'"
      print -u2 -r -- "looked under: ${(j:, :)${TCD_PROJECT_DIRS[@]/#$HOME/~}}"
      return 1
    fi
  else
    dir="$PWD"
  fi

  local -a args=( "$@" )
  [[ "$program" == claude ]] && args=( ${(f)"$(_tcd_claude_args "$@")"} )
  _tcd_launch "$program" "$dir" "${args[@]}"
}

# ---------------------------------------------------------------------------
# Remote Macs: `tcd @mini`, `tcd @mini 2`, `tcd @mini cl proj`, `tcd @mini close 3`.
# Runs the same tcd command on the host over ssh (or mosh) in a login shell,
# so the remote needs tcd sourced from its ~/.zshrc. A host name from
# TCD_HOSTS also works without the @ when it is not a local session name.
# ---------------------------------------------------------------------------

_tcd_is_host() {
  local h
  for h in "${TCD_HOSTS[@]}"; do [[ "$h" == "$1" ]] && return 0; done
  return 1
}

_tcd_remote() {
  local host="$1"; shift
  local cmd
  cmd="$(_tcd_cmdline tcd "$@")"
  local -a tty=()
  [[ -t 0 ]] && tty=( -t )
  case "$TCD_REMOTE" in
    mosh)
      command mosh "$host" -- zsh -lic "$cmd"
      ;;
    *)
      command ssh "${tty[@]}" -o ConnectTimeout=8 "$host" -- zsh -lic "${(q)cmd}"
      ;;
  esac
  local rc=$?
  if (( rc == 255 )); then
    print -u2 -r -- "tcd: could not reach $host (ssh exit 255)."
    print -u2 -r -- "  check: Tailscale on both ends, Remote Login on, the Mac awake. try: tcd hosts"
  fi
  return $rc
}

_tcd_hosts() {
  if (( ${#TCD_HOSTS} == 0 )); then
    print -r -- "no hosts configured. add to ${_tcd_config_file/#$HOME/~}:"
    print -r -- "  TCD_HOSTS=(mini mbp)"
    return 1
  fi
  local h
  for h in "${TCD_HOSTS[@]}"; do
    if command ssh -o BatchMode=yes -o ConnectTimeout=4 "$h" -- true 2>/dev/null; then
      printf '%-12s up\n' "$h"
    else
      printf '%-12s unreachable\n' "$h"
    fi
  done
}

# ---------------------------------------------------------------------------
# Closing. Destructive: it kills the session's processes (claude/codex), so it
# lists what it is about to kill, with what each is running, and asks for a
# one-key confirmation. -y/-f skips the prompt; there is no default that skips it.
# ---------------------------------------------------------------------------
_tcd_close() {
  local force=0
  local -a targets=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes|-f|--force) force=1 ;;
      *) targets+=( "$arg" ) ;;
    esac
  done

  local -a to_close=()
  if (( ${#targets} == 0 )); then
    # No target: close the session this shell is attached to.
    if [[ -z "${TMUX:-}" ]]; then
      print -r -- "tcd close: not inside a tmux session — say which to close, e.g. 'tcd close 2', 'tcd close zer' or 'tcd close all'"
      _tcd_list
      return 1
    fi
    local self
    self="$(_tcd_tmux display-message -p '#{session_name}' 2>/dev/null)" || true
    if [[ -z "$self" ]]; then
      print -r -- "tcd close: could not determine the current session"
      return 1
    fi
    to_close=( "$self" )
  elif [[ "${targets[1]}" == "all" ]]; then
    local raw
    raw="$(_tcd_names)" || true
    [[ -n "$raw" ]] && to_close=( ${(f)raw} )
  else
    # Close every session matching each partial (the symmetric counterpart of
    # attach picking one — clearing a project's agents at once).
    local matches t
    for t in "${targets[@]}"; do
      if ! matches="$(_tcd_match_all "$t")"; then
        print -r -- "no tmux session matching: $t"
        _tcd_list
        return 1
      fi
      to_close+=( ${(f)matches} )
    done
    to_close=( ${(u)to_close} )
  fi

  if (( ${#to_close} == 0 )); then
    print -r -- "no tmux sessions to close"
    return 1
  fi

  if (( force != 1 )); then
    print -r -- "close ${#to_close} session(s):"
    local rows line name state
    rows="$(_tcd_rows)" || rows=''
    for name in $to_close; do
      state=''
      for line in ${(f)rows}; do
        [[ "${line%%$'\t'*}" == "$name" ]] || continue
        line="${line#*$'\t'*$'\t'}"; state="${line%%$'\t'*}"
      done
      printf '  %s%s\n' "$name" "${state:+  ($state)}"
    done
    local reply
    if ! read -q "reply?proceed? [y/N] "; then
      print -r -- $'\naborted'
      return 1
    fi
    print
  fi

  # One tmux invocation for the whole batch. Killing 500 sessions used to mean
  # 500 forks; a tmux command sequence makes it one.
  local -a cmd=()
  local s
  for s in $to_close; do
    (( ${#cmd} )) && cmd+=( ';' )
    cmd+=( kill-session -t "=$s" )
  done
  _tcd_tmux "${cmd[@]}" 2>/dev/null

  # Report per session from one follow-up query rather than trusting the
  # batch's aggregate exit status.
  local raw
  raw="$(_tcd_names)" || true
  local -A alive=()
  for s in ${(f)raw}; do [[ -n "$s" ]] && alive[$s]=1; done

  local rc=0
  for s in $to_close; do
    if (( ${+alive[$s]} )); then
      print -r -- "failed to close: $s"
      rc=1
    else
      print -r -- "closed: $s"
    fi
  done
  return $rc
}

# ---------------------------------------------------------------------------
# Doctor: one screen that says why something is not working.
# ---------------------------------------------------------------------------
_tcd_doctor() {
  local bad=0
  _tcd_check() {  # _tcd_check <ok|bad> <label> [hint]
    if [[ "$1" == ok ]]; then
      print -r -- "ok    $2"
    else
      print -r -- "FAIL  $2"; [[ -n "${3:-}" ]] && print -r -- "      $3"
      bad=1
    fi
  }
  local v
  if _tcd_have_tmux; then
    v="$(_tcd_tmux -V 2>/dev/null)"; _tcd_check ok "tmux ($v)"
  else
    _tcd_check bad "tmux not found" "brew install tmux"
  fi
  local p
  for p in claude codex; do
    if _tcd_have_bin "$p"; then _tcd_check ok "$p installed"
    else _tcd_check bad "$p not installed" "tcd $p[1,2] will not work on this machine"; fi
  done
  if command -v mosh >/dev/null 2>&1; then _tcd_check ok "mosh installed"
  else print -r -- "info  mosh not installed (optional; TCD_REMOTE=mosh needs it)"; fi

  local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
  if [[ -f "$zshrc" ]] && grep -qF 'tcd.zsh' "$zshrc"; then _tcd_check ok "~/.zshrc sources tcd.zsh"
  else _tcd_check bad "~/.zshrc does not source tcd.zsh" "run ./install.sh"; fi

  local conf="$HOME/.tmux.conf"
  if [[ -L "$conf" ]]; then _tcd_check ok "~/.tmux.conf -> $(readlink "$conf")"
  elif [[ -e "$conf" ]]; then print -r -- "info  ~/.tmux.conf is a regular file (not the tcd symlink)"
  else _tcd_check bad "~/.tmux.conf missing" "run ./install.sh"; fi
  [[ -d "$HOME/.tmux/plugins/tpm" ]] && _tcd_check ok "tpm installed" \
    || print -r -- "info  tpm not installed (optional; ./install.sh clones it)"

  if [[ -r "$_tcd_config_file" ]]; then _tcd_check ok "config ${_tcd_config_file/#$HOME/~}"
  else print -r -- "info  no config at ${_tcd_config_file/#$HOME/~} (hosts/project dirs use defaults)"; fi

  local d
  for d in "${TCD_PROJECT_DIRS[@]}"; do
    [[ -d "${~d}" ]] && _tcd_check ok "project dir ${d/#$HOME/~}" || _tcd_check bad "project dir ${d/#$HOME/~} missing" "set TCD_PROJECT_DIRS in the config"
  done

  if (( ${#TCD_HOSTS} )); then
    print -r -- "hosts:"; _tcd_hosts | sed 's/^/      /'
  else
    print -r -- "info  no remote hosts (TCD_HOSTS is empty)"
  fi

  local n
  n="$(_tcd_names 2>/dev/null | wc -l | tr -d ' ')" || n=0
  print -r -- "info  ${n:-0} tmux session(s) on this machine"
  return $bad
}

_tcd_help() {
  print -r -- 'tcd — drive tmux agent sessions with short commands.

  tcd                  list sessions: number, ▸ if attached, status, age
  tcd <n>              attach to row n of the list
  tcd <partial>        attach to the best match (exact name wins, then substring)
  tcd -                attach to the previous session

  tcd cl [proj] [args] start or attach claude in a project  (--yolo ok)
  tcd co [proj] [args] start or attach codex in a project
                       proj = path, or part of a folder name under
                       TCD_PROJECT_DIRS (default ~/Projects); empty = here
                       resume last conversation: tcd cl proj -c

  tcd close            close the session you are in
  tcd close <n|part>.. close matching sessions (asks y/N; -y skips)
  tcd close all        close every session
                       kill, rm and x are aliases for close

  tcd @host [cmd...]   run any of the above on a remote Mac (ssh)
  tcd hosts            configured hosts and whether they answer
  tcd doctor           check the install and explain what is missing
  tcd help             this text'
}

tcd() {
  if ! _tcd_have_tmux; then
    print -u2 -r -- "tcd: tmux not found"
    return 1
  fi

  case "${1:-}" in
    '')               _tcd_list; return ;;
    ls|list)          _tcd_list; return ;;
    -h|--help|help)   _tcd_help; return ;;
    -)                _tcd_last; return ;;
    cl|claude)        shift; _tcd_agent claude "$@"; return ;;
    co|codex)         shift; _tcd_agent codex "$@"; return ;;
    close|kill|rm|x)  shift; _tcd_close "$@"; return ;;
    hosts)            _tcd_hosts; return ;;
    doctor)           _tcd_doctor; return ;;
    @?*)              local h="${1#@}"; shift; _tcd_remote "$h" "$@"; return ;;
  esac

  local match
  if match="$(_tcd_match "$1")"; then
    _tcd_attach "$match"
    return
  fi
  if _tcd_is_host "$1"; then
    local h="$1"; shift
    _tcd_remote "$h" "$@"
    return
  fi
  print -r -- "no tmux session matching: $1"
  _tcd_list
  return 1
}

# Phone logins: show the list as soon as an ssh shell opens (opt-in).
if [[ "${TCD_LOGIN_LIST:-0}" == 1 && -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -o interactive ]]; then
  tcd 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Completion: session names, subcommands, hosts, projects.
# ---------------------------------------------------------------------------
_tcd_completion() {
  local -a names
  names=( ${(f)"$(_tcd_names)"} )
  if (( CURRENT == 2 )); then
    compadd -a names
    compadd close kill rm x cl co hosts doctor help -
    (( ${#TCD_HOSTS} )) && compadd -- "${(@)TCD_HOSTS/#/@}"
  elif [[ "${words[2]}" == (close|kill|rm|x) ]]; then
    compadd -a names
    compadd all -y -f
  elif [[ "${words[2]}" == (cl|co|claude|codex) && CURRENT == 3 ]]; then
    local -a projs
    projs=( ${(f)"$(_tcd_project_dirs 2>/dev/null)"} )
    compadd -- "${(@)projs:t}"
  fi
}
(( ${+functions[compdef]} )) && compdef _tcd_completion tcd
