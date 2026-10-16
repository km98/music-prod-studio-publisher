#!/bin/bash
# fetch-published-candidate.sh — retrieve the notarized candidate for a version
# that is ALREADY PUBLISHED, through the public read-only endpoints the release
# service already supports. NO credential, NO private repository, NO token.
#
# WHY THIS EXISTS
#   The publisher run has to start from the exact bytes users download. Two
#   public, unauthenticated routes already answer that question:
#
#     GET /updates?product=<p>&platform=macos&current=<v>
#       -> data.latestVersion + data.artifacts[] {id, fileName, sha256, fileSize}
#     GET /downloads/authorize?artifactId=<uuid>
#       -> the server re-states that identity and mints a short-lived signed URL
#
#   For Music-Prod Studio the deployed download policy is `public` (the desktop
#   app must be able to update itself without an account), so `downloads/authorize`
#   needs no identity at all. The artifact id is a LOOKUP KEY only: what the file
#   IS is decided by the server-reported sha256/size, and then again by hashing the
#   bytes that actually arrive. Both must agree with BOTH the live catalog and the
#   identity the run was asked to publish.
#
# WHAT IT NEVER DOES
#   * no POST/PATCH/DELETE — every request is a read-only GET
#   * no credential of any kind is sent or needed
#   * nothing is rebuilt, re-signed or modified; the bytes are only written to the
#     output directory
#
# USAGE
#   fetch-published-candidate.sh --version <v> [--build <n>]
#       --expect-sha <64-hex> --expect-size <bytes> --out <dir>
#       [--product <slug>] [--current <v>]
#
# Exit codes: 0 = the candidate was fetched and every identity agreed
#             1 = refused (named reason; nothing was written)
#             2 = usage error

set -uo pipefail
# NOTE: deliberately NOT `set -x` — a trace would print the signed URL.

BASE="${MPS_API_BASE:-https://wfpeajmdojcjqyrsnxbk.supabase.co/functions/v1/music-prod-studio-api}"

VERSION=""
BUILD=""
EXPECT_SHA=""
EXPECT_SIZE=""
OUT=""
PRODUCT="music-prod-studio"
CURRENT="0.0.0"

usage() {
    cat >&2 <<'USAGE'
usage: fetch-published-candidate.sh --version <v> [--build <n>]
       --expect-sha <64-hex> --expect-size <bytes> --out <dir>
       [--product <slug>] [--current <v>]
USAGE
    exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)     VERSION="${2:-}"; shift 2 ;;
        --build)       BUILD="${2:-}"; shift 2 ;;
        --expect-sha)  EXPECT_SHA="${2:-}"; shift 2 ;;
        --expect-size) EXPECT_SIZE="${2:-}"; shift 2 ;;
        --out)         OUT="${2:-}"; shift 2 ;;
        --product)     PRODUCT="${2:-}"; shift 2 ;;
        --current)     CURRENT="${2:-}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "REFUSED: unknown argument '$1'" >&2; usage 2 ;;
    esac
done

refuse() { echo ""; echo "REFUSED: $1" >&2; exit 1; }

[ -n "$VERSION" ] || usage
[ -n "$EXPECT_SHA" ] || usage
[ -n "$EXPECT_SIZE" ] || usage
[ -n "$OUT" ] || usage
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || refuse "--version '$VERSION' is not x.y.z"
[ -z "$BUILD" ] || echo "$BUILD" | grep -qE '^[0-9]+$' || refuse "--build '$BUILD' is not numeric"
echo "$EXPECT_SHA" | grep -qE '^[0-9a-f]{64}$' || refuse "--expect-sha must be 64 lowercase hex characters"
echo "$EXPECT_SIZE" | grep -qE '^[0-9]+$' || refuse "--expect-size must be a whole number of bytes"
mkdir -p "$OUT" || refuse "the output directory could not be created: $OUT"

# ------------------------------------------------------------ 1. the catalog
CATALOG_URL="$BASE/updates?product=$PRODUCT&platform=macos&current=$CURRENT"
echo "==> [1/5] reading the public catalog (unauthenticated GET, no credential)"
CATALOG="$(curl -sS "$CATALOG_URL")" || refuse "the public catalog could not be reached: $CATALOG_URL"
IDENTITY="$(printf '%s' "$CATALOG" | python3 -c '
import json, re, sys
version = sys.argv[1]
build = sys.argv[2]
expect_sha = sys.argv[3]
expect_size = sys.argv[4]

def fail(message):
    print("error\t%s" % message.replace("\t", " "))
    raise SystemExit(0)

try:
    payload = json.load(sys.stdin)["data"]
except Exception as exc:
    fail("the public catalog did not answer with a usable payload: %s" % exc)

latest = payload.get("latestVersion")
if latest != version:
    fail("the public catalog serves %r, not the requested %r - the requested version is not the published one, so its bytes cannot be fetched this way" % (latest, version))

artifacts = [a for a in (payload.get("artifacts") or [])
             if a.get("platform") == "macos" and a.get("architecture") == "arm64"]
if len(artifacts) != 1:
    fail("expected exactly one macos/arm64 artifact in the catalog, found %d" % len(artifacts))
a = artifacts[0]

name = a.get("fileName") or ""
if build:
    expected_name = "Music-Prod-Studio-%s-%s.zip" % (version, build)
    if name != expected_name:
        fail("the published artifact is named %r, not %r" % (name, expected_name))
else:
    if not re.fullmatch(r"Music-Prod-Studio-%s-[0-9]+\.zip" % re.escape(version), name):
        fail("the published artifact is named %r, which does not carry version %s" % (name, version))

# The live catalog is the server-authoritative record for these bytes: a
# disagreement with the requested identity is a refusal, never something to
# resolve by preferring one of the two.
if a.get("sha256") != expect_sha:
    fail("the live catalog reports sha256 %s, this run asked for %s - refusing to fetch bytes the catalog does not vouch for" % (a.get("sha256"), expect_sha))
if str(a.get("fileSize")) != expect_size:
    fail("the live catalog reports %s bytes, this run asked for %s" % (a.get("fileSize"), expect_size))
if not a.get("id"):
    fail("the published artifact has no id")

print("ok\t%s\t%s\t%s\t%s" % (a["id"], name, a["sha256"], a["fileSize"]))
' "$VERSION" "$BUILD" "$EXPECT_SHA" "$EXPECT_SIZE")"
IFS=$'\t' read -r KIND ARTIFACT_ID FILE_NAME SERVER_SHA SERVER_SIZE <<< "$IDENTITY"
case "$KIND" in
    ok) : ;;
    error) refuse "$ARTIFACT_ID" ;;
    *) refuse "the public catalog could not be read" ;;
esac
echo "    OK — catalog serves $FILE_NAME ($SERVER_SIZE bytes, sha256 ${SERVER_SHA:0:12}…) for $VERSION"

# ---------------------------------------------------- 2. the download authority
echo "==> [2/5] asking /downloads/authorize for that exact artifact (unauthenticated GET)"
AUTHZ="$(curl -sS "$BASE/downloads/authorize?artifactId=$ARTIFACT_ID")" \
    || refuse "the download-authorization call did not complete"
SIGNED_URL="$(printf '%s' "$AUTHZ" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("error\tthe download authorization did not answer with JSON")
    raise SystemExit(0)
if d.get("success") is not True:
    print("error\t%s" % (str(d.get("error") or "the download authorization was refused").replace("\t", " ")))
    raise SystemExit(0)
a = d.get("data") or {}
def fail(message):
    print("error\t%s" % message.replace("\t", " "))
    raise SystemExit(0)
if a.get("artifactId") != sys.argv[1]:
    fail("the server authorized a different artifact: %s" % a.get("artifactId"))
if a.get("sha256") != sys.argv[2]:
    fail("the download authorization reports sha256 %s, expected %s" % (a.get("sha256"), sys.argv[2]))
if str(a.get("fileSize")) != sys.argv[3]:
    fail("the download authorization reports %s bytes, expected %s" % (a.get("fileSize"), sys.argv[3]))
if a.get("fileName") != sys.argv[4]:
    fail("the download authorization offers %r, expected %r" % (a.get("fileName"), sys.argv[4]))
if not a.get("signedUrl"):
    fail("the server minted no signed URL")
print(a["signedUrl"].replace("\n", ""))
' "$ARTIFACT_ID" "$EXPECT_SHA" "$EXPECT_SIZE" "$FILE_NAME")"
case "$SIGNED_URL" in
    error*) refuse "${SIGNED_URL#error	}" ;;
    "") refuse "the download authorization could not be read" ;;
esac
echo "    OK — a signed URL was minted for the same identity (the URL itself is never printed)"

# ------------------------------------------------------------- 3. the bytes
DEST="$OUT/$FILE_NAME"
echo "==> [3/5] downloading the artifact (the signed URL travels on stdin, never in argv)"
printf 'url = "%s"\n' "$SIGNED_URL" | curl -sS -L --fail -K - -o "$DEST" \
    || refuse "the authorized download failed"
unset SIGNED_URL

# --------------------------------------------------------- 4. prove the bytes
echo "==> [4/5] hashing the bytes that actually arrived"
ACTUAL_SHA="$(shasum -a 256 "$DEST" | awk '{print $1}')"
ACTUAL_SIZE="$(stat -f '%z' "$DEST")"
[ "$ACTUAL_SHA" = "$EXPECT_SHA" ] \
    || refuse "the downloaded file hashes to $ACTUAL_SHA, expected $EXPECT_SHA — refusing to use it"
[ "$ACTUAL_SIZE" = "$EXPECT_SIZE" ] \
    || refuse "the downloaded file is $ACTUAL_SIZE bytes, expected $EXPECT_SIZE — refusing to use it"
echo "    OK — bytes verified: $ACTUAL_SIZE bytes, sha256 $ACTUAL_SHA"

# ----------------------------------------------------------------- 5. report
echo "==> [5/5] candidate ready"
echo "=============================================================="
echo " PUBLISHED CANDIDATE FETCHED — nothing was modified"
echo "   file        : $DEST"
echo "   sha256      : $ACTUAL_SHA"
echo "   size        : $ACTUAL_SIZE bytes"
echo "   artifactId  : $ARTIFACT_ID"
echo "   source      : public catalog + /downloads/authorize (no credential used)"
echo "=============================================================="
# The caller consumes this one line: <path> <sha256> <size> <artifactId>
echo "CANDIDATE $DEST $ACTUAL_SHA $ACTUAL_SIZE $ARTIFACT_ID"
