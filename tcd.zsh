# tcd — tmux convenience for running AI CLIs in named, restorable sessions.
# Source this from your ~/.zshrc:   source /path/to/tcd/tcd.zsh
#
# Requires: zsh + tmux. The claude()/codex() wrappers are optional and only
# kick in if those CLIs are installed.

# ---------------------------------------------------------------------------
# AI CLIs: run from named tmux sessions when launched normally.
# ---------------------------------------------------------------------------

# Derive a stable session name from the current project (repo root, else PWD).
_ai_tmux_project_session_name() {
  local program="$1"
  local project_dir
  project_dir="$(git rev-parse --show-toplevel 2>/dev/null || print -r -- "$PWD")"
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

# Launch $program inside a named tmux session (or just run it if already in tmux
# or tmux is unavailable).
_ai_tmux_session() {
  local session_name="$1"
  local program="$2"
  shift 2

  if [[ -n "${TMUX:-}" ]]; then
    command "$program" "$@"
    return
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    command "$program" "$@"
    return
  fi

  local cmdline="${(q)program}"
  local arg
  for arg in "$@"; do
    cmdline+=" ${(q)arg}"
  done

  tmux new-session -A -s "$session_name" "$cmdline"
}

# Wrap `claude` so it always runs in a per-project tmux session.
# Also rewrites the convenience flag `--yolo` -> `--dangerously-skip-permissions`.
if command -v claude >/dev/null 2>&1; then
  claude() {
    local args=()
    local a
    for a in "$@"; do
      if [[ "$a" == "--yolo" ]]; then
        args+=("--dangerously-skip-permissions")
      else
        args+=("$a")
      fi
    done
    _ai_tmux_session "$(_ai_tmux_project_session_name claude)" claude "${args[@]}"
  }
fi

# Wrap `codex` the same way.
if command -v codex >/dev/null 2>&1; then
  codex() {
    _ai_tmux_session "$(_ai_tmux_project_session_name codex)" codex "$@"
  }
fi

# ---------------------------------------------------------------------------
# tcd [partial]: no arg -> list sessions; with arg -> attach to the first
# session whose name contains <partial> (case-insensitive). Easy on a phone:
# `tcd zer` instead of `tmux attach -t ZER-259-claude-579067`.
# Listing sorts attached sessions (marked ▸) first, then detached; each row is
# marker, name, window count, created time.
#
# tcd close: the mirror image of attaching — kill sessions by partial name
# instead of memorizing the full one.
#   tcd close            -> close the session you're currently in (inside tmux)
#   tcd close <partial>  -> close every session whose name contains <partial>
#   tcd close all        -> close every session
# Closing is destructive (it kills the session's processes, e.g. claude/codex),
# so it lists what it's about to kill and asks for confirmation; pass -y/-f to
# skip the prompt. `kill`, `rm`, and `x` are accepted as aliases for `close`.
# ---------------------------------------------------------------------------
_tcd_list() {
  tmux ls -F $'#{?session_attached,0,1}\t#{?session_attached,▸ ,  }#{session_name}\t#{session_windows} win\t#{t/f/%b %d %H#:%M:session_created}' 2>/dev/null \
    | sort -t $'\t' -k1,1n -k2,2 \
    | cut -f2- \
    | column -t -s $'\t'
}

_tcd_close() {
  if ! command -v tmux >/dev/null 2>&1; then
    print -r -- "tcd close: tmux not found"
    return 1
  fi

  local force=0
  local -a targets=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes|-f|--force) force=1 ;;
      *) targets+=("$arg") ;;
    esac
  done

  local -a to_close=()
  if [[ ${#targets[@]} -eq 0 ]]; then
    # No target: close the session this shell is attached to.
    if [[ -z "${TMUX:-}" ]]; then
      print -r -- "tcd close: not inside a tmux session — say which to close, e.g. 'tcd close zer' or 'tcd close all'"
      _tcd_list
      return 1
    fi
    to_close=("$(tmux display-message -p '#{session_name}')")
  elif [[ "${targets[1]}" == "all" ]]; then
    local all
    all="$(tmux ls -F '#{session_name}' 2>/dev/null)"
    [[ -n "$all" ]] && to_close=("${(@f)all}")
  else
    # Close every session matching the partial (the symmetric counterpart of
    # attach picking the first match — clearing a project's agents at once).
    local matches
    matches="$(tmux ls -F '#{session_name}' 2>/dev/null | grep -iF -- "${targets[1]}")"
    [[ -n "$matches" ]] && to_close=("${(@f)matches}")
    if [[ ${#to_close[@]} -eq 0 ]]; then
      print -r -- "no tmux session matching: ${targets[1]}"
      _tcd_list
      return 1
    fi
  fi

  if [[ ${#to_close[@]} -eq 0 ]]; then
    print -r -- "no tmux sessions to close"
    return 1
  fi

  if [[ $force -ne 1 ]]; then
    print -r -- "close ${#to_close[@]} session(s): ${(j:, :)to_close}"
    local reply
    if ! read -q "reply?proceed? [y/N] "; then
      print -r -- $'\naborted'
      return 1
    fi
    print
  fi

  local s rc=0
  for s in "${to_close[@]}"; do
    if tmux kill-session -t "=$s" 2>/dev/null; then
      print -r -- "closed: $s"
    else
      print -r -- "failed to close: $s"
      rc=1
    fi
  done
  return $rc
}

tcd() {
  if [[ -z "${1:-}" ]]; then
    _tcd_list
    return
  fi
  case "$1" in
    close|kill|rm|x)
      shift
      _tcd_close "$@"
      return
      ;;
  esac
  local match
  match="$(tmux ls -F '#{session_name}' 2>/dev/null | grep -iF -- "$1" | head -1)"
  if [[ -z "$match" ]]; then
    print -r -- "no tmux session matching: $1"
    _tcd_list
    return 1
  fi
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "=$match"
  else
    tmux attach -t "=$match"
  fi
}
