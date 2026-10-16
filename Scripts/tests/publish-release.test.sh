#!/bin/bash
# Offline suite for Scripts/publish-release.sh.
#
# The script publishes to PRODUCTION, so its failure paths matter more than its
# happy path: every assertion below is either a STOP that must fire BEFORE the
# mutation it guards, or a property of the CREDENTIAL it exists to carry.
#
# `fixtures/publish-release.fakecurl.py` stands in for curl and replays the
# deployed admin-API sequence, so nothing here touches the network, the backend,
# or anything under /Applications. The fake curl also records, per call, WHICH
# credential travelled (`auth=publisher|admin|none`), whether it travelled in a
# header, and whether it ever reached a process argument — the last one is the
# script's promise that `ps` can never capture it.
#
# PART A is artifact-independent (arguments, release record, credential handling)
# and always runs. PART B replays the deployed lifecycle and needs the real
# notarized candidate, which lives in the (git-ignored) build/ tree; without it
# PART B SKIPs with an explicit reason rather than silently passing — the same
# rule the other release suites follow for artifacts only a release run produces.
# PART P exercises the hidden prompt on a REAL pty (fixtures/pty_prompt_probe.py)
# and, like the other prompt tests, needs no artifact at all.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/Scripts/publish-release.sh"
FAKE="$HERE/fixtures/publish-release.fakecurl.py"
PROBE="$HERE/fixtures/pty_prompt_probe.py"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mps-publish-release-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cp "$FAKE" "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
# A file that is never a real candidate: the prompt tests stop on the digest,
# which is checked after the credential has been classified.
: > "$TMP/not-a-candidate.zip"
BOGUS_SHA="$(python3 -c 'print("e" * 64)')"

# A well-formed but entirely bogus machine credential (never a real secret).
PUBLISHER_TOKEN="$(python3 -c "print('mpspub_ci-test_' + 's' * 43)")"
ADMIN_TOKEN="aaa.bbb.ccc"
TOKEN_FILE="$TMP/publisher.token"
INSECURE_TOKEN_FILE="$TMP/publisher-insecure.token"
printf '%s\n' "$PUBLISHER_TOKEN" > "$TOKEN_FILE"
printf '%s\n' "$PUBLISHER_TOKEN" > "$INSECURE_TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
chmod 644 "$INSECURE_TOKEN_FILE"
NOTES_FILE="$TMP/notes.txt"
printf 'Music-Prod Studio — offline suite release notes.\n' > "$NOTES_FILE"
EMPTY_NOTES_FILE="$TMP/empty-notes.txt"
: > "$EMPTY_NOTES_FILE"

passed=0
failed=0
skipped=0
pass() { echo "  PASS $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL $1"; failed=$((failed + 1)); }
skip() { echo "  SKIP $1"; skipped=$((skipped + 1)); }

# --- the candidate (PART B) -------------------------------------------------
# A REAL candidate is used whenever one is available, in this order:
#   MPS_TEST_CANDIDATE, a local release build tree, a candidate fetched into
#   candidate/ (Scripts/fetch-published-candidate.sh --out candidate).
# PART A is artifact-independent, so it still runs with none: every refusal it
# asserts fires long before the packaged-resource gate, and an empty file is
# enough for it to reach the guard under test. The cases that do walk as far as
# that gate (A11, A23) and PART B need the real bytes and SKIP with that reason —
# they are never reported as passing.
HAVE_CANDIDATE=0
CANDIDATE="${MPS_TEST_CANDIDATE:-}"
if [ -z "$CANDIDATE" ]; then
    CANDIDATE="$(find "$REPO_ROOT/build" "$REPO_ROOT/candidate" -maxdepth 3 \
        -name 'Music-Prod-Studio-*.zip' 2>/dev/null | sort | tail -1)"
fi
if [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ] && [ -s "$CANDIDATE" ]; then
    HAVE_CANDIDATE=1
else
    CANDIDATE="$TMP/not-a-candidate.zip"
fi
FAKE_VERSION="2.0.13"; FAKE_PREVIOUS="2.0.12"; FAKE_SHA=""; FAKE_SIZE=""; FAKE_NAME=""
if [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ]; then
    FAKE_NAME="$(basename "$CANDIDATE")"
    FAKE_SHA="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
    FAKE_SIZE="$(stat -f '%z' "$CANDIDATE")"
    FAKE_VERSION="$(printf '%s' "$FAKE_NAME" | sed -nE 's/.*-([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+\.zip$/\1/p')"
    [ -n "$FAKE_VERSION" ] || FAKE_VERSION="2.0.13"
    FAKE_PREVIOUS="$(python3 -c "v='$FAKE_VERSION'.split('.');v[2]=str(int(v[2])-1);print('.'.join(v))")"
fi

# run <scenario|-> <credential-mode> [script args…]
#   credential-mode: publisher | admin | none | token-file | token-file-insecure
#                    | require-publisher-admin
# Sets RUN_STATUS, and writes $TMP/out and $TMP/log.
run() {
    rm -f "$TMP/counter" "$TMP/log"
    local scenario="$1" credential="$2"; shift 2
    local env_args=(-u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN -u MPS_PUBLISHER_TOKEN_FILE
                    -u MPS_REQUIRE_PUBLISHER_CREDENTIAL
                    PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" FAKECURL_LOG="$TMP/log"
                    FAKECURL_ARTIFACT="${CANDIDATE:-/dev/null}"
                    FAKE_VERSION="$FAKE_VERSION" FAKE_PREVIOUS="$FAKE_PREVIOUS" FAKE_SHA="$FAKE_SHA"
                    FAKE_SIZE="$FAKE_SIZE" FAKE_NAME="$FAKE_NAME"
                    FAKE_CURRENT_NOTES="$(printf '%s' "$(cat "$NOTES_FILE")")")
    [ -n "$scenario" ] && env_args+=(SCENARIO="$scenario")
    case "$credential" in
        publisher)               env_args+=(MPS_PUBLISHER_TOKEN="$PUBLISHER_TOKEN") ;;
        admin)                   env_args+=(MPS_ADMIN_TOKEN="$ADMIN_TOKEN") ;;
        none)                    ;;
        token-file)              env_args+=(MPS_PUBLISHER_TOKEN_FILE="$TOKEN_FILE") ;;
        token-file-insecure)     env_args+=(MPS_PUBLISHER_TOKEN_FILE="$INSECURE_TOKEN_FILE") ;;
        require-publisher-admin) env_args+=(MPS_ADMIN_TOKEN="$ADMIN_TOKEN" MPS_REQUIRE_PUBLISHER_CREDENTIAL=1) ;;
        *) echo "run: unknown credential mode $credential" >&2; exit 2 ;;
    esac
    env "${env_args[@]}" bash "$SCRIPT" "$@" < /dev/null > "$TMP/out" 2>&1
    RUN_STATUS=$?
}

# The identity arguments every invocation needs. A bash array (not a helper that
# prints words) so word splitting is explicit and every call site is quoted.
IDENTITY=(--version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS"
          --zip "$CANDIDATE" --release-notes-file "$NOTES_FILE")

calls_made() { [ -f "$TMP/counter" ] && [ "$(cat "$TMP/counter")" -gt 0 ]; }
no_calls() { ! calls_made; }
post_call() { [ -f "$TMP/log" ] && grep -q "^POST .*$1" "$TMP/log"; }
only_auth() { # only_auth <publisher|admin>: that credential was used, the other never was
    [ -f "$TMP/log" ] || return 1
    grep -q "auth=$1" "$TMP/log" || return 1
    if [ "$1" = publisher ]; then ! grep -q "auth=admin" "$TMP/log"; else ! grep -q "auth=publisher" "$TMP/log"; fi
}
log_no_credential_in_argv() { [ -f "$TMP/log" ] && ! grep -q "argv_has_credential=yes" "$TMP/log"; }
log_header_carried() { [ -f "$TMP/log" ] && grep -q "header_has_credential=yes" "$TMP/log"; }

# A release manifest in release-finalize.sh's own format (one `"key": "value",`
# line per field, NOT JSON), with any field overridable by name=value pairs.
write_manifest() { # write_manifest <file> [key=value …]
    local file="$1"; shift
    local mode=production submitted=yes stapled=yes evidence=PASS gate=PASS
    local version="$FAKE_VERSION" build=99 name="$FAKE_NAME" sha="$FAKE_SHA" size="$FAKE_SIZE"
    local kv
    for kv in "$@"; do
        case "${kv%%=*}" in
            mode) mode="${kv#*=}" ;;
            notarizationSubmitted) submitted="${kv#*=}" ;;
            stapled) stapled="${kv#*=}" ;;
            evidenceVerdict) evidence="${kv#*=}" ;;
            finalGateResult) gate="${kv#*=}" ;;
            version) version="${kv#*=}" ;;
            buildNumber) build="${kv#*=}" ;;
            finalZipName) name="${kv#*=}" ;;
            finalZipSha256) sha="${kv#*=}" ;;
            finalZipBytes) size="${kv#*=}" ;;
            *) echo "write_manifest: unknown field ${kv%%=*}" >&2; exit 2 ;;
        esac
    done
    {
        printf '  "credentialProfile": "MusicProdNotarization",\n'
        printf '  "mode": "%s",\n' "$mode"
        printf '  "notarizationSubmitted": "%s",\n' "$submitted"
        printf '  "stapled": "%s",\n' "$stapled"
        printf '  "sourceCommit": "%s",\n' "9160ff12e978d19b0b2a5a5a761be0fab64288fe"
        printf '  "sourceBranch": "%s",\n' "studio-updater-qa"
        printf '  "version": "%s",\n' "$version"
        printf '  "buildNumber": "%s",\n' "$build"
        printf '  "finalZipName": "%s",\n' "$name"
        printf '  "finalZipSha256": "%s",\n' "$sha"
        printf '  "finalZipBytes": "%s",\n' "$size"
        printf '  "evidenceVerdict": "%s",\n' "$evidence"
        printf '  "finalGateResult": "%s",\n' "$gate"
    } > "$file"
}

echo "publish-release.sh — credential-driven publication suite"
echo ""

# ===========================================================================
# C. the guard rails are structural, not incidental
# ===========================================================================
grep -qE '^\s*set -x' "$SCRIPT" && fail "C1 the script enables xtrace (would leak the credential)" \
    || pass "C1 no xtrace anywhere in the script"
grep -q 'curl -sS -K -' "$SCRIPT" && pass "C2 the credential travels via a stdin config, never argv" \
    || fail "C2 the credential does not travel via a stdin config"
grep -q 'X-Release-Publisher-Token: %s' "$SCRIPT" \
    && pass "C3 the publisher credential is sent in its own header" \
    || fail "C3 the publisher header is missing"
grep -q 'MPS_REQUIRE_PUBLISHER_CREDENTIAL' "$SCRIPT" \
    && pass "C4 the script can refuse to publish with a human token" \
    || fail "C4 MPS_REQUIRE_PUBLISHER_CREDENTIAL is not honoured"
grep -qF -- "-t \"\$remaining\" -d '' char" "$SCRIPT" \
    && pass "C5 the byte reader makes NUL the delimiter (read cannot eat Enter)" \
    || fail "C5 the byte reader does not use -d ''"
grep -qF -- '[ -n "$char" ] || break' "$SCRIPT" \
    && pass "C6 a successful empty read is treated as End-of-line, not 'keep waiting'" \
    || fail "C6 an empty successful read is not handled as Enter"

# ===========================================================================
# A. arguments, the release record, and the credential (artifact-independent)
# ===========================================================================
echo ""
echo "  --- arguments and identity ---"

run "" publisher --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q -- "--version is required" "$TMP/out" && no_calls; then
    pass "A1 a missing --version stops before any call"
else
    fail "A1 missing --version (exit $RUN_STATUS, calls $(cat "$TMP/counter" 2>/dev/null || echo 0))"
fi

run "" publisher --version "2.0" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --sha256 "$FAKE_SHA" --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "must be a semantic version" "$TMP/out" && no_calls; then
    pass "A2 a non-semantic version is refused"
else
    fail "A2 non-semantic version (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_VERSION" --zip "$CANDIDATE" \
    --sha256 "$FAKE_SHA" --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "a release never replaces the version it supersedes" "$TMP/out" && no_calls; then
    pass "A3 publishing the currently published version is refused"
else
    fail "A3 same-version guard (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_PREVIOUS" --previous-version "$FAKE_VERSION" --zip "$CANDIDATE" \
    --sha256 "$FAKE_SHA" --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "the version arguments are not consistent" "$TMP/out" && no_calls; then
    pass "A4 a version older than the published one is refused"
else
    fail "A4 version monotonicity (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "a release identity is required" "$TMP/out" && no_calls; then
    pass "A5 a release with no digest and no manifest is refused"
else
    fail "A5 missing identity (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --sha256 "not-a-digest" --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "64 lowercase hex" "$TMP/out" && no_calls; then
    pass "A6 a malformed digest is refused"
else
    fail "A6 malformed digest (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --sha256 "$FAKE_SHA" --release-notes-file "$TMP/absent-notes.txt"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "release notes file not found" "$TMP/out" && no_calls; then
    pass "A7 missing release notes stop the run"
else
    fail "A7 missing release notes (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --sha256 "$FAKE_SHA" --release-notes-file "$EMPTY_NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "release notes file is empty" "$TMP/out" && no_calls; then
    pass "A8 empty release notes stop the run"
else
    fail "A8 empty release notes (exit $RUN_STATUS)"
fi

run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$TMP/absent.zip" \
    --sha256 "$FAKE_SHA" --release-notes-file "$NOTES_FILE"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "candidate ZIP not found" "$TMP/out" && no_calls; then
    pass "A9 a missing candidate stops before any call"
else
    fail "A9 missing candidate (exit $RUN_STATUS)"
fi

run "" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --filename "Something-Else.zip"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "the published name and the published bytes must be the same file" "$TMP/out" && no_calls; then
    pass "A10 a filename that is not the candidate's own name is refused"
else
    fail "A10 filename mismatch (exit $RUN_STATUS)"
fi

echo ""
echo "  --- the release record (release-finalize manifest) ---"

M="$TMP/manifest.json"
write_manifest "$M"
run "resume" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --release-notes-file "$NOTES_FILE" --manifest "$M" --inspect
if [ "$RUN_STATUS" -eq 0 ] && grep -q "release record: $M" "$TMP/out" && grep -q "INSPECTION ONLY" "$TMP/out"; then
    pass "A11 a complete, stapled, evidence-PASS release record is accepted"
elif [ "$HAVE_CANDIDATE" != "1" ]; then
    skip "A11 needs a real candidate bundle (this case walks as far as the packaged-resource gate; set MPS_TEST_CANDIDATE)"
else
    fail "A11 release record acceptance (exit $RUN_STATUS): $(tail -2 "$TMP/out" | tr '\n' ' ')"
fi

write_manifest "$M" mode=dry-run
run "" publisher "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "a rehearsal is not publishable" "$TMP/out" && no_calls; then
    pass "A12 a dry-run record is refused"
else
    fail "A12 dry-run record (exit $RUN_STATUS)"
fi

write_manifest "$M" stapled=no
run "" publisher "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "only a stapled artifact is a publication identity" "$TMP/out" && no_calls; then
    pass "A13 an unstapled record is refused"
else
    fail "A13 unstapled record (exit $RUN_STATUS)"
fi

write_manifest "$M" notarizationSubmitted=no
run "" publisher "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "an unsubmitted artifact is never published" "$TMP/out" && no_calls; then
    pass "A14 an unsubmitted record is refused"
else
    fail "A14 unsubmitted record (exit $RUN_STATUS)"
fi

write_manifest "$M" evidenceVerdict=FAIL
run "" publisher "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "evidence must PASS" "$TMP/out" && no_calls; then
    pass "A15 a failed-evidence record is refused"
else
    fail "A15 failed evidence (exit $RUN_STATUS)"
fi

write_manifest "$M" finalGateResult=FAIL
run "" publisher "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "the final gate must PASS" "$TMP/out" && no_calls; then
    pass "A16 a failed final gate is refused"
else
    fail "A16 failed final gate (exit $RUN_STATUS)"
fi

write_manifest "$M" finalZipSha256="$(python3 -c 'print("d" * 64)')"
run "" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "disagrees with the release manifest" "$TMP/out" && no_calls; then
    pass "A17 a digest that disagrees with the record is refused, never guessed"
else
    fail "A17 digest disagreement (exit $RUN_STATUS)"
fi

write_manifest "$M" version="1.2.3"
run "" publisher "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "disagrees with the release manifest's version" "$TMP/out" && no_calls; then
    pass "A18 a version that disagrees with the record is refused"
else
    fail "A18 version disagreement (exit $RUN_STATUS)"
fi

write_manifest "$M"
# An incomplete record (a field never written) must stop the run rather than
# default to something optimistic.
grep -v '"stapled":' "$M" > "$TMP/manifest-partial.json"
run "" publisher "${IDENTITY[@]}" --manifest "$TMP/manifest-partial.json"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "refusing to publish from an incomplete release record" "$TMP/out" && no_calls; then
    pass "A19 an incomplete release record is refused"
else
    fail "A19 incomplete record (exit $RUN_STATUS)"
fi

echo ""
echo "  --- the credential (the whole point) ---"

run "" none "${IDENTITY[@]}" --sha256 "$FAKE_SHA"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "no credential was supplied and no interactive terminal" "$TMP/out" && no_calls; then
    pass "A20 with no credential and no terminal the run stops with a named reason (never hangs)"
else
    fail "A20 missing credential (exit $RUN_STATUS)"
fi

run "" admin "${IDENTITY[@]}" --sha256 "$FAKE_SHA"
if grep -q "using a human admin access token from MPS_ADMIN_TOKEN" "$TMP/out" \
    && ! grep -q "STOP: the supplied value" "$TMP/out" \
    && { no_calls || only_auth admin; }; then
    pass "A21 a human access token is accepted as the manual fallback"
else
    fail "A21 admin fallback (exit $RUN_STATUS): $(tail -2 "$TMP/out" | tr '\n' ' ')"
fi

run "" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA"
if grep -q "using the release publisher credential from MPS_PUBLISHER_TOKEN" "$TMP/out"; then
    pass "A22 the publisher credential is taken from the environment"
else
    fail "A22 publisher environment credential: $(tail -2 "$TMP/out" | tr '\n' ' ')"
fi

run "resume" token-file --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
    --release-notes-file "$NOTES_FILE" --manifest "$M" --inspect
if [ "$RUN_STATUS" -eq 0 ] && grep -q "using the release publisher credential from MPS_PUBLISHER_TOKEN_FILE" "$TMP/out"; then
    pass "A23 a 0600 credential file is accepted"
elif [ "$HAVE_CANDIDATE" != "1" ]; then
    skip "A23 needs a real candidate bundle (this case walks as far as the packaged-resource gate; set MPS_TEST_CANDIDATE)"
else
    fail "A23 credential file mode 600 (exit $RUN_STATUS): $(tail -2 "$TMP/out" | tr '\n' ' ')"
fi

run "" token-file-insecure "${IDENTITY[@]}" --manifest "$M"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "must not be group- or world-readable" "$TMP/out" && no_calls; then
    pass "A24 a credential file readable by others is refused"
else
    fail "A24 credential file mode 644 (exit $RUN_STATUS)"
fi

run "" require-publisher-admin "${IDENTITY[@]}" --sha256 "$FAKE_SHA"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "refusing to publish with a pasted token" "$TMP/out" && no_calls; then
    pass "A25 automation cannot fall back to a human token (MPS_REQUIRE_PUBLISHER_CREDENTIAL)"
else
    fail "A25 publisher-credential requirement (exit $RUN_STATUS)"
fi

run "" publisher "${IDENTITY[@]}" --sha256 "$BOGUS_SHA"
if [ "$RUN_STATUS" -eq 1 ] && grep -q "refusing to publish different bytes" "$TMP/out" && no_calls; then
    pass "A26 the local ZIP is hashed: different bytes are refused before any call"
else
    fail "A26 local digest guard (exit $RUN_STATUS)"
fi

# A value in no credential shape is refused by name, before any call. This is
# the environment path (the prompt path is covered in PART P).
rm -f "$TMP/counter" "$TMP/log"
env MPS_PUBLISHER_TOKEN=hello PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
    bash "$SCRIPT" "${IDENTITY[@]}" --sha256 "$FAKE_SHA" < /dev/null > "$TMP/out" 2>&1
STATUS=$?
if [ "$STATUS" -eq 1 ] && grep -q "not one (expected mpspub_" "$TMP/out" && no_calls; then
    pass "A27 a value in no credential shape is refused before any call"
else
    fail "A27 bogus credential shape (exit $STATUS): $(tail -2 "$TMP/out" | tr '\n' ' ')"
fi

# ===========================================================================
# P. the hidden prompt, on a real pty (no artifact needed)
# ===========================================================================
echo ""
echo "  --- the hidden prompt on a real terminal ---"

if [ ! -f "$PROBE" ]; then
    skip "P1–P6 the pty probe is missing: $PROBE"
    skipped=$((skipped + 6))
elif ! command -v python3 > /dev/null 2>&1; then
    skip "P1–P6 no python3 on this host"
    skipped=$((skipped + 6))
else
    # pty_case <name> <send|-> <press-enter|no-enter> <expected-text> [extra env…]
    # Every case stops on the bogus digest, so nothing reaches the network.
    pty_case() {
        local name="$1" send="$2" enter="$3" expected="$4"; shift 4
        rm -f "$TMP/counter" "$TMP/log"
        local probe_args=(--max-wait 30)
        if [ "$send" != "-" ]; then
            probe_args+=(--send "$send")
            [ "$enter" = "press-enter" ] && probe_args+=(--press-enter)
            probe_args+=(--send-after 'access_token: ')
        fi
        env -u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN -u MPS_PUBLISHER_TOKEN_FILE \
            "$@" PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
            python3 "$PROBE" "${probe_args[@]}" -- \
            env -u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN -u MPS_PUBLISHER_TOKEN_FILE \
            PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
            bash "$SCRIPT" --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" \
            --zip "$TMP/not-a-candidate.zip" --sha256 "$BOGUS_SHA" \
            --release-notes-file "$NOTES_FILE" > "$TMP/pty.out" 2>&1
        if ! grep -q "^exit=1$" "$TMP/pty.out"; then
            fail "$name (exit $(grep -m1 '^exit=' "$TMP/pty.out"), $(grep -m1 '^elapsed=' "$TMP/pty.out"))"
            return 1
        fi
        if ! grep -qF "$expected" "$TMP/pty.out"; then
            fail "$name (missing: $expected)"
            return 1
        fi
        if calls_made; then
            fail "$name (the API was called before the credential was accepted)"
            return 1
        fi
        pass "$name"
    }

    pty_case "P1 a typed publisher token is classified as the machine credential" \
        "$PUBLISHER_TOKEN" press-enter "credential id: ci-test"
    if pty_case "P2 a typed JWT is classified as the human fallback" \
        "$ADMIN_TOKEN" press-enter "credential: human admin access token"; then
        grep -q '^echo_at_prompt=off$' "$TMP/pty.out" \
            && pass "P2b echo is off while the prompt is up (the value cannot be seen)" \
            || fail "P2b echo state at the prompt ($(grep -m1 '^echo_at_prompt=' "$TMP/pty.out"))"
        grep -q '^transcript_has_send=no$' "$TMP/pty.out" \
            && pass "P2c the typed value is NOT echoed back to the terminal" \
            || fail "P2c the typed value appeared in the transcript"
        grep -q '^modes_restored=yes$' "$TMP/pty.out" \
            && pass "P2d terminal modes are restored after a successful read" \
            || fail "P2d terminal modes after the prompt ($(grep -m1 '^modes_restored=' "$TMP/pty.out"))"
    else
        skipped=$((skipped + 3))
    fi
    pty_case "P3 a value in no credential shape is refused by name" \
        "hello" press-enter "is neither a publisher credential"
    pty_case "P4 bare Enter ends the prompt and fails the no-credential guard" \
        "" press-enter "no credential supplied"

    # P5: nothing typed while the terminal stays open: the bound must end the wait.
    rm -f "$TMP/counter" "$TMP/log"
    env -u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN MPS_TOKEN_PROMPT_TIMEOUT=3 \
        PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
        python3 "$PROBE" --max-wait 20 -- \
        env -u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN MPS_TOKEN_PROMPT_TIMEOUT=3 \
        PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
        bash "$SCRIPT" --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" \
        --zip "$TMP/not-a-candidate.zip" --sha256 "$BOGUS_SHA" \
        --release-notes-file "$NOTES_FILE" > "$TMP/pty-p5.out" 2>&1
    if grep -q "no credential was entered within 3s" "$TMP/pty-p5.out" && grep -q '^exit=1$' "$TMP/pty-p5.out" \
        && grep -q '^modes_restored=yes$' "$TMP/pty-p5.out" && ! calls_made; then
        pass "P5 the prompt times out with a named reason instead of waiting"
    else
        fail "P5 prompt timeout ($(grep -m1 '^elapsed=' "$TMP/pty-p5.out"), $(grep -m1 '^modes_restored=' "$TMP/pty-p5.out"))"
    fi

    # P6: interrupted while waiting — the failure that once left terminals with
    # echo disabled, looking dead to the operator.
    rm -f "$TMP/counter" "$TMP/log"
    env -u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN MPS_TOKEN_PROMPT_TIMEOUT=60 \
        PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
        python3 "$PROBE" --signal SIGTERM --signal-delay 1 --max-wait 15 -- \
        env -u MPS_PUBLISHER_TOKEN -u MPS_ADMIN_TOKEN MPS_TOKEN_PROMPT_TIMEOUT=60 \
        PATH="$TMP/bin:$PATH" FAKECURL_COUNTER="$TMP/counter" \
        bash "$SCRIPT" --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" \
        --zip "$TMP/not-a-candidate.zip" --sha256 "$BOGUS_SHA" \
        --release-notes-file "$NOTES_FILE" > "$TMP/pty-p6.out" 2>&1
    if grep -q '^exit=143$' "$TMP/pty-p6.out" && grep -q '^modes_restored=yes$' "$TMP/pty-p6.out" && ! calls_made; then
        pass "P6 SIGTERM at the prompt restores the terminal and exits (143)"
    else
        fail "P6 SIGTERM while waiting (exit $(grep -m1 '^exit=' "$TMP/pty-p6.out"), $(grep -m1 '^modes_restored=' "$TMP/pty-p6.out"))"
    fi
fi

# ===========================================================================
# B. the deployed lifecycle, against the real notarized candidate
# ===========================================================================
echo ""
echo "  --- the deployed lifecycle (publisher credential) ---"

if [ "$HAVE_CANDIDATE" != "1" ]; then
    skip "B1–B24 no notarized candidate available (set MPS_TEST_CANDIDATE, or fetch one into candidate/)"
    echo "      the publication guards are only meaningful against the artifact they would publish."
    skipped=$((skipped + 24))
else
    # B1: the happy path, authenticated by the MACHINE credential.
    run "" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 0 ] && grep -q "PUBLISHED: music-prod-studio $FAKE_VERSION" "$TMP/out"; then
        pass "B1 a fresh release reaches PUBLISHED with the publisher credential (exit 0)"
    else
        fail "B1 publisher publication (exit $RUN_STATUS): $(tail -3 "$TMP/out" | tr '\n' ' ')"
    fi
    only_auth publisher && pass "B2 every call carried the publisher credential (never the human one)" \
        || fail "B2 the publisher credential was not the only one used ($(grep -m1 auth= "$TMP/log" 2>/dev/null))"
    log_no_credential_in_argv && pass "B3 the credential never reached a process argument" \
        || fail "B3 the credential appeared in argv"
    log_header_carried && pass "B4 the credential travelled in a header" \
        || fail "B4 the credential did not travel in a header"
    grep -q "credential id: ci-test" "$TMP/out" \
        && pass "B5 the credential id (never the secret) is reported" \
        || fail "B5 the credential id is not reported"
    sequence_ok=1
    for step in "/admin/releases " "/ready" "/submit" "/approve" "/publish"; do
        post_call "$step" || sequence_ok=0
    done
    [ "$sequence_ok" = 1 ] && pass "B6 the deployed create -> validate -> submit -> approve -> publish sequence is performed" \
        || fail "B6 the deployed lifecycle sequence is incomplete"
    grep -q "downloaded $FAKE_NAME through /downloads/authorize" "$TMP/out" \
        && pass "B7 the authorized download returned exactly the candidate bytes" \
        || fail "B7 download smoke test"
    grep -q "packaged resources verified against the shipped ZIP" "$TMP/out" \
        && pass "B8 the startup-critical resource gate ran on the shipped bytes" \
        || fail "B8 the packaged-resource gate did not run"
    grep -q "$PUBLISHER_TOKEN" "$TMP/out" && fail "B9 the credential was echoed into the output" \
        || pass "B9 the credential never appears in the script's output"

    # B10: the manual fallback still works, unchanged.
    run "" admin "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 0 ] && only_auth admin && log_no_credential_in_argv; then
        pass "B10 the human admin access token still publishes (manual fallback intact)"
    else
        fail "B10 admin fallback publication (exit $RUN_STATUS, $(grep -m1 auth= "$TMP/log" 2>/dev/null))"
    fi

    # B11: a credential file publishes too, and keeps the secret out of argv.
    run "" token-file "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 0 ] && only_auth publisher && log_no_credential_in_argv; then
        pass "B11 a 0600 credential file publishes with the publisher credential"
    else
        fail "B11 credential-file publication (exit $RUN_STATUS)"
    fi

    # B12: read-only inspection mutates nothing.
    run "resume" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE" --inspect
    if [ "$RUN_STATUS" -eq 0 ] && grep -q "INSPECTION ONLY" "$TMP/out" && ! grep -q "^POST " "$TMP/log"; then
        pass "B12 --inspect reports the state and issues no mutating call"
    else
        fail "B12 --inspect (exit $RUN_STATUS)"
    fi

    # B13: a release record supplies the same identity end to end.
    write_manifest "$TMP/manifest-live.json"
    run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
        --release-notes-file "$NOTES_FILE" --manifest "$TMP/manifest-live.json"
    if [ "$RUN_STATUS" -eq 0 ] && grep -q "PUBLISHED: music-prod-studio $FAKE_VERSION" "$TMP/out"; then
        pass "B13 a release record supplies the publication identity end to end"
    else
        fail "B13 manifest-driven publication (exit $RUN_STATUS): $(tail -3 "$TMP/out" | tr '\n' ' ')"
    fi

    # B14: resuming adopts the existing release and never repeats a mutation.
    run "resume" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 0 ] && grep -q "adopting the existing $FAKE_VERSION release" "$TMP/out" \
        && grep -q "NOT re-uploading" "$TMP/out" && ! post_call "/admin/releases " && ! post_call "/artifacts"; then
        pass "B14 a partially published release is resumed: no second draft, no second artifact"
    else
        fail "B14 resume (exit $RUN_STATUS): $(tail -3 "$TMP/out" | tr '\n' ' ')"
    fi

    # B15: an already published release is verified, never mutated.
    run "alreadypublished" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 0 ] && grep -q "PUBLISHED: music-prod-studio $FAKE_VERSION" "$TMP/out" \
        && ! grep -q "^POST " "$TMP/log"; then
        pass "B15 an already published release is verified without repeating a transition"
    else
        fail "B15 already-published verification (exit $RUN_STATUS)"
    fi

    # B24: a version the catalog ALREADY serves is still inspectable. The
    # catalog's releaseNotes then describe THIS version, not the previous one, so
    # comparing them with the previous version's row (which never carried them)
    # made every re-inspection of a published release impossible — the state a
    # release run leaves behind and the one an operator re-checks.
    run "alreadypublished" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE" --inspect
    if [ "$RUN_STATUS" -eq 0 ] && grep -q "ALREADY serves $FAKE_VERSION" "$TMP/out" \
        && grep -q "INSPECTION ONLY" "$TMP/out" && ! grep -q "^POST " "$TMP/log"; then
        pass "B24 a version the catalog already serves is inspected end to end (nothing modified)"
    else
        fail "B24 verification-pass inspection (exit $RUN_STATUS): $(tail -2 "$TMP/out" | tr '\n' ' ')"
    fi

    echo ""
    echo "  --- guards that must fire (they refuse BEFORE the mutation they guard) ---"

    run "artifactmismatch" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "carries sha" "$TMP/out" && ! post_call "/artifacts" && ! grep -q "^POST " "$TMP/log"; then
        pass "B16 an existing artifact that is not this candidate stops the run, untouched"
    else
        fail "B16 existing-artifact guard (exit $RUN_STATUS)"
    fi

    run "foreignversion" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] \
        && grep -q "records different release notes than this run would publish" "$TMP/out" \
        && ! grep -q "^POST " "$TMP/log"; then
        pass "B17 a row for this version that is not the release this run would publish is never adopted"
    else
        fail "B17 foreign-version guard (exit $RUN_STATUS): $(tail -2 "$TMP/out" | tr '\n' ' ')"
    fi

    run "wrongproduct" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "refusing to guess the product" "$TMP/out" && ! grep -q "^POST " "$TMP/log"; then
        pass "B18 a previous-version row that is not this product is refused"
    else
        fail "B18 product-identity guard (exit $RUN_STATUS)"
    fi

    run "notready" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "readiness report is not ready" "$TMP/out" && ! grep -q "^POST " "$TMP/log"; then
        pass "B19 an unready release is not walked further"
    else
        fail "B19 readiness guard (exit $RUN_STATUS)"
    fi

    run "uploadmismatch" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "server-computed SHA mismatch" "$TMP/out" && ! post_call "/publish"; then
        pass "B20 a server-side digest mismatch is refused before publication"
    else
        fail "B20 upload digest guard (exit $RUN_STATUS)"
    fi

    run "mismatch" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "post-publication verification failed" "$TMP/out"; then
        pass "B21 a catalog serving the wrong artifact refuses to report success"
    else
        fail "B21 post-publication verification guard (exit $RUN_STATUS)"
    fi

    run "downloadcorrupt" publisher "${IDENTITY[@]}" --sha256 "$FAKE_SHA" --size "$FAKE_SIZE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "the downloaded file's SHA-256 is" "$TMP/out"; then
        pass "B22 a corrupted download is refused (the served bytes are not the candidate)"
    else
        fail "B22 download digest guard (exit $RUN_STATUS)"
    fi

    # B23: a wrong-version argument against a real artifact is still refused
    # before any call, so a mislabelled run can never move server state.
    run "" publisher --version "$FAKE_VERSION" --previous-version "$FAKE_PREVIOUS" --zip "$CANDIDATE" \
        --sha256 "$BOGUS_SHA" --release-notes-file "$NOTES_FILE"
    if [ "$RUN_STATUS" -eq 1 ] && grep -q "refusing to publish different bytes" "$TMP/out" && no_calls; then
        pass "B23 a mislabelled artifact is refused before any call"
    else
        fail "B23 mislabelled artifact (exit $RUN_STATUS)"
    fi
fi

echo ""
echo "publish-release tests: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
