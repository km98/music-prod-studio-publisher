#!/bin/bash
# Offline suite for Scripts/release-publisher-credential.sh.
#
# This tooling creates the credential that can approve and publish a production
# release, so its properties are asserted rather than assumed:
#
#   * the SECRET never reaches stdout/stderr (a secret printed once into a
#     scrollback, a CI log or a chat is a secret leaked),
#   * the SERVER entry it prints is the SHA-256 of exactly that token, verified
#     against an independent implementation (python hashlib) — the same digest
#     the backend compares, never the secret itself,
#   * a credential file is written 0600 and never inside the repository,
#   * an existing credential file is never overwritten (that would silently
#     invalidate a credential in use),
#   * rotation prints the two-entry window, and revocation removes exactly the
#     named entry and keeps the rest.
#
# Nothing here touches the network, the backend, or any real credential: every
# generated secret lives in a private temp directory and is deleted with it.
#
# Exit status is the verdict.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/Scripts/release-publisher-credential.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mps-publisher-credential-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

passed=0
failed=0
pass() { echo "  PASS $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL $1"; failed=$((failed + 1)); }

run() { # run <out-file> [args…] ; sets RUN_STATUS
    local out="$1"; shift
    bash "$SCRIPT" "$@" > "$out" 2>&1
    RUN_STATUS=$?
}

# The digest of a token, computed independently of the tooling.
independent_sha256() { printf '%s' "$1" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())'; }

echo "release-publisher-credential.sh — credential tooling suite"
echo ""

# --- generate ---------------------------------------------------------------
TOKEN_DIR="$TMP/credentials"
mkdir -p "$TOKEN_DIR"
run "$TMP/gen.out" generate --id ci-2026-10 --out "$TOKEN_DIR/ci-2026-10" --actor 0f5d9c1e-6b7a-4c2d-8e3f-1a2b3c4d5e6f
TOKEN_FILE="$TOKEN_DIR/ci-2026-10"
if [ "$RUN_STATUS" -eq 0 ] && [ -s "$TOKEN_FILE" ]; then
    pass "G1 a credential is generated"
else
    fail "G1 generate (exit $RUN_STATUS): $(tail -2 "$TMP/gen.out" | tr '\n' ' ')"
fi

TOKEN="$(cat "$TOKEN_FILE")"
printf '%s' "$TOKEN" | grep -qE '^mpspub_ci-2026-10_[A-Za-z0-9_-]{43,}$' \
    && pass "G2 the token has the shape the server validates (mpspub_<id>_<43+ chars>)" \
    || fail "G2 token shape: '$(printf '%s' "$TOKEN" | cut -c1-24)…'"

[ "$(stat -f '%Lp' "$TOKEN_FILE")" = "600" ] \
    && pass "G3 the credential file is 0600" \
    || fail "G3 credential file mode is $(stat -f '%Lp' "$TOKEN_FILE")"

grep -qF "$TOKEN" "$TMP/gen.out" \
    && fail "G4 the secret was printed to stdout/stderr" \
    || pass "G4 the secret is never printed (only its digest and id are)"

EXPECTED_HASH="$(independent_sha256 "$TOKEN")"
grep -q "RELEASE_PUBLISHER_CREDENTIALS   ci-2026-10:${EXPECTED_HASH}:write" "$TMP/gen.out" \
    && pass "G5 the server entry is the SHA-256 of exactly this token (verified independently)" \
    || fail "G5 server entry: $(grep -m1 RELEASE_PUBLISHER_CREDENTIALS "$TMP/gen.out")"

grep -q "RELEASE_PUBLISHER_ACTOR_ID     0f5d9c1e-6b7a-4c2d-8e3f-1a2b3c4d5e6f" "$TMP/gen.out" \
    && pass "G6 the actor identity is reported for the backend secret" \
    || fail "G6 actor identity"

# The printed path is canonical (the tooling resolves /var → /private/var on
# macOS), which is what makes the printed command work when it is pasted.
TOKEN_FILE_CANON="$(cd "$(dirname "$TOKEN_FILE")" && pwd)/$(basename "$TOKEN_FILE")"
grep -qF "gh secret set MPS_PUBLISHER_TOKEN --env production < '$TOKEN_FILE_CANON'" "$TMP/gen.out" \
    && pass "G7 the GitHub secret is set from the file, never typed" \
    || fail "G7 GitHub secret instructions: $(grep -m1 'gh secret set' "$TMP/gen.out")"

# A second credential gets its own secret and its own digest.
run "$TMP/gen2.out" generate --id monitor --scope read --out "$TOKEN_DIR/monitor"
TOKEN2="$(cat "$TOKEN_DIR/monitor" 2>/dev/null || true)"
if [ "$RUN_STATUS" -eq 0 ] && [ -n "$TOKEN2" ] && [ "$TOKEN2" != "$TOKEN" ] \
    && grep -q "RELEASE_PUBLISHER_CREDENTIALS   monitor:$(independent_sha256 "$TOKEN2"):read" "$TMP/gen2.out"; then
    pass "G8 a second credential is independent and carries its own scope"
else
    fail "G8 second credential (exit $RUN_STATUS)"
fi

# --- refusals ---------------------------------------------------------------
run "$TMP/overwrite.out" generate --id ci-2026-10 --out "$TOKEN_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "refusing to overwrite" "$TMP/overwrite.out" \
    && [ "$(cat "$TOKEN_FILE")" = "$TOKEN" ]; then
    pass "G9 an existing credential file is never overwritten (and is left intact)"
else
    fail "G9 overwrite refusal (exit $RUN_STATUS)"
fi

# The target is a path inside the repository whose PARENT DIRECTORY exists, so
# the case reaches the in-repository guard under test. (The app repository had a
# git-ignored build/ tree here; this repository deliberately has none, and a
# missing parent directory is refused earlier, for a different reason.)
run "$TMP/inrepo.out" generate --id ci-in-repo --out "$REPO_ROOT/Scripts/publisher-credential"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "must never live in a tracked tree" "$TMP/inrepo.out" \
    && [ ! -e "$REPO_ROOT/Scripts/publisher-credential" ]; then
    pass "G10 a credential can never be written inside the repository"
else
    fail "G10 in-repository refusal (exit $RUN_STATUS)"
fi

run "$TMP/badid.out" generate --id "CI-2026-10" --out "$TOKEN_DIR/bad-id"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "must be 1-32 characters" "$TMP/badid.out" && [ ! -e "$TOKEN_DIR/bad-id" ]; then
    pass "G11 an id outside the token alphabet is refused"
else
    fail "G11 invalid id (exit $RUN_STATUS)"
fi

run "$TMP/badscope.out" generate --id ci-bad-scope --scope admin --out "$TOKEN_DIR/bad-scope"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "scope must be 'write' or 'read'" "$TMP/badscope.out"; then
    pass "G12 an unknown scope is refused (no credential is issued)"
else
    fail "G12 invalid scope (exit $RUN_STATUS)"
fi

run "$TMP/badactor.out" generate --id ci-bad-actor --actor not-a-uuid --out "$TOKEN_DIR/bad-actor"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "is not a UUID" "$TMP/badactor.out" && [ ! -e "$TOKEN_DIR/bad-actor" ]; then
    pass "G13 an actor identity that is not a UUID is refused"
else
    fail "G13 invalid actor (exit $RUN_STATUS)"
fi

# --- hash -------------------------------------------------------------------
run "$TMP/hash.out" hash --file "$TOKEN_FILE"
if [ "$RUN_STATUS" -eq 0 ] && grep -q "sha256: $EXPECTED_HASH" "$TMP/hash.out" \
    && grep -q "id:     ci-2026-10" "$TMP/hash.out" \
    && grep -q "entry:  ci-2026-10:${EXPECTED_HASH}:write" "$TMP/hash.out"; then
    pass "H1 hash reports the id and digest of an existing credential (never the secret)"
else
    fail "H1 hash (exit $RUN_STATUS)"
fi
grep -qF "$TOKEN" "$TMP/hash.out" && fail "H2 hash printed the secret" \
    || pass "H2 hash never prints the secret"

printf 'not-a-token\n' > "$TMP/not-a-token"
run "$TMP/hash-bad.out" hash --file "$TMP/not-a-token"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "does not contain a publisher token" "$TMP/hash-bad.out"; then
    pass "H3 hash refuses a file that is not a publisher token"
else
    fail "H3 hash refusal (exit $RUN_STATUS)"
fi

# --- rotate -----------------------------------------------------------------
run "$TMP/rotate.out" rotate --id ci-2026-11 --previous ci-2026-10 --out "$TOKEN_DIR/ci-2026-11"
TOKEN3="$(cat "$TOKEN_DIR/ci-2026-11" 2>/dev/null || true)"
if [ "$RUN_STATUS" -eq 0 ] && [ -n "$TOKEN3" ] && [ "$TOKEN3" != "$TOKEN" ]; then
    pass "R1 rotation issues a new credential"
else
    fail "R1 rotate (exit $RUN_STATUS)"
fi
grep -q "ROTATION IS A TWO-ENTRY WINDOW" "$TMP/rotate.out" \
    && pass "R2 rotation prints the two-entry window" \
    || fail "R2 rotation instructions"
grep -q "<old-id>:<old-hash>:write,ci-2026-11:$(independent_sha256 "$TOKEN3"):write" "$TMP/rotate.out" \
    && pass "R3 the window adds the NEW entry beside the old one (so the old token keeps working)" \
    || fail "R3 two-entry window: $(grep -m1 'RELEASE_PUBLISHER_CREDENTIALS' "$TMP/rotate.out")"
grep -q "REMOVE the old entry ('ci-2026-10')" "$TMP/rotate.out" \
    && pass "R4 the window names the entry to remove and when" \
    || fail "R4 removal instruction"
grep -qF "$TOKEN3" "$TMP/rotate.out" && fail "R5 rotation printed the new secret" \
    || pass "R5 rotation never prints the new secret"

# --- revoke -----------------------------------------------------------------
ENTRY_A="ci-2026-11:$(independent_sha256 "$TOKEN3"):write"
ENTRY_B="monitor:$(independent_sha256 "$TOKEN2"):read"
run "$TMP/revoke.out" revoke --id ci-2026-11 --entry "$ENTRY_A,$ENTRY_B"
if [ "$RUN_STATUS" -eq 0 ] && grep -q "removed 1 entry" "$TMP/revoke.out" \
    && grep -q "RELEASE_PUBLISHER_CREDENTIALS   $ENTRY_B" "$TMP/revoke.out" \
    && ! grep -q "$ENTRY_A" "$TMP/revoke.out"; then
    pass "V1 revocation removes exactly the named entry and keeps the rest"
else
    fail "V1 revoke (exit $RUN_STATUS): $(tail -2 "$TMP/revoke.out" | tr '\n' ' ')"
fi
grep -q "gh secret delete MPS_PUBLISHER_TOKEN --env production" "$TMP/revoke.out" \
    && pass "V2 revocation also names the caller-side secret to delete" \
    || fail "V2 revocation instructions"

run "$TMP/revoke-missing.out" revoke --id not-there --entry "$ENTRY_B"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "is not in the supplied list" "$TMP/revoke-missing.out"; then
    pass "V3 revoking an id that is not in the list is refused"
else
    fail "V3 revoke missing id (exit $RUN_STATUS)"
fi

run "$TMP/revoke-last.out" revoke --id monitor --entry "$ENTRY_B"
if [ "$RUN_STATUS" -eq 0 ] && grep -q "RELEASE_PUBLISHER_CREDENTIALS   (empty — no machine credential is authorized)" "$TMP/revoke-last.out"; then
    pass "V4 removing the last credential leaves an explicitly empty list (authorizes nothing)"
else
    fail "V4 revoke last entry (exit $RUN_STATUS)"
fi

run "$TMP/revoke-noentry.out" revoke --id monitor
if [ "$RUN_STATUS" -eq 1 ] && grep -q "revoke needs the current list" "$TMP/revoke-noentry.out"; then
    pass "V5 revocation refuses to guess the current list"
else
    fail "V5 revoke without the current list (exit $RUN_STATUS)"
fi

# --- actor ------------------------------------------------------------------
run "$TMP/actor1.out" actor
run "$TMP/actor2.out" actor
ACTOR1="$(cat "$TMP/actor1.out")"
ACTOR2="$(cat "$TMP/actor2.out")"
if [ "$RUN_STATUS" -eq 0 ] \
    && printf '%s' "$ACTOR1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    && [ "$ACTOR1" != "$ACTOR2" ]; then
    pass "A1 actor prints a fresh UUID (the identity recorded on the release rows)"
else
    fail "A1 actor (exit $RUN_STATUS, '$ACTOR1')"
fi

# --- usage ------------------------------------------------------------------
run "$TMP/usage.out" bogus-command
[ "$RUN_STATUS" -eq 2 ] && pass "U1 an unknown command exits 2 (usage)" \
    || fail "U1 unknown command (exit $RUN_STATUS)"

echo ""
echo "release-publisher-credential tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
