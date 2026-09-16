#!/usr/bin/env bash
#
# Claude Code statusline for Domovoy-Core.
#
# Reads the Status hook payload as JSON on stdin and prints two lines:
#
#   Domovoy-Core  branch  Opus 5 · xhigh · $1.84
#   ctx ━━╸╍╍╍╍╍╍╍ 26% 52k   5h ━━━━╍╍╍╍╍╍ 42% ·2h13m
#
# Row 1 is variable-length identity text and may safely truncate. Row 2 holds
# fixed-width meters, so a long branch name can never push them off-screen.
#
# Wired up by .claude/settings.json. See docs/statusline.md.
#
# Written for bash 3.2 (the macOS system bash): no associative arrays, no
# EPOCHSECONDS, no printf %()T, no ${var^^}.

set -uo pipefail
export LC_ALL=C

# --------------------------------------------------------------- appearance

BAR_WIDTH=10

# Box Drawing glyphs, all vertically centred on the text height. Swap these if
# your terminal font lacks any of them.
GLYPH_FULL='━'
GLYPH_HALF='╸'
GLYPH_EMPTY='╍'

# Utilisation thresholds (percent) for the colour ramp.
THRESHOLD_NOTICE=60
THRESHOLD_HIGH=80
THRESHOLD_CRITICAL=95

# Longest branch name shown on row 1 before it is shortened.
BRANCH_MAX=44

if [ -n "${NO_COLOR:-}" ]; then
  C_OK=''; C_NOTICE=''; C_HIGH=''; C_CRIT=''
  C_TRACK=''; C_LABEL=''; C_RESET=''
else
  C_OK=$'\033[38;5;71m'
  C_NOTICE=$'\033[38;5;179m'
  C_HIGH=$'\033[38;5;208m'
  C_CRIT=$'\033[1;38;5;203m'
  C_TRACK=$'\033[38;5;238m'
  C_LABEL=$'\033[38;5;245m'
  C_RESET=$'\033[0m'
fi

# Field separator for the jq handoff. Must not be space, tab or newline: bash
# treats runs of those as one delimiter, which would shift fields after an
# empty one.
US=$'\037'

# Wall clock, sampled once so a render never forks date more than once.
NOW=$(date +%s 2>/dev/null) || NOW=0
[ -n "$NOW" ] || NOW=0

# ------------------------------------------------------------------ helpers
#
# Percentages are carried as integer tenths (0-1000) so the bar keeps
# sub-percent accuracy. Helpers assign to a named global rather than echoing,
# to keep the render path free of subshell forks.

# severity_color <tenths> -> _color
severity_color() {
  local pct=$(( $1 / 10 ))
  if [ "$pct" -ge "$THRESHOLD_CRITICAL" ]; then
    _color=$C_CRIT
  elif [ "$pct" -ge "$THRESHOLD_HIGH" ]; then
    _color=$C_HIGH
  elif [ "$pct" -ge "$THRESHOLD_NOTICE" ]; then
    _color=$C_NOTICE
  else
    _color=$C_OK
  fi
}

# repeat <glyph> <count> -> _repeat
repeat() {
  local glyph=$1 count=$2
  _repeat=''
  while [ "$count" -gt 0 ]; do
    _repeat=$_repeat$glyph
    count=$(( count - 1 ))
  done
}

# bar <tenths> -> _bar
bar() {
  local tenths=$1 halves full half empty fill

  [ "$tenths" -lt 0 ] && tenths=0
  [ "$tenths" -gt 1000 ] && tenths=1000

  # Round to the nearest half cell.
  halves=$(( (tenths * BAR_WIDTH * 2 + 500) / 1000 ))
  full=$(( halves / 2 ))
  half=$(( halves % 2 ))
  empty=$(( BAR_WIDTH - full - half ))
  [ "$empty" -lt 0 ] && empty=0

  repeat "$GLYPH_FULL" "$full"
  fill=$_repeat
  [ "$half" -eq 1 ] && fill=$fill$GLYPH_HALF
  repeat "$GLYPH_EMPTY" "$empty"

  severity_color "$tenths"
  _bar="${_color}${fill}${C_TRACK}${_repeat}${C_RESET}"
}

# countdown <epoch_seconds> -> _countdown ('' when absent or already past)
countdown() {
  local target=${1:-} delta days hours mins
  _countdown=''
  case $target in
    ''|*[!0-9]*) return 0 ;;
  esac

  delta=$(( target - NOW ))
  [ "$delta" -le 0 ] && return 0

  days=$(( delta / 86400 ))
  hours=$(( (delta % 86400) / 3600 ))
  mins=$(( (delta % 3600) / 60 ))

  if [ "$days" -gt 0 ] && [ "$hours" -gt 0 ]; then
    printf -v _countdown '%dd%dh' "$days" "$hours"
  elif [ "$days" -gt 0 ]; then
    printf -v _countdown '%dd' "$days"
  elif [ "$hours" -gt 0 ]; then
    printf -v _countdown '%dh%02dm' "$hours" "$mins"
  elif [ "$mins" -gt 0 ]; then
    printf -v _countdown '%dm' "$mins"
  else
    _countdown='<1m'
  fi
}

# human_tokens <count> -> _tokens
human_tokens() {
  local n=${1:-}
  _tokens=''
  case $n in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$n" -eq 0 ] && return 0
  if [ "$n" -ge 1000000 ]; then
    printf -v _tokens '%d.%dM' $(( n / 1000000 )) $(( (n % 1000000) / 100000 ))
  elif [ "$n" -ge 1000 ]; then
    printf -v _tokens '%dk' $(( n / 1000 ))
  else
    _tokens=$n
  fi
}

# git_branch <dir> -> _branch
# Reads .git/HEAD directly rather than shelling out to git. Handles a linked
# worktree, where .git is a file holding "gitdir: <path>".
git_branch() {
  local dir=${1:-} git_dir line
  _branch=''
  [ -n "$dir" ] || return 0

  git_dir=$dir/.git
  if [ -f "$git_dir" ]; then
    IFS= read -r line < "$git_dir" || return 0
    git_dir=${line#gitdir: }
    case $git_dir in
      /*) ;;
      *) git_dir=$dir/$git_dir ;;
    esac
  fi

  [ -r "$git_dir/HEAD" ] || return 0
  IFS= read -r line < "$git_dir/HEAD" || return 0
  case $line in
    'ref: refs/heads/'*) _branch=${line#ref: refs/heads/} ;;
    ?*) _branch=${line:0:7} ;;
  esac
}

# shorten_branch <branch> -> _short_branch
# Keeps the whole name when it fits. Otherwise drops leading path segments,
# then truncates once a single segment is all that remains.
shorten_branch() {
  _short_branch=${1:-}
  while [ ${#_short_branch} -gt "$BRANCH_MAX" ]; do
    case $_short_branch in
      */*) _short_branch=${_short_branch#*/} ;;
      *) break ;;
    esac
  done
  if [ ${#_short_branch} -gt "$BRANCH_MAX" ]; then
    _short_branch=${_short_branch:0:$(( BRANCH_MAX - 1 ))}'…'
  fi
}

# meter <label> <tenths> <resets_at> <suffix> -> _meter
meter() {
  local label=$1 tenths=$2 resets_at=${3:-} suffix=${4:-} pct pct_text

  pct=$(( (tenths + 5) / 10 ))
  printf -v pct_text '%3d%%' "$pct"

  bar "$tenths"
  severity_color "$tenths"

  _meter="${C_LABEL}${label}${C_RESET} ${_bar} ${_color}${pct_text}${C_RESET}"
  [ -n "$suffix" ] && _meter="${_meter} ${C_LABEL}${suffix}${C_RESET}"

  countdown "$resets_at"
  [ -n "$_countdown" ] && _meter="${_meter} ${C_LABEL}·${_countdown}${C_RESET}"
}

# ------------------------------------------------------------------- render

# render_meters <ctx_tenths> <ctx_tokens> <5h_tenths> <5h_reset>
#               <7d_tenths> <7d_reset> <spend_tenths> <spend_reset> -> _row2
render_meters() {
  local ctx_tenths=$1 ctx_tokens=$2
  local five=$3 five_reset=$4 seven=$5 seven_reset=$6 spend=$7 spend_reset=$8
  local gap='   '

  human_tokens "$ctx_tokens"
  meter 'ctx' "$ctx_tenths" '' "$_tokens"
  _row2=$_meter

  if [ -n "$five" ]; then
    meter '5h' "$five" "$five_reset" ''
    _row2="${_row2}${gap}${_meter}"
  fi
  if [ -n "$seven" ]; then
    meter '7d' "$seven" "$seven_reset" ''
    _row2="${_row2}${gap}${_meter}"
  fi
  if [ -n "$spend" ]; then
    meter '$' "$spend" "$spend_reset" ''
    _row2="${_row2}${gap}${_meter}"
  fi

  if [ -z "$five" ] && [ -z "$seven" ] && [ -z "$spend" ]; then
    _row2="${_row2}${gap}${C_LABEL}limits n/a${C_RESET}"
  fi
}

# --------------------------------------------------------------------- demo

demo() {
  local levels='0 180 420 650 800 970 1000' t

  printf '%sglyphs%s  full %s   half %s   empty %s      %sbar width%s %s cells\n' \
    "$C_LABEL" "$C_RESET" "$GLYPH_FULL" "$GLYPH_HALF" "$GLYPH_EMPTY" \
    "$C_LABEL" "$C_RESET" "$BAR_WIDTH"
  printf '%sramp%s    <%s%% ok   >=%s%% notice   >=%s%% high   >=%s%% critical\n\n' \
    "$C_LABEL" "$C_RESET" "$THRESHOLD_NOTICE" "$THRESHOLD_NOTICE" \
    "$THRESHOLD_HIGH" "$THRESHOLD_CRITICAL"

  for t in $levels; do
    bar "$t"
    severity_color "$t"
    printf '  %s%4d%%%s  %s\n' "$_color" $(( (t + 5) / 10 )) "$C_RESET" "$_bar"
  done

  printf '\n%srow 2, as rendered:%s\n\n' "$C_LABEL" "$C_RESET"
  for t in $levels; do
    render_meters "$t" 52000 "$t" $(( NOW + 7980 )) "$t" $(( NOW + 273600 )) '' ''
    printf '  %s\n' "$_row2"
  done

  printf '\n%sno plan limits (API key / Bedrock / Vertex session):%s\n\n' "$C_LABEL" "$C_RESET"
  render_meters 260 52000 '' '' '' '' '' ''
  printf '  %s\n' "$_row2"

  printf '\n%swith a gateway spend limit:%s\n\n' "$C_LABEL" "$C_RESET"
  render_meters 260 52000 421 $(( NOW + 7980 )) 714 $(( NOW + 273600 )) 120 $(( NOW + 1555200 ))
  printf '  %s\n\n' "$_row2"
}

# --------------------------------------------------------------------- main

if [ "${1:-}" = '--demo' ]; then
  demo
  exit 0
fi

payload=$(cat)
project_dir=${CLAUDE_PROJECT_DIR:-$PWD}

if ! command -v jq >/dev/null 2>&1; then
  git_branch "$project_dir"
  shorten_branch "$_branch"
  row1=${project_dir##*/}
  [ -n "$_short_branch" ] && row1="${row1}  ${C_LABEL}⎇${C_RESET} ${_short_branch}"
  printf '%s  %sstatusline: jq not found%s\n' "$row1" "$C_LABEL" "$C_RESET"
  exit 0
fi

fields=$(
  printf '%s' "$payload" | jq -j --arg us "$US" '
    def tenths:
      if . == null then ""
      else ([([., 0] | max), 100] | min) * 10 | round
      end;
    [
      (.workspace.current_dir      // ""),
      (.workspace.project_dir      // ""),
      (.model.display_name         // ""),
      (.effort.level               // ""),
      (if .fast_mode == true then "fast" else "" end),
      (.cost.total_cost_usd        // 0),
      ((.context_window.used_percentage // 0) | tenths),
      (.context_window.total_input_tokens // 0),
      (.rate_limits.five_hour.used_percentage   | tenths),
      (.rate_limits.five_hour.resets_at         // ""),
      (.rate_limits.seven_day.used_percentage   | tenths),
      (.rate_limits.seven_day.resets_at         // ""),
      (.rate_limits.spend_limit.used_percentage | tenths),
      (.rate_limits.spend_limit.resets_at       // ""),
      (.pr.number                  // ""),
      (.worktree.name              // ""),
      (.worktree.branch            // "")
    ] | map(tostring) | join($us)
  ' 2>/dev/null
)

# A malformed payload leaves every field empty; row 1 still renders.
IFS=$US read -r current_dir payload_project_dir model effort fast cost \
  ctx_tenths ctx_tokens five_tenths five_reset seven_tenths seven_reset \
  spend_tenths spend_reset pr_number worktree_name worktree_branch \
  <<< "$fields"

[ -n "${payload_project_dir:-}" ] && project_dir=$payload_project_dir
current_dir=${current_dir:-$project_dir}
[ -z "${ctx_tenths:-}" ] && ctx_tenths=0
[ -z "${ctx_tokens:-}" ] && ctx_tokens=0
cost=${cost:-0}

git_branch "$current_dir"
[ -z "$_branch" ] && _branch=${worktree_branch:-}

# Row 1: identity.
printf -v cost_text '%.2f' "$cost"
shorten_branch "$_branch"

row1=${current_dir##*/}
[ -n "$_short_branch" ] && row1="${row1}  ${C_LABEL}⎇${C_RESET} ${_short_branch}"
[ -n "${worktree_name:-}" ] && row1="${row1} ${C_LABEL}[${worktree_name}]${C_RESET}"
[ -n "${pr_number:-}" ] && row1="${row1} ${C_LABEL}#${pr_number}${C_RESET}"
[ -n "${model:-}" ] && row1="${row1}  ${C_LABEL}${model}${C_RESET}"
[ -n "${effort:-}" ] && row1="${row1} ${C_LABEL}· ${effort}${C_RESET}"
[ -n "${fast:-}" ] && row1="${row1} ${C_LABEL}· ${fast}${C_RESET}"
row1="${row1} ${C_LABEL}· \$${cost_text}${C_RESET}"

# Row 2: meters.
render_meters "$ctx_tenths" "$ctx_tokens" \
  "${five_tenths:-}" "${five_reset:-}" \
  "${seven_tenths:-}" "${seven_reset:-}" \
  "${spend_tenths:-}" "${spend_reset:-}"

printf '%s\n%s\n' "$row1" "$_row2"
