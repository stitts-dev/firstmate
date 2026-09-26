#!/usr/bin/env bash
# Live driver: real tasks-axi backlog, real fm-captain-hold.sh hold/complete/answer/open,
# real fm-classify-lib.sh status_monitor_line and fm-supervise-daemon.sh classify_stale.
# Only fm-crew-state.sh is stubbed (no harness pane/run exists in this sandbox).
set -u
ROOT=${ROOT:?}
. "$ROOT/tests/lib.sh"
T=$(mktemp -d /tmp/nm-live-held.XXXXXX)
home="$T/home"; mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for t in tmux treehouse no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; done
# gh/gh-axi log every call so we can prove nothing was published.
for t in gh gh-axi; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/publish.log"\nexit 0\n' "$t" "$T" > "$home/fakebin/$t"; done
chmod +x "$home/fakebin"/*
REAL=$(command -v tasks-axi)
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" REAL_TASKS_AXI="$REAL"
export PATH="$home/fakebin:$PATH"
cap() { "$ROOT/bin/fm-captain-hold.sh" "$@"; }
# Real captain-hold binary, wrapped only to carry the isolated home env.
printf '#!/usr/bin/env bash\nexec "%s/bin/fm-captain-hold.sh" "$@"\n' "$ROOT" > "$T/captain-hold"; chmod +x "$T/captain-hold"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FM_FAKE_CREW_STATE"\n' > "$T/crew-state"; chmod +x "$T/crew-state"
export FM_CAPTAIN_HOLD_BIN="$T/captain-hold" FM_CREW_STATE_BIN="$T/crew-state"
export FM_FAKE_CREW_STATE='state: working · source: run-step'

id=voxren-pi-coach
(cd "$home" && tasks-axi add "$id" "Private Voxren Pi coach review" --kind scout --repo voxren --start >/dev/null)
cat > "$home/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$home/projects/missing-$id
project=$home/projects/voxren
harness=pi
kind=scout
mode=scout
spawn_gen=fixture-$id
EOF
mkdir -p "$home/data/$id"
printf '# Pi coach review\n\nMetric and publication choices await the captain.\n' > "$home/data/$id/report.md"
report_hash=$(shasum -a 256 "$home/data/$id/report.md" | awk '{print $1}')
printf 'needs-decision [key=metric]: pick the coaching metric\nneeds-decision [key=publication]: keep private or publish?\n' > "$home/state/$id.status"

echo "== hold metric and publication calls (real fm-captain-hold hold)"
cap hold "$id-metric" --title "Pick coach metric" --reason "captain metric choice pending" --repo voxren --origin "$id" >/dev/null || { echo FAIL hold metric; exit 1; }
cap hold "$id-publication" --title "Publish coach?" --reason "captain publication choice pending" --repo voxren --origin "$id" >/dev/null || { echo FAIL hold pub; exit 1; }
cap complete "$id" "$id-metric" "$id-publication" >/dev/null || { echo FAIL complete; exit 1; }
echo "-- status file after complete:"; cat "$home/state/$id.status"

show() {
  bash -c '. "$1/bin/fm-classify-lib.sh"; printf "last_status_line:    %s\n" "$(last_status_line "$2")"; printf "status_monitor_line: %s\n" "$(status_monitor_line "$2")"' _ "$ROOT" "$home/state/$id.status"
  FM_TEST_DAEMON_SOURCED=1 bash -c '. "$1/bin/fm-supervise-daemon.sh"; mkdir -p "$3"; printf "classify_stale:      %s\n" "$(classify_stale "firstmate:fm-$2" "$3")"' _ "$ROOT" "$id" "$home/state" 2>/dev/null
}

echo; echo "== S1 routine working: after hold, run live, calls open"
printf 'working: routine repair bookkeeping completed\n' >> "$home/state/$id.status"
printf 'note: rechecked worktree, nothing to do\n' >> "$home/state/$id.status"
show

echo; echo "== S2 lost run behind masked hold (crew state unknown)"
FM_FAKE_CREW_STATE='state: unknown · source: none' show

echo; echo "== S3 blocker after hold"
cp "$home/state/$id.status" "$T/status.bak"
printf 'blocked [key=repair]: repair validation failed\n' >> "$home/state/$id.status"
show
cp "$T/status.bak" "$home/state/$id.status"

echo; echo "== S4 captain answers metric only (publication still open)"
printf 'Use weekly active coaching minutes.\n' > "$T/metric.txt"
cap answer "$id-metric" --decision-file "$T/metric.txt" >/dev/null || echo "answer metric rc=$?"
cap open "$id-metric" --origin "$id"; echo "open metric rc=$?"
cap open "$id-publication" --origin "$id"; echo "open publication rc=$?"
show

echo; echo "== S5 captain answers publication too (all calls answered, worker resumed)"
printf 'Keep it private for now.\n' > "$T/pub.txt"
cap answer "$id-publication" --decision-file "$T/pub.txt" >/dev/null || echo "answer pub rc=$?"
cap open "$id-publication" --origin "$id"; echo "open publication rc=$?"
show

echo; echo "== S6 work untouched, nothing published"
now_hash=$(shasum -a 256 "$home/data/$id/report.md" | awk '{print $1}')
[ "$report_hash" = "$now_hash" ] && echo "report.md unchanged ($now_hash)" || echo "FAIL report changed"
[ -s "$T/publish.log" ] && { echo "publish calls:"; cat "$T/publish.log"; } || echo "no gh/gh-axi publish calls"
rm -rf "$T"
