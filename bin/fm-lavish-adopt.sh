#!/usr/bin/env bash
# Arm a procevent listener for every live Lavish session that has none.
#
# Usage:
#   fm-lavish-adopt.sh sweep
#
# WHY THIS EXISTS. Publishing a Lavish review and attaching a listener to it are
# two separate commands, and skipping the second one fails silently: the URL
# works, the captain annotates, the feedback queues on the server, and nothing
# ever consumes it. The captain sees "Your agent is not listening"; no machine
# could see anything at all. This sweep makes that invariant - a live session
# has a listener - hold continuously instead of depending on every publisher
# remembering the second command.
#
# THE TRUTH ABOUT LISTENERS IS THE SERVER'S, NEVER THIS HOME'S REGISTRY. A
# worker running its own foreground `lavish-axi poll` is a listener that this
# home's procevent registry cannot see, and Lavish's own guidance makes the
# foreground poll the default. Arming such a session would put two consumers on
# one destructively-cleared feedback queue and lose the captain's words. So
# eligibility is decided by the `presence` field the server reports, not by
# registry membership:
#
#   waiting    nobody is attached          -> adopt
#   listening  a poll is attached          -> leave alone, whoever owns it
#   working    feedback already delivered  -> leave alone
#   unknown    no server, or it did not answer -> leave alone
#
# `unknown` means "cannot tell", never "nobody is listening", and arming a
# session on a server that is not running registers a poll that can never
# attach. Treating it as adoptable is the one mistake that turns this sweep
# into the bug it exists to fix.
#
# VERSION FLOOR, SELF-DESCRIBING. `presence` arrives in the listing's own field
# header. A lavish-axi that predates it simply does not declare the column, and
# this sweep is then a no-op that says so once rather than guessing a position
# and arming the wrong rows.
#
# This adopts only. It never polls, never retires a source, never reopens an
# ended session, and never edits an artifact.
#
# RATE LIMITED, BECAUSE IT IS A BACKSTOP. Reading the listing spawns a process
# and costs about a second. The supervision cycle runs far more often than an
# unlistened review appears, and the ordinary publish path arms its own listener
# anyway, so sweeping every cycle would spend that second over and over to find
# nothing. One sweep per FM_LAVISH_ADOPT_INTERVAL seconds is enough for a
# backstop; `--force` is how a caller that genuinely needs an immediate answer,
# such as a test, bypasses it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ADOPT_INTERVAL_DEFAULT=300

warn() { printf 'fm-lavish-adopt: %s\n' "$1" >&2; }

usage() {
  printf 'usage: fm-lavish-adopt.sh sweep [--force]\n' >&2
  exit 2
}

adopt_interval() {
  local raw=${FM_LAVISH_ADOPT_INTERVAL:-$ADOPT_INTERVAL_DEFAULT}
  case $raw in
    ''|*[!0-9]*) printf '%s\n' "$ADOPT_INTERVAL_DEFAULT" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# Exit 0 when this cycle should sweep. The stamp is touched before the sweep,
# not after, so a slow or failing listing cannot make every later cycle retry it.
due_for_sweep() {
  local stamp="$STATE/.lavish-adopt-stamp" interval now last
  interval=$(adopt_interval)
  [ "$interval" -gt 0 ] || return 0
  now=$(date +%s)
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null) || last=0
    case $last in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$interval" ] || return 1
  fi
  [ -d "$STATE" ] || return 0
  printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
  return 0
}

# Rows are `<file>,<status>,"<url>",<pending>,<presence>` under a header that
# declares the field names. A path may itself contain a comma, so every field is
# addressed from the RIGHT, where the offsets are fixed, and the file name is
# whatever remains on the left. Reading the offsets out of the header instead of
# hardcoding them means a field appended upstream later does not silently shift
# what this sweep thinks it is reading.
eligible_rows() {  # <listing>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*sessions\[[0-9]+\]\{/ {
      header = $0
      sub(/^[^{]*\{/, "", header)
      sub(/\}.*$/, "", header)
      total = split(header, names, ",")
      for (i = 1; i <= total; i++) {
        if (names[i] == "presence") presence_from_right = total - i
        if (names[i] == "status") status_from_right = total - i
      }
      fields_after_file = total - 1
      next
    }
    presence_from_right == "" { next }
    /^[[:space:]]*\// {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      n = split(line, field, ",")
      presence = field[n - presence_from_right]
      status = field[n - status_from_right]
      if (presence != "waiting") next
      if (status == "ended") next
      # Everything left of the first structural field is the path, which may
      # itself contain commas.
      file = field[1]
      for (i = 2; i <= n - fields_after_file; i++) file = file "," field[i]
      print file
    }
    END { if (presence_from_right == "") exit 3 }
  '
}

cmd_sweep() {  # [--force]
  [ "${1-}" = --force ] || due_for_sweep || return 0
  command -v lavish-axi >/dev/null 2>&1 || { warn "lavish-axi is not installed; nothing to adopt"; return 0; }

  local listing rows armed=0 registry
  # A listing must never be allowed to hang a supervision cycle.
  listing=$(lavish-axi 2>/dev/null) || { warn "could not read the Lavish session listing"; return 0; }

  rows=$(eligible_rows "$listing")
  case $? in
    0) ;;
    3) warn "this lavish-axi does not report session presence; skipping (upgrade to adopt unlistened reviews)"; return 0 ;;
    *) warn "could not parse the Lavish session listing"; return 0 ;;
  esac

  [ -n "$rows" ] || return 0
  registry=$("$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null) || registry=""

  local file id
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || { warn "skipping a listed session whose artifact is gone: $file"; continue; }
    id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$file" 2>/dev/null) || continue
    # Already registered is the ordinary case on every later cycle: the source
    # is armed, its runner owns the poll, and presence simply has not caught up
    # yet within this cycle. Re-arming is not an error, it is just noise.
    case $registry in *"$id"*) continue ;; esac
    if "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$file" >/dev/null 2>&1; then
      printf 'adopted: %s %s\n' "$id" "$file"
      armed=$((armed + 1))
    else
      warn "could not arm an unlistened session: $file"
    fi
  done <<< "$rows"

  [ "$armed" -eq 0 ] || printf 'fm-lavish-adopt: armed %d unlistened Lavish session(s)\n' "$armed"
  return 0
}

case "${1-}" in
  sweep)
    shift
    case "${1-}" in
      '') cmd_sweep ;;
      --force) [ "$#" -eq 1 ] || usage; cmd_sweep --force ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
