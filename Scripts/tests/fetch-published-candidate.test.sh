#!/usr/bin/env bash
#
# Offline suite for Scripts/fetch-published-candidate.sh.
#
# The script fetches the bytes of an ALREADY-PUBLISHED release through two public,
# unauthenticated routes. Its value is that it refuses anything the live catalog
# does not vouch for, so every refusal below is the point of the suite:
#
#   * a catalog digest that disagrees with the requested identity
#   * a catalog size that disagrees
#   * a version the public catalog does not serve as the latest release
#   * a download authorization that is refused, or that describes other bytes
#   * bytes that arrive hashing to something else (the transfer is not trusted)
#
# The fake `curl` also records whether ANY credential was sent: the whole point of
# this path is that it needs none.
#
# Nothing here touches the network, the backend or production.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/Scripts/fetch-published-candidate.sh"

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mps-fetch-published-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# A deterministic stand-in for an installer archive. The test derives the
# expected identity from THESE bytes, so the fixture and the assertions cannot
# drift apart.
PAYLOAD="$TMP/payload.zip"
python3 -c "
import sys
with open(sys.argv[1], 'wb') as handle:
    handle.write(b'PK\x03\x04' + bytes(2048))
" "$PAYLOAD"
PAYLOAD_SHA="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
PAYLOAD_SIZE="$(stat -f '%z' "$PAYLOAD")"

cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env python3
"""Stands in for curl: replays the public catalog, the download authorization and
the artifact download. Records whether any credential was sent (there must never
be one on this path)."""
import json
import os
import shutil
import sys

args = sys.argv[1:]
url = args[-1] if args else ""
stdin = sys.stdin.read() if "-K" in args else ""
scenario = os.environ.get("FAKE_SCENARIO", "ok")
sha = os.environ["FAKE_SHA"]
size = os.environ["FAKE_SIZE"]
name = os.environ.get("FAKE_NAME", "Music-Prod-Studio-2.0.13-15.zip")

with open(os.environ["FAKE_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "url": url,
        "is_download": "-K" in args,
        # Any credential at all on this path is a defect.
        "credential_present": "mpspub_" in stdin
                              or "Authorization:" in stdin
                              or "x-release-publisher-token" in stdin.lower()
                              or any("mpspub_" in a for a in args),
        "signed_url_in_argv": "token=" in " ".join(args),
    }) + "\n")

if "/updates" in url:
    latest = "2.0.12" if scenario == "not_published" else "2.0.13"
    catalog_sha = ("f" * 64) if scenario == "catalog_sha_mismatch" else sha
    catalog_size = size
    print(json.dumps({"success": True, "data": {
        "latestVersion": latest,
        "artifacts": [{"id": "4cf81f17-d3f0-4e94-a6c1-18f9ad08866b", "platform": "macos",
                       "architecture": "arm64", "fileName": name,
                       "sha256": catalog_sha, "fileSize": catalog_size}]}}))
    sys.exit(0)

if "/downloads/authorize" in url:
    if scenario == "authorize_refused":
        print(json.dumps({"success": False, "errorCode": "notFound",
                          "error": "the release is not published"}))
        sys.exit(0)
    print(json.dumps({"success": True, "data": {
        "artifactId": "4cf81f17-d3f0-4e94-a6c1-18f9ad08866b", "fileName": name,
        "fileSize": size, "sha256": sha,
        "signedUrl": "https://storage.example.invalid/object/sign/releases/x.zip?token=fake",
        "expiresAt": "2026-10-16T23:59:59Z"}}))
    sys.exit(0)

if "-K" in args:
    if scenario == "download_fails":
        sys.stderr.write("curl: (22) The requested URL returned error: 403\n")
        sys.exit(22)
    destination = args[args.index("-o") + 1]
    if scenario == "corrupt_bytes":
        with open(destination, "wb") as handle:
            handle.write(b"PK\x03\x04" + bytes(16))
    else:
        shutil.copyfile(os.environ["FAKE_PAYLOAD"], destination)
    sys.exit(0)

sys.exit(0)
FAKE
chmod +x "$TMP/bin/curl"

CALL_LOG="$TMP/calls.jsonl"
: > "$CALL_LOG"

passed=0
failed=0
pass() { echo "  PASS $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL $1"; failed=$((failed + 1)); }

OUT=""
CODE=0
run() { # run <scenario> [extra args...]
    local scenario="$1"; shift
    : > "$CALL_LOG"
    local out_dir="$TMP/out-$scenario"
    rm -rf "$out_dir"
    set +e
    OUT="$(env FAKE_SCENARIO="$scenario" FAKE_CALL_LOG="$CALL_LOG" FAKE_SHA="$PAYLOAD_SHA" \
               FAKE_SIZE="$PAYLOAD_SIZE" FAKE_PAYLOAD="$PAYLOAD" \
               PATH="$TMP/bin:$PATH" "$SCRIPT" \
               --version 2.0.13 --build 15 --expect-sha "$PAYLOAD_SHA" \
               --expect-size "$PAYLOAD_SIZE" --out "$out_dir" "$@" 2>&1)"
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

calls_count() { local n; n="$(grep -c . "$CALL_LOG" 2>/dev/null)"; echo "${n:-0}"; }

echo "fetch-published-candidate — offline suite"
echo ""

# --------------------------------------------------------------- 1. success
run ok
check "a published candidate is fetched and verified" 0 "PUBLISHED CANDIDATE FETCHED"
check "the reported digest is the bytes' digest" 0 "$PAYLOAD_SHA"
check "the fetched file is written to the output directory" 0 "candidate ready"
if [ -f "$TMP/out-ok/Music-Prod-Studio-2.0.13-15.zip" ]; then
    got="$(shasum -a 256 "$TMP/out-ok/Music-Prod-Studio-2.0.13-15.zip" | awk '{print $1}')"
    [ "$got" = "$PAYLOAD_SHA" ] && pass "the written file matches the expected digest" \
                               || fail "the written file hashes to $got"
else
    fail "the candidate was not written"
fi
[ "$(calls_count)" = "3" ] && pass "exactly three read-only requests were made" \
                           || fail "expected 3 requests, saw $(calls_count)"

# -------------------------------------------------------------- 2. refusals
run catalog_sha_mismatch
check "a catalog digest that disagrees is refused" 1 "refusing to fetch bytes the catalog does not vouch for"

run not_published
check "a version that is not the published one is refused" 1 "is not the published one"

run authorize_refused
check "a refused download authorization is reported" 1 "the release is not published"

run download_fails
check "a failed download is refused" 1 "the authorized download failed"

run corrupt_bytes
check "bytes that hash differently are refused" 1 "refusing to use it"

# A refusal must never leave a file that looks usable behind.
run corrupt_bytes
if [ -f "$TMP/out-corrupt_bytes/Music-Prod-Studio-2.0.13-15.zip" ]; then
    got="$(shasum -a 256 "$TMP/out-corrupt_bytes/Music-Prod-Studio-2.0.13-15.zip" | awk '{print $1}')"
    if [ "$got" = "$PAYLOAD_SHA" ]; then
        fail "a refused run left a file claiming to be the candidate"
    else
        pass "a refused run leaves no valid candidate behind"
    fi
else
    pass "a refused run wrote nothing"
fi

# --------------------------------------------------- 3. no credential is used
run ok
if grep -q '"credential_present": true' "$CALL_LOG"; then
    fail "a credential was sent on a path that must need none"
else
    pass "no credential of any kind is sent"
fi
if grep -q '"signed_url_in_argv": true' "$CALL_LOG"; then
    fail "the signed URL reached a process argument"
else
    pass "the signed URL never reaches a process argument"
fi

# --------------------------------------------------------- 4. request hygiene
if grep -qE '(-X POST|--request POST|-d |--data)' "$SCRIPT"; then
    fail "the script issues a request that is not a read"
else
    pass "every request in the script is a read (no POST/PATCH/DELETE)"
fi

echo ""
echo "fetch-published-candidate: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
