#!/usr/bin/env bash
#
# run-publisher-tests.sh — run every offline suite in this repository.
#
# OFFLINE. No suite here contacts the network, the backend, or production, and
# none of them needs a release artifact. The `publish-release` suite replays the
# deployed lifecycle against a fake `curl`; its PART B needs a real local
# notarized candidate and SKIPs with an explicit reason when there is none —
# a skip is never reported as a pass.
#
# Each suite's exit status is captured directly (no pipeline into a filter, so a
# failure can never be hidden by the thing that formats it) and printed in the
# summary. The whole script exits non-zero if any suite failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SUITES=(
    verify-publisher-credential
    fetch-published-candidate
    verify-app-resources
    release-publisher-credential
    publish-release
)

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mps-publisher-tests.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

# The packaged-resource gate always needs its pinned reference in this repository
# (there is no application tree to default to), and the publish-release suite uses
# a real candidate when one has been fetched into candidate/. Neither is required:
# the suites SKIP their artifact-dependent cases with a reason instead of failing.
ICON_REFERENCE="$ROOT/assets/music-prod-favicon.png"
TEST_CANDIDATE="${MPS_TEST_CANDIDATE:-}"
if [ -z "$TEST_CANDIDATE" ]; then
    TEST_CANDIDATE="$(find "$ROOT/candidate" -maxdepth 2 -name 'Music-Prod-Studio-*.zip' 2>/dev/null | sort | tail -1)"
fi

failures=0
failed_names=()
passed=0

echo "Music-Prod Studio publisher — offline suites"
echo "logs: $LOG_DIR"
if [ -n "$TEST_CANDIDATE" ]; then
    echo "candidate: $TEST_CANDIDATE"
else
    echo "candidate: none found — artifact-dependent cases will SKIP (fetch one with:"
    echo "           Scripts/fetch-published-candidate.sh --version <v> --build <n> \\"
    echo "             --expect-sha <hex> --expect-size <bytes> --out candidate)"
fi
echo ""

for suite in "${SUITES[@]}"; do
    file="$ROOT/Scripts/tests/$suite.test.sh"
    log="$LOG_DIR/$suite.log"
    if [ ! -f "$file" ]; then
        printf 'MISSING  %s\n' "$suite"
        failures=$((failures + 1))
        failed_names+=("$suite (missing)")
        continue
    fi
    set +e
    MPS_ICON_REFERENCE="$ICON_REFERENCE" MPS_TEST_CANDIDATE="$TEST_CANDIDATE" \
        bash "$file" > "$log" 2>&1
    status=$?
    set -e 2>/dev/null || true
    summary="$(grep -E ':[[:space:]]*[0-9]+ passed, [0-9]+ failed' "$log" | tail -1)"
    skipped="$(grep -c '^  SKIP ' "$log" 2>/dev/null || true)"
    if [ "$status" -eq 0 ]; then
        printf 'PASS     %-32s %s%s\n' "$suite" "${summary:-ok}" \
               "${skipped:+   (skipped: $skipped)}"
        passed=$((passed + 1))
    else
        printf 'FAIL     %-32s exit %s\n' "$suite" "$status"
        failures=$((failures + 1))
        failed_names+=("$suite")
        echo "--- $suite output ---"
        cat "$log"
        echo "--- end $suite ---"
    fi
done

echo ""
echo "$passed suite(s) passed, $failures failed"
if [ "$failures" -ne 0 ]; then
    echo ""
    echo "failing suites: ${failed_names[*]}"
    exit 1
fi
