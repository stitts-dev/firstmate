#!/usr/bin/env bash
# Focused tests for bin/fm-lavish-adopt.sh.
# Covers presence-driven eligibility, the version floor, idempotence, and the
# refusals that keep a second consumer off a session that already has one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lavish-adopt)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT="$TMP_ROOT/root"
mkdir -p "$ROOT/bin" "$TMP_ROOT/artifacts"
cp "$FM_ROOT/bin/fm-lavish-adopt.sh" "$ROOT/bin/"

WAITING="$TMP_ROOT/artifacts/waiting.html"
LISTENING="$TMP_ROOT/artifacts/listening.html"
ENDED="$TMP_ROOT/artifacts/ended.html"
UNKNOWN="$TMP_ROOT/artifacts/unknown.html"
for f in "$WAITING" "$LISTENING" "$ENDED" "$UNKNOWN"; do
  printf '<!doctype html><html><body></body></html>' > "$f"
done

ARMED="$TMP_ROOT/armed.log"
: > "$ARMED"

# A stub lavish-axi whose listing is whatever the test wrote, and stub procevent
# scripts that record what the sweep asked for instead of registering anything.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
cat "$LAVISH_LISTING_FIXTURE"
SH
cat > "$ROOT/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  source-id) printf 'lavish-%s\n' "$(printf '%s' "$2" | cksum | tr -d ' \n')" ;;
  arm) printf '%s\n' "$2" >> "$ARMED_LOG"; printf 'armed\n' ;;
  *) exit 2 ;;
esac
SH
cat > "$ROOT/bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = list ] || exit 2
cat "${REGISTRY_FIXTURE:-/dev/null}"
SH
chmod +x "$FAKEBIN/lavish-axi" "$ROOT/bin/fm-procevent-lavish.sh" "$ROOT/bin/fm-procevent.sh"
export PATH="$FAKEBIN:$PATH"
export ARMED_LOG="$ARMED"

LISTING="$TMP_ROOT/listing.txt"
export LAVISH_LISTING_FIXTURE="$LISTING"

write_listing() {  # <header-fields> <rows...>
  local header=$1; shift
  {
    printf 'bin: lavish-axi\n'
    printf 'sessions[%d]{%s}:\n' "$#" "$header"
    printf '  %s\n' "$@"
    printf 'help[1]: "unrelated trailing output"\n'
  } > "$LISTING"
}

sweep() { "$ROOT/bin/fm-lavish-adopt.sh" sweep --force 2>&1; }

# --- presence decides eligibility, nothing else ------------------------------
: > "$ARMED"
write_listing 'file,status,url,pending_prompts,presence' \
  "$WAITING,feedback,\"http://h/1\",1,waiting" \
  "$LISTENING,feedback,\"http://h/2\",3,listening" \
  "$ENDED,ended,\"http://h/3\",0,waiting" \
  "$UNKNOWN,open,\"http://h/4\",0,unknown"
out=$(sweep) || fail "sweep exited non-zero: $out"
assert_contains "$out" "adopted:" "sweep reported no adoption"
[ "$(wc -l < "$ARMED" | tr -d ' ')" = "1" ] \
  || fail "expected exactly one arm, got: $(cat "$ARMED")"
assert_grep "$WAITING" "$ARMED" "the waiting session was not armed"
assert_no_grep "$LISTENING" "$ARMED" "a session with a listener was armed anyway"
assert_no_grep "$ENDED" "$ARMED" "an ended session was armed"
assert_no_grep "$UNKNOWN" "$ARMED" "a session with unknown presence was armed"
pass "sweep arms waiting sessions only, and never listening, ended, or unknown"

# --- idempotence: an already-registered source is left alone -----------------
: > "$ARMED"
REG="$TMP_ROOT/registry.txt"
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$WAITING")
printf 'SOURCE ADAPTER OWNER PENDING\n%s lavish live 0\n' "$id" > "$REG"
REGISTRY_FIXTURE="$REG" sweep >/dev/null || fail "second sweep exited non-zero"
[ ! -s "$ARMED" ] || fail "an already-registered source was armed again: $(cat "$ARMED")"
pass "sweep is idempotent against an already-registered source"

# --- version floor: no presence column means no guessing ---------------------
: > "$ARMED"
write_listing 'file,status,url,pending_prompts' \
  "$WAITING,feedback,\"http://h/1\",1"
out=$(sweep) || fail "sweep exited non-zero on a listing without presence"
assert_contains "$out" "does not report session presence" "the version floor was not reported"
[ ! -s "$ARMED" ] || fail "armed a session from a listing that never declared presence"
pass "a lavish-axi without presence is a no-op, not a guess"

# --- a field appended upstream must not shift what is read -------------------
: > "$ARMED"
write_listing 'file,status,url,pending_prompts,presence,future_field' \
  "$WAITING,feedback,\"http://h/1\",1,waiting,xyz" \
  "$LISTENING,open,\"http://h/2\",0,listening,xyz"
sweep >/dev/null || fail "sweep exited non-zero on an extended listing"
assert_grep "$WAITING" "$ARMED" "presence was misread when a field was appended"
assert_no_grep "$LISTENING" "$ARMED" "listening was misread when a field was appended"
pass "field offsets come from the header, so an appended column is harmless"

# --- a path containing a comma is still parsed from the right ----------------
: > "$ARMED"
COMMA="$TMP_ROOT/artifacts/a,b.html"
printf '<!doctype html>' > "$COMMA"
write_listing 'file,status,url,pending_prompts,presence' \
  "$COMMA,feedback,\"http://h/1\",1,waiting"
sweep >/dev/null || fail "sweep exited non-zero on a comma path"
assert_grep "a,b.html" "$ARMED" "a path containing a comma was not reassembled"
pass "a path containing a comma is parsed correctly"

# --- a listed artifact that no longer exists is skipped, not armed -----------
: > "$ARMED"
write_listing 'file,status,url,pending_prompts,presence' \
  "$TMP_ROOT/artifacts/gone.html,feedback,\"http://h/1\",1,waiting"
out=$(sweep) || fail "sweep exited non-zero on a missing artifact"
assert_contains "$out" "artifact is gone" "a missing artifact was not reported"
[ ! -s "$ARMED" ] || fail "armed a session whose artifact no longer exists"
pass "a session whose artifact is gone is skipped"

# --- the backstop is rate limited, and --force bypasses it -------------------
: > "$ARMED"
export FM_HOME="$TMP_ROOT/ratelimit" FM_STATE_OVERRIDE="$TMP_ROOT/ratelimit/state"
mkdir -p "$FM_STATE_OVERRIDE"
write_listing 'file,status,url,pending_prompts,presence' \
  "$WAITING,feedback,\"http://h/1\",1,waiting"
"$ROOT/bin/fm-lavish-adopt.sh" sweep >/dev/null 2>&1 || fail "first unforced sweep exited non-zero"
[ -s "$ARMED" ] || fail "the first unforced sweep did not run"
assert_present "$FM_STATE_OVERRIDE/.lavish-adopt-stamp" "the sweep did not record when it last ran"

: > "$ARMED"
"$ROOT/bin/fm-lavish-adopt.sh" sweep >/dev/null 2>&1 || fail "rate-limited sweep exited non-zero"
[ ! -s "$ARMED" ] || fail "a second sweep ran inside the rate-limit interval"
pass "the sweep is rate limited between supervision cycles"

: > "$ARMED"
"$ROOT/bin/fm-lavish-adopt.sh" sweep --force >/dev/null 2>&1 || fail "forced sweep exited non-zero"
[ -s "$ARMED" ] || fail "--force did not bypass the rate limit"
pass "--force bypasses the rate limit"

: > "$ARMED"
FM_LAVISH_ADOPT_INTERVAL=0 "$ROOT/bin/fm-lavish-adopt.sh" sweep >/dev/null 2>&1 \
  || fail "sweep with a zero interval exited non-zero"
[ -s "$ARMED" ] || fail "a zero interval did not disable the rate limit"
pass "FM_LAVISH_ADOPT_INTERVAL=0 disables the rate limit"
unset FM_HOME FM_STATE_OVERRIDE

printf 'all fm-lavish-adopt tests passed\n' 
