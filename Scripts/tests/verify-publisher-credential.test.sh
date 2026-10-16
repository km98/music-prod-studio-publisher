#!/usr/bin/env bash
#
# Offline suite for Scripts/verify-publisher-credential.sh.
#
# The script exists to answer ONE question — "does the deployment still accept
# the publisher credential?" — and its failure paths matter more than its success
# path, because the credentials it handles are real. Every assertion below is
# either a refusal that must fire BEFORE any request is sent, or a property of the
# credential's transport.
#
# A fake `curl` stands in for the real one and replays canned API envelopes, so
# nothing here touches the network, the backend, or production. The fake also
# records, per call, whether the credential EVER reached a process argument — the
# promise that `ps` can never capture it — and whether it did arrive on stdin.
#
# No real secret appears here: the token below is a well-formed DUMMY.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/Scripts/verify-publisher-credential.sh"

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mps-verify-credential-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env python3
"""Stands in for curl: replays a canned envelope, and instruments the credential.

It NEVER prints the credential — it only records whether one was present in the
argument list or in the stdin config, which is exactly what the script promises.
"""
import json
import os
import sys

args = sys.argv[1:]
stdin = sys.stdin.read() if "-K" in args else ""
scenario = os.environ.get("FAKE_SCENARIO", "200")

with open(os.environ["FAKE_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "argv": args,
        "url": args[-1] if args else "",
        "credential_in_argv": any("mpspub_" in a for a in args),
        "credential_in_stdin_config": "mpspub_" in stdin,
        "authorization_in_stdin_config": "Authorization:" in stdin,
    }) + "\n")

BODIES = {
    "200": {"success": True, "data": {"releases": [
        {"version": "2.0.13", "status": "published"},
        {"version": "2.0.12", "status": "published"},
        {"version": "2.0.14", "status": "draft"},
    ]}},
    "401": {"success": False, "errorCode": "unauthenticated",
            "error": "authentication is required for this endpoint"},
    "403": {"success": False, "errorCode": "forbidden",
            "error": "you do not have permission for this operation"},
    "500": {"success": False, "errorCode": "internalError",
            "error": "an unexpected error occurred"},
    "garbage": "not json at all",
}

body = BODIES.get(scenario, BODIES["200"])
text = body if isinstance(body, str) else json.dumps(body)
sys.stdout.write(text + "\n" + scenario)
sys.exit(0)
FAKE
chmod +x "$TMP/bin/curl"

# A well-formed but entirely bogus machine credential (never a real secret).
TOKEN="$(python3 -c "print('mpspub_ci-test_' + 's' * 43)")"
TOKEN_FILE="$TMP/publisher.token"
INSECURE_TOKEN_FILE="$TMP/publisher-insecure.token"
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
printf '%s\n' "$TOKEN" > "$INSECURE_TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
chmod 644 "$INSECURE_TOKEN_FILE"
CALL_LOG="$TMP/calls.jsonl"
: > "$CALL_LOG"

passed=0
failed=0
pass() { echo "  PASS $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL $1"; failed=$((failed + 1)); }

# run <scenario> <mode> — executes the script with the fake curl and captures
# output plus the script's own exit status. mode is one of: env, missing, file,
# insecure, malformed, none.
OUT=""
CODE=0
run() {
    local scenario="$1" mode="$2"
    : > "$CALL_LOG"
    set +e
    case "$mode" in
        env)       OUT="$(env -u MPS_PUBLISHER_TOKEN_FILE MPS_PUBLISHER_TOKEN="$TOKEN" \
                            FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" \
                            PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)" ;;
        file)      OUT="$(env -u MPS_PUBLISHER_TOKEN MPS_PUBLISHER_TOKEN_FILE="$TOKEN_FILE" \
                            FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" \
                            PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)" ;;
        insecure)  OUT="$(env -u MPS_PUBLISHER_TOKEN MPS_PUBLISHER_TOKEN_FILE="$INSECURE_TOKEN_FILE" \
                            FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" \
                            PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)" ;;
        missing)   OUT="$(env -u MPS_PUBLISHER_TOKEN MPS_PUBLISHER_TOKEN_FILE="$TMP/nope.token" \
                            FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" \
                            PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)" ;;
        malformed) OUT="$(env -u MPS_PUBLISHER_TOKEN_FILE MPS_PUBLISHER_TOKEN="not-a-credential" \
                            FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" \
                            PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)" ;;
        none)      OUT="$(env -u MPS_PUBLISHER_TOKEN -u MPS_PUBLISHER_TOKEN_FILE \
                            FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" \
                            PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)" ;;
    esac
    CODE=$?
    set -e 2>/dev/null || true
}

check() { # check <description> <expected code> [substring]
    local description="$1" expected="$2" needle="${3:-}"
    if [ "$CODE" != "$expected" ]; then
        echo "  FAIL  $description (exit $CODE, expected $expected)"
        echo "$OUT" | sed 's/^/        | /'
        failed=$((failed + 1))
        return
    fi
    if [ -n "$needle" ] && ! printf '%s' "$OUT" | grep -qF -- "$needle"; then
        echo "  FAIL  $description (missing: $needle)"
        echo "$OUT" | sed 's/^/        | /'
        failed=$((failed + 1))
        return
    fi
    pass "$description"
}

calls() { cat "$CALL_LOG"; }
calls_count() { local n; n="$(grep -c . "$CALL_LOG" 2>/dev/null)"; echo "${n:-0}"; }

echo "verify-publisher-credential — offline suite"
echo ""

# ------------------------------------------------------- 1. configuration
run 200 none
check "no credential at all is a usage error" 2 "no credential was supplied"
[ "$(calls_count)" = "0" ] && pass "no credential: no request was sent" || fail "no credential: a request was sent"

run 200 malformed
check "a value that is not a publisher token is refused" 2 "is not a release publisher credential"

run 200 missing
check "a missing token file is refused" 2 "MPS_PUBLISHER_TOKEN_FILE does not exist"

run 200 insecure
check "a group- or world-readable token file is refused" 2 "must not be group- or world-readable"

# ------------------------------------------------------------ 2. acceptance
run 200 env
check "an accepted credential exits 0" 0 "the credential was ACCEPTED"
check "the accepted credential id is named (and only the id)" 0 "ci-test"
check "the accepted run performs exactly one request" 0 "releases visible: 3 (published: 2)"
[ "$(calls_count)" = "1" ] && pass "exactly one request was made" || fail "expected 1 request, saw $(calls_count)"

run 200 file
check "a 0600 token file is accepted as a credential source" 0 "the credential was ACCEPTED"

# ------------------------------------------------------------ 3. refusals
run 401 env
check "401 is reported as not accepted" 1 "the credential was NOT accepted"
check "401 reports the server's own words" 1 "authentication is required for this endpoint"
check "401 refuses to guess which side is missing" 1 "does not say WHICH"
check "401 forbids regenerating the credential to make it pass" 1 "Do NOT regenerate the credential"

run 403 env
check "403 is reported as a scope refusal" 1 "not scoped to this route"

run 500 env
check "an unexpected status is reported with its code" 1 "HTTP 500"

run garbage env
check "an unparseable body does not crash the check" 1 "did not succeed"

# ------------------------------------------- 4. credential transport promises
run 200 env
if grep -q '"credential_in_argv": true' "$CALL_LOG"; then
    fail "the credential reached a process argument (ps would capture it)"
else
    pass "the credential never reached a process argument"
fi
if grep -q '"credential_in_stdin_config": true' "$CALL_LOG"; then
    pass "the credential travelled in the stdin curl config"
else
    fail "the credential did not reach the request at all"
fi
if grep -q '"authorization_in_stdin_config": true' "$CALL_LOG"; then
    fail "a bearer Authorization header was sent alongside the publisher header"
else
    pass "no bearer Authorization header is sent"
fi

run 200 env
if printf '%s' "$OUT" | grep -qF -- "$TOKEN"; then
    fail "the SECRET appeared in the script's own output"
else
    pass "the secret never appears in the script's output"
fi
if printf '%s' "$OUT" | grep -q "mpspub_ci-test"; then
    fail "the secret's body appeared in the output"
else
    pass "no part of the secret appears in the output"
fi

# --------------------------------------------------------------- 5. hygiene
# Anchored to the start of a line so the script's own comment about xtrace ("NOT
# `set -x` anywhere") cannot be mistaken for the real thing.
if grep -qE '^[[:space:]]*set -x' "$SCRIPT"; then
    fail "the script enables xtrace, which would leak the credential"
else
    pass "the script never enables xtrace"
fi
# The credential may only ever be piped into the check that needs it — never
# written out, and never echoed.
if grep -qE 'tee[^|]*\$TOKEN|\$TOKEN[[:space:]]*>>?' "$SCRIPT"; then
    fail "the script writes the credential to a file"
else
    pass "the credential is never written to a file"
fi
if grep -qE '^[[:space:]]*echo[[:space:]]+"?\$TOKEN' "$SCRIPT"; then
    fail "the script echoes the credential variable"
else
    pass "the script never echoes the credential variable"
fi

echo ""
echo "verify-publisher-credential: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
