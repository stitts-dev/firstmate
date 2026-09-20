#!/usr/bin/env bash
# Publish a Lavish review AND attach its listener, as one operation.
#
# Usage:
#   fm-lavish-publish.sh <html-file>
#
# WHY THIS IS THE REQUIRED PATH. `lavish-axi <html>` establishes a review and
# exits 0. Arming a listener for it is a second, separate command, and skipping
# that second command fails silently: the URL works, the captain annotates, the
# feedback queues on the server, and nothing ever consumes it. Nobody notices
# until someone asks why a review went nowhere. Publishing and listening are one
# intention, so they are one command here, and the URL is printed only once a
# listener is registered for it.
#
# A SESSION IS PROVED LIVE, NEVER ASSUMED. `lavish-axi <file>` also exits 0 when
# it refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` with the same session id. An exit code therefore proves
# nothing; the server's own listing must show the session open before anything
# arms a poll on it. This mirrors the check bin/fm-bearings-board.sh has always
# done for the bearings board.
#
# This never passes --reopen. A session the captain ended is theirs to reopen,
# and reopening it uninvited is exactly the behavior lavish-axi refuses by
# default. This reports the refusal and stops.
#
# ponytail: bin/fm-bearings-board.sh still carries its own copy of the
# establish-and-prove sequence, because its flow also owns captain-hold binding
# and a reopen-generation retirement that this path deliberately does not have.
# Consolidating the two is a separate change with its own test surface.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'fm-lavish-publish: %s\n' "$1" >&2; exit 1; }

usage() {
  printf 'usage: fm-lavish-publish.sh <html-file>\n' >&2
  exit 2
}

canonical_path() {  # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

url_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>[,<presence>]`, and only a live session is
# listed `open`. Fields after the status are irrelevant here, so an appended
# column cannot affect this check.
session_listed_open() {  # <canonical-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

artifact=${1-}
[ -n "$artifact" ] || usage
[ "$#" -eq 1 ] || usage
[ -f "$artifact" ] || die "no such artifact: $artifact"
command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"

real=$(canonical_path "$artifact") || die "cannot resolve the artifact path: $artifact"

out=$(lavish-axi "$real") || die "cannot establish the Lavish session"
status=$(status_field "$out")
if [ "$status" = "user-ended" ]; then
  die "the captain ended this review; ask them before reopening it (lavish-axi '$real' --reopen)"
fi

if ! session_listed_open "$real"; then
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  die "the Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}, reported status ${status:-none}); refusing to arm a poll on a session that is not live"
fi

"$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$real" >/dev/null \
  || die "the review is live but its listener could not be armed; do not hand out the URL until it is"

printf 'published: %s\n' "$real"
printf 'url: %s\n' "$(url_field "$out")"
printf 'listener: armed\n'
