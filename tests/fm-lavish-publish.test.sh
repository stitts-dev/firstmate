#!/usr/bin/env bash
# Focused tests for bin/fm-lavish-publish.sh: the URL is handed out only once a
# listener exists, and every state that cannot prove a live session refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lavish-publish)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT="$TMP_ROOT/root"
mkdir -p "$ROOT/bin"
cp "$FM_ROOT/bin/fm-lavish-publish.sh" "$ROOT/bin/"

ARTIFACT="$TMP_ROOT/review.html"
printf '<!doctype html><html><body></body></html>' > "$ARTIFACT"
REAL=$(perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$ARTIFACT")

ARMED="$TMP_ROOT/armed.log"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# The stub answers `lavish-axi <file>` from ESTABLISH_STATUS and the bare
# listing from LISTING_STATUS, so each refusal can be driven independently.
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then
  printf 'sessions[1]{file,status,url,pending_prompts,presence}:\n'
  printf '  %s,%s,"http://h/1",0,waiting\n' "$REAL_PATH" "${LISTING_STATUS:-open}"
  exit 0
fi
if [ "$1" = "--version" ]; then printf '0.0.0-test\n'; exit 0; fi
printf 'session:\n  file: %s\n  url: "http://h/1"\n  status: %s\n' "$1" "${ESTABLISH_STATUS:-opened}"
exit 0
SH
cat > "$ROOT/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = arm ] || exit 2
[ -z "${ARM_FAILS:-}" ] || exit 1
printf '%s\n' "$2" >> "$ARMED_LOG"
SH
chmod +x "$FAKEBIN/lavish-axi" "$ROOT/bin/fm-procevent-lavish.sh"
export PATH="$FAKEBIN:$PATH" ARMED_LOG="$ARMED" REAL_PATH="$REAL"

publish() { "$ROOT/bin/fm-lavish-publish.sh" "$ARTIFACT" 2>&1; }

# --- the happy path arms before it prints the URL ----------------------------
: > "$ARMED"
out=$(publish) || fail "publish failed on a live session: $out"
assert_contains "$out" "listener: armed" "publish did not report an armed listener"
assert_contains "$out" "url: http://h/1" "publish did not report the session URL"
assert_grep "$REAL" "$ARMED" "publish did not arm the canonical artifact path"
pass "publish establishes, proves live, arms, then hands out the URL"

# --- a session the captain ended is never reopened uninvited -----------------
: > "$ARMED"
out=$(ESTABLISH_STATUS=user-ended publish) && fail "publish accepted a captain-ended session"
assert_contains "$out" "ask them before reopening" "the captain-ended refusal was not reported"
[ ! -s "$ARMED" ] || fail "armed a poll on a session the captain ended"
pass "a captain-ended session refuses instead of reopening uninvited"

# --- a session that is not listed open refuses to be armed -------------------
: > "$ARMED"
out=$(LISTING_STATUS=feedback publish) && fail "publish armed a session that is not listed open"
assert_contains "$out" "not listed open" "the not-live refusal was not reported"
[ ! -s "$ARMED" ] || fail "armed a poll on a session that is not listed open"
pass "a session not listed open refuses rather than arming a poll that cannot attach"

# --- if arming fails, the URL is never handed out ----------------------------
: > "$ARMED"
out=$(ARM_FAILS=1 publish) && fail "publish succeeded although arming failed"
assert_contains "$out" "listener could not be armed" "the arm failure was not reported"
assert_not_contains "$out" "url:" "the URL was handed out although no listener was armed"
pass "a failed arm refuses, and never hands out an unlistened URL"

# --- a missing artifact refuses before touching lavish-axi -------------------
out=$("$ROOT/bin/fm-lavish-publish.sh" "$TMP_ROOT/absent.html" 2>&1) \
  && fail "publish accepted a missing artifact"
assert_contains "$out" "no such artifact" "the missing-artifact refusal was not reported"
pass "a missing artifact refuses before anything is established"

printf 'all fm-lavish-publish tests passed\n'
