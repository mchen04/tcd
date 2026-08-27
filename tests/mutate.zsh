#!/usr/bin/env zsh
# Proof that the suite can fail. Each mutation breaks one behaviour in a copy
# of tcd.zsh; the suite must then fail. A mutation the suite does not catch is
# reported as a gap, and the script exits 1.
#
#   zsh tests/mutate.zsh
set -u
repo="${${(%):-%x}:A:h:h}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tcd-mutate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

typeset -a mutations=(
  # label | sed expression (applied to a copy of tcd.zsh)
  'private socket routing follows inherited TMUX|s/command tmux -S "$TCD_TMUX_SOCKET" "$@"/command tmux "$@"/'
  'close skips the y/N prompt by default|s/local force=0/local force=1/'
  'row numbers never resolve|s/^_tcd_nth() {/_tcd_nth() { return 1;/'
  'agent detection always says idle|s/^_tcd_classify() {/_tcd_classify() { return 1;/'
  'long names are not truncated|s/(( namewidth > maxname )) \&\& namewidth=\$maxname//'
  'host names are never recognised|s/^_tcd_is_host() {/_tcd_is_host() { return 1;/'
  'login listing is on by default|s/\${TCD_LOGIN_LIST:-0}/${TCD_LOGIN_LIST:-1}/'
  'ambiguous projects guess the first hit|s/hits=( "\${sub\[@\]}" )/hits=( ${sub[@][1,1]} )/'
  'deep project folders are not searched|s/TCD_PROJECT_DEPTH:=3/TCD_PROJECT_DEPTH:=2/'
  'cl starts a duplicate instead of attaching|s/if _tcd_tmux has-session -t "=\$name" 2>\/dev\/null; then/if false; then/'
  '--yolo is no longer rewritten|s/\[\[ "\$a" == "--yolo" \]\]/[[ "$a" == "--never" ]]/'
  'ssh failures lose their hint|s/(( rc == 255 ))/(( rc == -1 ))/'
  'a surviving session is reported closed|s/print -r -- "failed to close: \$s"/print -r -- "closed: $s"/'
  # --live
  'the live view draws one frame and stops|s/while (( _TCD_LIVE_STOP == 0 )); do/while false; do/'
  'the live view never repaints after the first frame|s/^    _tcd_live_draw "\$(_tcd_live_frame)"$/    [[ -n "${_tcd_drawn:-}" ]] || _tcd_live_draw "$(_tcd_live_frame)"; _tcd_drawn=1/'
  'the live table drifts from the real listing|s/body="\$(_tcd_list)" || rc=\$?/body="$(_tcd_rows)" || rc=$?/'
  'live frames are not clamped to the terminal|s/(( \${#out} > avail )); then/(( 0 )); then/'
  'the redraw clears the screen every frame|s/local out=\$'"'"'\\e\[H'"'"' i/local out=$'"'"'\\e[2J\\e[H'"'"' i/'
  'the redraw leaves a trailing newline|s/print -rn -- "\$out"\$'"'"'\\e\[J'"'"'/print -r -- "$out"$'"'"'\\e[J'"'"'/'
  'the live view never leaves the alternate screen|s/print -rn -- \$'"'"'\\e\[?25h\\e\[?1049l'"'"'//'
  'the live view never restores the tty modes|s/command stty "\$_TCD_LIVE_TTY" 2>\/dev\/null/true/'
  'Ctrl-C is not caught|s/trap '"'"'_TCD_LIVE_STOP=2'"'"' INT//'
  'q does not quit|s/        q|Q)     break ;;//'
  'a zero refresh interval is accepted|s/(( s < 0.2 )) \&\& s=0.2//'
  'tcd --live is not wired up|s/^    --live)           _tcd_live; return ;;$//'
)

gaps=0 n=0
for m in "${mutations[@]}"; do
  label="${m%%|*}"; expr="${m#*|}"
  (( n++ ))
  cp "$repo/tcd.zsh" "$tmp/tcd.zsh"
  sed -i '' -e "$expr" "$tmp/tcd.zsh"
  if cmp -s "$repo/tcd.zsh" "$tmp/tcd.zsh"; then
    print -r -- "  GAP  $label  (mutation did not apply: $expr)"
    (( gaps++ )); continue
  fi
  if TCD_LIB_FILE="$tmp/tcd.zsh" zsh "$repo/tests/run.zsh" >"$tmp/out" 2>&1; then
    print -r -- "  GAP  $label  (suite still passes)"
    (( gaps++ ))
  else
    print -r -- "  ok   suite fails when: $label  ($(grep -c '^  FAIL' "$tmp/out") failing)"
  fi
done

print
if (( gaps )); then print -r -- "GAPS: $gaps of $n mutations survived"; exit 1; fi
print -r -- "PASS: all $n mutations caught"
