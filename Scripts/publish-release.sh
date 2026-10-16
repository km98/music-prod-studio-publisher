#!/bin/bash
# publish-release.sh — publish a Music-Prod Studio macOS release through the
# deployed admin lifecycle, authenticated by a MACHINE CREDENTIAL.
#
# WHY THIS EXISTS (the difference from Scripts/publish-2.0.13.sh)
#   publish-2.0.13.sh publishes one release, from one hardcoded identity, and
#   authenticates with a human Magic Link access token that an operator has to
#   retrieve from browser storage and paste into a hidden prompt. That made a
#   human, hourly-expiring credential a required step of every release and made
#   unattended/CI publication impossible.
#
#   This script takes the release IDENTITY from its arguments (or from the
#   release-finalize manifest) and authenticates with either:
#
#     1. MPS_PUBLISHER_TOKEN              the release publisher credential — the
#                                         machine credential created for this job
#                                         (see docs/RELEASE-PUBLISH-AUTOMATION.md).
#                                         Revocable and scoped server-side to the
#                                         release publication routes only.
#     2. MPS_PUBLISHER_TOKEN_FILE         the same value in a 0600 file, for a
#                                         local run (never in argv, never in the
#                                         shell history).
#     3. MPS_ADMIN_TOKEN                  a human admin access token (the manual
#                                         fallback; unchanged behaviour).
#     4. nothing above                    the hidden prompt, as before.
#
#   Everything else — every guard, every STOP, the whole server state machine —
#   is the same contract publish-2.0.13.sh proved in production.
#
# THE DEPLOYED LIFECYCLE (the transition each route performs is the contract,
# not the route's name):
#
#   draft ──upload──> uploaded ──/validate (/ready)──> validated
#         ──/submit──> ready_for_approval ──/approve──> approved
#         ──/publish (/commit)──> published ──/yank──> yanked ──/archive──> archived
#
#   * `POST .../ready` is a LEGACY ALIAS of `POST .../validate` and returns the
#     release in status `validated`, not `ready`. `ready` is not a status the
#     deployed schema has.
#   * `validated` can never publish. `/publish` (alias `/commit`) requires status
#     `approved` AND a recorded `approved_by`, so the approval step is mandatory
#     and this script performs it explicitly.
#   * `/validate`, `/submit`, `/approve` and `/publish` ALL re-run the server's
#     readiness check. A failure is a 422 with the issues and NOTHING is
#     published. Read-only `GET .../validation` reports the same checks.
#
# RESUMING A PARTIALLY PUBLISHED RELEASE
#   A re-run ADOPTS what already exists instead of creating a second draft or
#   uploading a second artifact:
#     * an existing row for this version must be the same product, and each
#       transition runs only if the observed status is its documented pre-state;
#     * the artifact must already be this candidate with the SERVER's sha256 and
#       size equal to the local ZIP — a release carrying any other artifact is a
#       STOP, never re-uploaded or replaced.
#   `--inspect` stops after the read-only calls and prints the state.
#
# TOKEN/C REDENTIAL HANDLING GUARANTEES
#   - never echoed, never traced (the script never enables xtrace), never logged
#   - never written to disk or the repository (it lives in a shell variable)
#   - never in process arguments: every curl call receives its credential header
#     through `curl -K -` (a config streamed on STDIN), so `ps` and shell logs
#     can never capture it
#   - a credential is used ONLY for the read-only admin calls and the publication
#     calls below
#   - MPS_REQUIRE_PUBLISHER_CREDENTIAL=1 (set by the release workflow) refuses to
#     run on a human admin token, so CI can never silently fall back to a paste
#
# EVERY STEP STOPs on mismatch, before the mutation it guards. The public
# /updates endpoint is re-checked before publication to prove nothing is visible
# early, and re-checked after it to prove the catalog serves exactly this
# artifact. Finally the artifact is fetched through the public
# /downloads/authorize path and its bytes are hashed.
#
# ROLLBACK: this script never touches another release. To withdraw the release it
# published, POST .../admin/releases/<releaseId>/withdraw with an admin token:
# withdrawing yanks (never deletes) it, artifacts are retained, and clients fall
# back to the previously published release.
#
# USAGE
#   Scripts/publish-release.sh --version <v> --previous-version <v> --zip <zip>
#       (--sha256 <hex> [--size <bytes>] | --manifest <release-manifest.json>)
#       [--release-notes-file <file>] [--product-id <uuid>]
#       [--min-supported <v>] [--client-version <v>] [--inspect]
#
#   The ZIP's digest and size are always VERIFIED against the local bytes; when a
#   manifest or --size is supplied as well, every source (arguments, manifest,
#   bytes) must agree or the run stops. --size therefore only ever ADDS a check.

set -euo pipefail
# NOTE: deliberately NOT `set -x` anywhere — tracing would leak the credential.

BASE="${MPS_API_BASE:-https://wfpeajmdojcjqyrsnxbk.supabase.co/functions/v1/music-prod-studio-api}"
# Public anon key: not a secret, and required by the deployed function.
ANON_KEY="${MPS_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndmcGVham1kb2pjanF5cnNueGJrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjkyNTUwNDEsImV4cCI6MjA4NDgzMTA0MX0.3wrXDrOnh_bJtIAvzdGfoQfy8kMiugLMYHRYRezdanc}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

stop() { echo ""; echo "STOP: $1" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
usage: publish-release.sh --version <v> --previous-version <v> --zip <zip>
         (--sha256 <hex> | --manifest <release-manifest.json>) [--size <bytes>]
         --release-notes-file <file> [--build <n>] [--filename <name>]
         [--product-id <uuid>] [--min-supported <v>] [--client-version <v>]
         [--inspect]

Credential (first one set wins):
  MPS_PUBLISHER_TOKEN        the release publisher credential (mpspub_<id>_<secret>)
  MPS_PUBLISHER_TOKEN_FILE   the same value in a 0600 file
  MPS_ADMIN_TOKEN            a human admin access token (manual fallback)
  none of the above          hidden prompt on the controlling terminal

MPS_REQUIRE_PUBLISHER_CREDENTIAL=1 refuses to publish with a human token.
USAGE
    exit "${1:-0}"
}

# ------------------------------------------------- credential input plumbing
#
# The terminal-state handling lives HERE, before any argument is judged and
# before the first trap is armed, so that even an early usage error leaves the
# operator's terminal exactly as it was: a trap armed later could otherwise run
# before its own helpers exist.
TOKEN_PROMPT_TIMEOUT="${MPS_TOKEN_PROMPT_TIMEOUT:-300}"
_tty_saved_settings=""

_restore_terminal() {
    [ -n "$_tty_saved_settings" ] || return 0
    stty "$_tty_saved_settings" < /dev/tty 2>/dev/null \
        || stty "$_tty_saved_settings" < /dev/fd/0 2>/dev/null \
        || true
    _tty_saved_settings=""
}

# A trapped signal must restore the terminal AND then actually terminate: a
# handler that merely returns would make the process ignore Ctrl+C / SIGTERM
# while it sits at the prompt.
_on_signal() {
    _restore_terminal
    exit "$1"
}
trap '_restore_terminal' EXIT
trap '_on_signal 130' INT
trap '_on_signal 143' TERM
trap '_on_signal 129' HUP

# ------------------------------------------------------------------ arguments
VERSION=""
BUILD_NUMBER=""
PREVIOUS_VERSION=""
ZIP=""
SHA_ARG=""
SIZE_ARG=""
FILENAME=""
MANIFEST=""
PRODUCT_ID=""
MIN_SUPPORTED="2.0.0"
CLIENT_VERSION="2.0.0"
RELEASE_NOTES_FILE=""
MODE="publish"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)            VERSION="${2:-}"; shift 2 ;;
        --build)              BUILD_NUMBER="${2:-}"; shift 2 ;;
        --previous-version)   PREVIOUS_VERSION="${2:-}"; shift 2 ;;
        --zip)                ZIP="${2:-}"; shift 2 ;;
        --sha256)             SHA_ARG="${2:-}"; shift 2 ;;
        --size)               SIZE_ARG="${2:-}"; shift 2 ;;
        --filename)           FILENAME="${2:-}"; shift 2 ;;
        --manifest)           MANIFEST="${2:-}"; shift 2 ;;
        --product-id)         PRODUCT_ID="${2:-}"; shift 2 ;;
        --min-supported)      MIN_SUPPORTED="${2:-}"; shift 2 ;;
        --client-version)     CLIENT_VERSION="${2:-}"; shift 2 ;;
        --release-notes-file) RELEASE_NOTES_FILE="${2:-}"; shift 2 ;;
        --inspect)            MODE="inspect"; shift ;;
        -h|--help)            usage 0 ;;
        *) echo "STOP: unknown argument '$1'" >&2; usage 1 ;;
    esac
done

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
[ -n "$VERSION" ] || stop "--version is required"
[ -n "$PREVIOUS_VERSION" ] || stop "--previous-version is required (the release production is serving now)"
[ -n "$ZIP" ] || stop "--zip is required (the notarized, stapled candidate)"
[ -n "$SHA_ARG" ] || [ -n "$MANIFEST" ] || stop "a release identity is required: pass --sha256 or --manifest"
echo "$VERSION" | grep -qE "$SEMVER_RE" || stop "--version must be a semantic version (got '$VERSION')"
echo "$PREVIOUS_VERSION" | grep -qE "$SEMVER_RE" || stop "--previous-version must be a semantic version (got '$PREVIOUS_VERSION')"
echo "$MIN_SUPPORTED" | grep -qE "$SEMVER_RE" || stop "--min-supported must be a semantic version (got '$MIN_SUPPORTED')"
[ "$VERSION" != "$PREVIOUS_VERSION" ] || stop "--version and --previous-version are both $VERSION; a release never replaces the version it supersedes"
[ -f "$ZIP" ] || stop "candidate ZIP not found: $ZIP"
[ -f "$REPO_ROOT/Scripts/verify-app-resources.sh" ] || stop "Scripts/verify-app-resources.sh is missing from $REPO_ROOT"

# ------------------------------------------------- release-finalize manifest
# The manifest is release-finalize.sh's own record: ONE line per field, written
# and rewritten in place, read with a strict regex here. It is not JSON and must
# never be parsed as JSON.
manifest_field() { # manifest_field <file> <key>
    perl -ne 'print $1 if /"'$2'": "([^"]*)"/' "$1" 2>/dev/null | head -1
}
if [ -n "$MANIFEST" ]; then
    [ -f "$MANIFEST" ] || stop "release manifest not found: $MANIFEST"
    M_MODE="$(manifest_field "$MANIFEST" mode)"
    M_SUBMITTED="$(manifest_field "$MANIFEST" notarizationSubmitted)"
    M_STAPLED="$(manifest_field "$MANIFEST" stapled)"
    M_EVIDENCE="$(manifest_field "$MANIFEST" evidenceVerdict)"
    M_GATE="$(manifest_field "$MANIFEST" finalGateResult)"
    M_VERSION="$(manifest_field "$MANIFEST" version)"
    M_BUILD="$(manifest_field "$MANIFEST" buildNumber)"
    M_NAME="$(manifest_field "$MANIFEST" finalZipName)"
    M_SHA="$(manifest_field "$MANIFEST" finalZipSha256)"
    M_SIZE="$(manifest_field "$MANIFEST" finalZipBytes)"
    M_COMMIT="$(manifest_field "$MANIFEST" sourceCommit)"
    for pair in "mode:$M_MODE" "notarizationSubmitted:$M_SUBMITTED" "stapled:$M_STAPLED" \
                "evidenceVerdict:$M_EVIDENCE" "finalGateResult:$M_GATE" "version:$M_VERSION" \
                "finalZipName:$M_NAME" "finalZipSha256:$M_SHA" "finalZipBytes:$M_SIZE"; do
        [ -n "${pair#*:}" ] || stop "the release manifest ($MANIFEST) has no '${pair%%:*}' field — refusing to publish from an incomplete release record"
    done
    [ "$M_MODE" = "production" ] || stop "the release manifest records mode '$M_MODE', not 'production' — a rehearsal is not publishable"
    [ "$M_SUBMITTED" = "yes" ] || stop "the release manifest records notarizationSubmitted='$M_SUBMITTED' — an unsubmitted artifact is never published"
    [ "$M_STAPLED" = "yes" ] || stop "the release manifest records stapled='$M_STAPLED' — only a stapled artifact is a publication identity"
    [ "$M_EVIDENCE" = "PASS" ] || stop "the release manifest records evidenceVerdict='$M_EVIDENCE' — evidence must PASS"
    [ "$M_GATE" = "PASS" ] || stop "the release manifest records finalGateResult='$M_GATE' — the final gate must PASS"
    [ -z "$SHA_ARG" ] || [ "$SHA_ARG" = "$M_SHA" ] \
        || stop "--sha256 ($SHA_ARG) disagrees with the release manifest's finalZipSha256 ($M_SHA) — refusing to guess which artifact is meant"
    [ -z "$SIZE_ARG" ] || [ "$SIZE_ARG" = "$M_SIZE" ] \
        || stop "--size ($SIZE_ARG) disagrees with the release manifest's finalZipBytes ($M_SIZE)"
    [ -z "$FILENAME" ] || [ "$FILENAME" = "$M_NAME" ] \
        || stop "--filename ($FILENAME) disagrees with the release manifest's finalZipName ($M_NAME)"
    [ "$VERSION" = "$M_VERSION" ] || stop "--version ($VERSION) disagrees with the release manifest's version ($M_VERSION)"
    [ -z "$BUILD_NUMBER" ] || [ "$BUILD_NUMBER" = "$M_BUILD" ] \
        || stop "--build ($BUILD_NUMBER) disagrees with the release manifest's buildNumber ($M_BUILD)"
    SHA_ARG="$M_SHA"
    SIZE_ARG="$M_SIZE"
    FILENAME="$M_NAME"
    [ -n "$BUILD_NUMBER" ] || BUILD_NUMBER="$M_BUILD"
    echo "==> release record: $MANIFEST (version $M_VERSION build $M_BUILD, commit ${M_COMMIT:0:12}, mode $M_MODE, stapled $M_STAPLED, evidence $M_EVIDENCE, gate $M_GATE)"
fi

[ -n "$SHA_ARG" ] || stop "no expected SHA-256 was supplied (pass --sha256 or --manifest)"
echo "$SHA_ARG" | grep -qE '^[0-9a-f]{64}$' || stop "--sha256 must be 64 lowercase hex characters"
if [ -n "$SIZE_ARG" ]; then
    echo "$SIZE_ARG" | grep -qE '^[0-9]+$' || stop "--size must be a whole number of bytes"
else
    # The local ZIP is the source of truth for its own size: the published size
    # is re-derived server-side from these bytes and re-checked in step [8/8].
    SIZE_ARG="$(stat -f '%z' "$ZIP")"
fi
[ -z "$FILENAME" ] && FILENAME="$(basename "$ZIP")"
[ "$FILENAME" = "$(basename "$ZIP")" ] \
    || stop "--filename ($FILENAME) is not the name of the candidate ZIP ($(basename "$ZIP")) — the published name and the published bytes must be the same file"
echo "$FILENAME" | grep -qE '\.zip$' || stop "the release filename must end in .zip (got '$FILENAME')"

# --------------------------------------------------------- version monotonicity
python3 - "$VERSION" "$PREVIOUS_VERSION" "$MIN_SUPPORTED" <<'PY' || stop "the version arguments are not consistent — nothing was modified"
import sys
def parts(v):
    return tuple(int(p) for p in v.split('.'))
version, previous, minimum = (parts(a) for a in sys.argv[1:4])
if version <= previous:
    print("STOP: $VERSION is not newer than $PREVIOUS_VERSION", file=sys.stderr)
    raise SystemExit(1)
if minimum > version:
    print("STOP: minimumSupportedVersion is above the release version", file=sys.stderr)
    raise SystemExit(1)
PY

# The notes this run would publish. Read once, used for the draft body AND to
# judge an existing row for this version.
NOTES_TEXT="$(cat "$RELEASE_NOTES_FILE" 2>/dev/null || true)"

if [ -n "$RELEASE_NOTES_FILE" ]; then
    [ -f "$RELEASE_NOTES_FILE" ] || stop "release notes file not found: $RELEASE_NOTES_FILE"
    [ -s "$RELEASE_NOTES_FILE" ] || stop "release notes file is empty: $RELEASE_NOTES_FILE"
else
    stop "--release-notes-file is required: it becomes the releaseNotes recorded on the release"
fi

EXPECTED_SHA="$SHA_ARG"
EXPECTED_SIZE="$SIZE_ARG"
EXPECTED_PRODUCT_ID="$PRODUCT_ID"

# ---------------------------------------------------------------- credential
#
# HOW THE HIDDEN PROMPT READS, AND WHY IT IS WRITTEN THIS WAY (C6.9E-1)
#
# Field failure this fixes, measured 2026-10-11: three runs hung at
# `access_token:` with NO usable keyboard, and every one of those terminals was
# left with echo DISABLED (-echo) after the process was killed — so everything
# typed afterwards, at the script or back at the shell, was invisible. Terminal
# state belongs to the tty, not to the process, so it must be restored on EVERY
# exit path, including signals.
#
# The rules encoded below:
#   1. Read from the CONTROLLING TERMINAL (/dev/tty), never from stdin.
#   2. Read in non-canonical mode, one byte at a time: canonical mode buffers a
#      whole line and can discard a long paste. `-d ''` (delimiter NUL) AND
#      treating a successful EMPTY read as End-of-line are BOTH required — on
#      bash 3.2.57 (the shebang's bash) `read -n 1` stops at the first delimiter
#      it sees and never stores it, so Enter ended the read with an empty value
#      and the loop waited forever for input that had already arrived. That is
#      exactly what the operator sees as "cannot type, cannot paste".
#   3. Echo is forced OFF for the whole read and restored by a trap on
#      EXIT/INT/TERM/HUP.
#   4. The wait is BOUNDED by MPS_TOKEN_PROMPT_TIMEOUT (default 300 s).
#   5. The value is never printed, traced, written to disk, or placed in any
#      process argument.
# (The terminal-state helpers and their traps are armed near the top of this
#  script, before any argument is judged, so this is only the READER.)

# Reads a credential into TOKEN_VAR. Returns 0 on success; otherwise stops with a
# named reason (never hanging, never silent).
read_credential() {
    TOKEN_VAR=""
    local tty_path=""
    if [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
        tty_path="/dev/tty"
    elif [ -t 0 ]; then
        tty_path="/dev/fd/0"
    else
        stop "no credential was supplied and no interactive terminal is available for the hidden prompt (stdin is not a terminal and /dev/tty cannot be opened). Nothing was modified. In CI set MPS_PUBLISHER_TOKEN; locally export MPS_PUBLISHER_TOKEN or MPS_ADMIN_TOKEN, or run this from a real terminal window."
    fi

    _tty_saved_settings="$(stty -g < "$tty_path" 2>/dev/null)" || _tty_saved_settings=""
    if stty -a < "$tty_path" 2>/dev/null | grep -qE '(^|[[:space:]])-echo([[:space:]]|;|$)'; then
        echo "==> WARNING: this terminal already had echo disabled before the prompt; if typing stays invisible run 'stty echo'" >&2
    fi
    stty -echo -icanon -isig min 1 time 0 < "$tty_path" 2>/dev/null \
        || stop "the controlling terminal could not be put into hidden-input mode; nothing was modified"

    local prompt_out="/dev/tty"
    [ "$tty_path" = "/dev/fd/0" ] && prompt_out="/dev/stderr"
    # The deadline is counted with the SECONDS builtin so the per-byte loop forks
    # nothing: a forked `date` per byte measured 1.5 s for a 1.6 kB token paste
    # versus 0.04 s with SECONDS. A real credential is that size.
    local deadline=$(( SECONDS + TOKEN_PROMPT_TIMEOUT ))
    local remaining=0 char="" read_status=0
    printf '%s' 'publisher token or admin access_token: ' > "$prompt_out"
    while :; do
        remaining=$(( deadline - SECONDS ))
        if [ "$remaining" -le 0 ]; then
            _restore_terminal
            printf '\n' > "$prompt_out"
            stop "no credential was entered within ${TOKEN_PROMPT_TIMEOUT}s (MPS_TOKEN_PROMPT_TIMEOUT); nothing was modified"
        fi
        read_status=0
        IFS= read -r -n 1 -t "$remaining" -d '' char < "$tty_path" || read_status=$?
        if [ "$read_status" -ne 0 ]; then
            _restore_terminal
            printf '\n' > "$prompt_out"
            # Classify by the CLOCK, not by read's status: bash 3.2 reports an
            # expired -t timeout as status 1, exactly like EOF.
            if [ "$SECONDS" -ge "$deadline" ]; then
                stop "no credential was entered within ${TOKEN_PROMPT_TIMEOUT}s (MPS_TOKEN_PROMPT_TIMEOUT); nothing was modified"
            fi
            stop "the hidden credential prompt reached end-of-input before a credential was entered; nothing was modified"
        fi
        # A successful read that produced NO byte is Enter (EOL).
        [ -n "$char" ] || break
        case "$char" in
            $'\r'|$'\n') break ;;
            $'\003')
                _restore_terminal
                printf '\n' > "$prompt_out"
                stop "credential entry cancelled; nothing was modified" ;;
            $'\004')
                [ -n "$TOKEN_VAR" ] && break
                _restore_terminal
                printf '\n' > "$prompt_out"
                stop "credential entry cancelled; nothing was modified" ;;
            $'\177'|$'\b')
                TOKEN_VAR="${TOKEN_VAR%?}" ;;
            *) TOKEN_VAR="$TOKEN_VAR$char" ;;
        esac
    done
    _restore_terminal
    printf '\n' > "$prompt_out"

    # Terminals that wrap a paste in bracketed-paste markers (ESC[200~ /
    # ESC[201~) would otherwise corrupt the value; neither credential shape
    # contains an ESC byte, so removing them is lossless.
    TOKEN_VAR="$(printf '%s' "$TOKEN_VAR" | LC_ALL=C tr -d '\033' | LC_ALL=C sed -e 's/\[200~//g' -e 's/\[201~//g')"
    return 0
}

# A publisher token and a Supabase access token have disjoint shapes, so the
# credential's kind is decided by the value itself and checked BEFORE any call.
PUBLISHER_RE='^mpspub_[a-z0-9][a-z0-9-]{0,31}_[A-Za-z0-9_-]{43,}$'
JWT_RE='^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'

TOKEN_VAR=""
CREDENTIAL_ID=""
AUTH_MODE=""
if [ -n "${MPS_PUBLISHER_TOKEN:-}" ]; then
    TOKEN_VAR="$MPS_PUBLISHER_TOKEN"
    AUTH_MODE="publisher"
    echo "==> using the release publisher credential from MPS_PUBLISHER_TOKEN"
elif [ -n "${MPS_PUBLISHER_TOKEN_FILE:-}" ]; then
    [ -f "$MPS_PUBLISHER_TOKEN_FILE" ] || stop "MPS_PUBLISHER_TOKEN_FILE does not exist: $MPS_PUBLISHER_TOKEN_FILE"
    # Credential hygiene: a file readable by group or others is a leaked secret.
    PERMS="$(stat -f '%Lp' "$MPS_PUBLISHER_TOKEN_FILE")"
    case "$PERMS" in
        600|400|700|500) ;;
        *) stop "the publisher credential file must not be group- or world-readable (mode $PERMS); run: chmod 600 '$MPS_PUBLISHER_TOKEN_FILE'" ;;
    esac
    TOKEN_VAR="$(cat "$MPS_PUBLISHER_TOKEN_FILE")"
    TOKEN_VAR="${TOKEN_VAR%$'\n'}"
    AUTH_MODE="publisher"
    echo "==> using the release publisher credential from MPS_PUBLISHER_TOKEN_FILE"
elif [ -n "${MPS_ADMIN_TOKEN:-}" ]; then
    TOKEN_VAR="$MPS_ADMIN_TOKEN"
    AUTH_MODE="admin"
    echo "==> using a human admin access token from MPS_ADMIN_TOKEN"
else
    echo "==> paste the release publisher credential (preferred), or a human admin access token (hidden input; never echoed)"
    read_credential
    if printf '%s' "$TOKEN_VAR" | grep -qE "$PUBLISHER_RE"; then
        AUTH_MODE="publisher"
    elif printf '%s' "$TOKEN_VAR" | grep -qE "$JWT_RE"; then
        AUTH_MODE="admin"
    fi
fi

[ -n "$TOKEN_VAR" ] || stop "no credential supplied"
case "$AUTH_MODE" in
    publisher)
        printf '%s' "$TOKEN_VAR" | grep -qE "$PUBLISHER_RE" \
          || stop "the supplied value is configured as a publisher credential but is not one (expected mpspub_<id>_<secret>)" ;;
    admin)
        printf '%s' "$TOKEN_VAR" | grep -qE "$JWT_RE" \
          || stop "the supplied value is not a JWT access token" ;;
    *)  stop "the supplied value is neither a publisher credential (mpspub_<id>_<secret>) nor a Supabase access token (JWT)" ;;
esac

# The automation must not be able to fall back to a human credential by accident.
if [ "${MPS_REQUIRE_PUBLISHER_CREDENTIAL:-0}" = "1" ] && [ "$AUTH_MODE" != "publisher" ]; then
    stop "MPS_REQUIRE_PUBLISHER_CREDENTIAL=1 but the credential is a human access token — refusing to publish with a pasted token"
fi

# The credential's ID (a label, never the secret) is reported so an operator can
# tell which credential acted; it is the only part of the value ever printed.
if [ "$AUTH_MODE" = "publisher" ]; then
    CREDENTIAL_ID="$(printf '%s' "$TOKEN_VAR" | sed -E 's/^mpspub_([a-z0-9][a-z0-9-]{0,31})_.*$/\1/')"
    echo "    credential id: $CREDENTIAL_ID (scope is enforced server-side: release publication routes only)"
else
    echo "    credential: human admin access token (JWT); expires about one hour after sign-in"
fi

# Emit a curl config on stdin carrying the credential header, so the value NEVER
# appears in any process argument (invisible to ps).
curl_auth() {
    if [ "$AUTH_MODE" = "publisher" ]; then
        printf 'header = "X-Release-Publisher-Token: %s"\n' "$TOKEN_VAR"
    else
        printf 'header = "Authorization: Bearer %s"\n' "$TOKEN_VAR"
    fi | curl -sS -K - "$@"
}

# --------------------------------------------------- the candidate, by its bytes
ACTUAL_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
ACTUAL_SIZE="$(stat -f '%z' "$ZIP")"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || stop "the candidate ZIP's SHA-256 is $ACTUAL_SHA, expected $EXPECTED_SHA — refusing to publish different bytes"
[ "$ACTUAL_SIZE" = "$EXPECTED_SIZE" ] || stop "the candidate ZIP is $ACTUAL_SIZE bytes, expected $EXPECTED_SIZE"
echo "==> candidate verified: $FILENAME SHA $ACTUAL_SHA / $ACTUAL_SIZE bytes (the ZIP is never rebuilt or modified here)"

# The startup-critical resource gate, run against the SHIPPED bytes. An
# unlaunchable app is not a publishable release: this refuses here, before any
# server state moves, rather than after users install it. Read-only.
GATE_DIR="$(mktemp -d)"
trap 'rm -rf "$GATE_DIR"; _restore_terminal' EXIT
unzip -q "$ZIP" -d "$GATE_DIR" || stop "the candidate ZIP could not be extracted - nothing was modified"
GATE_APP="$(find "$GATE_DIR" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "$GATE_APP" ] || stop "the candidate ZIP contains no .app bundle - nothing was modified"
"$REPO_ROOT/Scripts/verify-app-resources.sh" "$GATE_APP" --zip "$ZIP" \
  || stop "the packaged candidate is missing a startup-critical resource or does not carry the genuine app icon - NOT PUBLISHING"
echo "==> packaged resources verified against the shipped ZIP"

CATALOG="$BASE/updates?product=music-prod-studio&platform=macos"
# Read the release status out of an API envelope, tolerating a missing field.
read_status() { python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print((d.get("data") or {}).get("release", {}).get("status") or "")'; }

# --------------------------------------------------------------- 0. baseline
echo "==> [0/8] baseline: public catalog for a client on $CLIENT_VERSION"
BASELINE="$(curl -sS "$CATALOG&current=$CLIENT_VERSION")"
BASELINE_LATEST="$(echo "$BASELINE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["latestVersion"])')" \
  || stop "the public catalog did not answer with a usable payload"
case "$BASELINE_LATEST" in
    "$PREVIOUS_VERSION") echo "    OK — catalog serves $PREVIOUS_VERSION; $VERSION is not visible" ;;
    "$VERSION") echo "    OK — catalog ALREADY serves $VERSION: this run is a verification pass" ;;
    *) stop "the public catalog serves an unexpected latest version: '$BASELINE_LATEST' (expected $PREVIOUS_VERSION or $VERSION)" ;;
esac
# Metadata of the release the catalog is SERVING, used below to prove the admin
# row for that release belongs to Music-Prod Studio. The served release is
# $PREVIOUS_VERSION on a first publication and $VERSION on a verification pass,
# so the notes are judged against $BASELINE_LATEST's row, never against a row
# that never carried them.
STUDIO_NOTES="$(echo "$BASELINE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("releaseNotes") or "")')"

# --------------------------------------------------------------- 1. identity
echo "==> [1/8] verifying the credential & resolving product/release state (read-only GET /admin/releases)"
RESP="$(curl_auth -w $'\n%{http_code}' "$BASE/admin/releases")"
ADMIN_CODE="${RESP##*$'\n'}"
ADMIN_BODY="${RESP%$'\n'*}"
if [ "$ADMIN_CODE" != "200" ]; then
    if [ "$AUTH_MODE" = "publisher" ]; then
        stop "GET /admin/releases returned $ADMIN_CODE — the publisher credential is unknown, revoked, or the function does not accept it yet (has the backend change been deployed?). Nothing was modified."
    fi
    stop "GET /admin/releases returned $ADMIN_CODE — token expired, invalid, or the user lacks the admin role. Nothing was modified."
fi
echo "    OK — the credential is authorized ($AUTH_MODE)"

# The parser reports every refusal as `error<TAB>message` (one line, no raw
# traceback), so a STOP names the guard that fired.
DISCOVERY="$(echo "$ADMIN_BODY" | python3 -c '
import json, sys, re
version, previous, expected_product, notes, notes_text, minimum, baseline_latest = sys.argv[1:8]

def fail(msg):
    print("error\t%s" % msg.replace("\t", " "))
    raise SystemExit(0)

try:
    rows = json.load(sys.stdin)["data"]["releases"]
except Exception as exc:
    fail("the admin release list could not be parsed: %s" % exc)
prev = [r for r in rows if r.get("version") == previous and r.get("status") == "published"]
if len(prev) != 1:
    fail("expected exactly one published %s release, found %d" % (previous, len(prev)))
row = prev[0]
pid = row.get("productId") or ""
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", pid):
    fail("the published %s row carries no usable product UUID: %r" % (previous, pid))
if expected_product and pid != expected_product:
    fail("product UUID mismatch: got %s, expected %s" % (pid, expected_product))
# The catalog reports the notes of the release it is SERVING — its own
# latestVersion — which is $PREVIOUS_VERSION only while that version is the newest
# one published. A run whose version the catalog ALREADY serves is a verification
# pass, and its notes then belong to $VERSION. They are therefore compared with
# the row the catalog is actually describing: reading them against the
# $PREVIOUS_VERSION row made a re-inspection of a published release impossible,
# and proved nothing even when it passed, because a row that never carried those
# notes is not evidence about the release the catalog serves.
notes_version = baseline_latest or previous
served = [r for r in rows if r.get("version") == notes_version and r.get("status") == "published"]
if len(served) != 1:
    fail("the public catalog serves %s but the admin list has no single published %s release (found %d) — the release record and the catalog disagree — refusing to guess the product" % (notes_version, notes_version, len(served)))
served_row = served[0]
if (served_row.get("productId") or "") != pid:
    fail("the %s release the catalog serves belongs to product %s, not to product %s of the published %s release — refusing to guess the product" % (notes_version, served_row.get("productId"), pid, previous))
if notes == "" or (served_row.get("releaseNotes") or "") != notes:
    fail("the admin %s row does not match the public music-prod-studio catalog (releaseNotes mismatch) — refusing to guess the product" % notes_version)
mine = [r for r in rows if r.get("version") == version]
if len(mine) > 1:
    fail("found %d %s rows; versions are unique per product, so this is stale state" % (len(mine), version))
if not mine:
    print("ok\t%s\t\t" % pid)
else:
    r = mine[0]
    if r.get("productId") != pid:
        fail("the existing %s row belongs to another product" % version)
    # Adopting a row created by an earlier run is the resume path, so the row has
    # to be the release THIS run would publish: the notes and the minimum
    # supported version it records are what users will be shown. A field the
    # response does not carry cannot be judged, but a field that disagrees is a
    # different publication wearing our version number.
    if r.get("releaseNotes") is not None and (r.get("releaseNotes") or "") != notes_text:
        fail("the existing %s row records different release notes than this run would publish - it is not this release" % version)
    if r.get("minimumSupportedVersion") is not None and (r.get("minimumSupportedVersion") or "") != minimum:
        fail("the existing %s row records minimumSupportedVersion %r, not %r" % (version, r.get("minimumSupportedVersion"), minimum))
    print("ok\t%s\t%s\t%s" % (pid, r.get("id"), r.get("status") or ""))
' "$VERSION" "$PREVIOUS_VERSION" "$EXPECTED_PRODUCT_ID" "$STUDIO_NOTES" "$NOTES_TEXT" "$MIN_SUPPORTED" "$BASELINE_LATEST")" || DISCOVERY=""
IFS=$'\t' read -r DISCOVERY_KIND PRODUCT_ID EXISTING_RELEASE_ID EXISTING_STATUS <<< "$DISCOVERY"
case "$DISCOVERY_KIND" in
    ok) EXISTING_RELEASE_ID="${EXISTING_RELEASE_ID:-}"; EXISTING_STATUS="${EXISTING_STATUS:-}" ;;
    error) stop "$PRODUCT_ID — nothing was modified" ;;
    *) stop "could not resolve the Music-Prod Studio product/release state from the published $PREVIOUS_VERSION release — nothing was modified" ;;
esac
if [ -n "$EXPECTED_PRODUCT_ID" ]; then
    echo "    OK — product UUID verified ($PRODUCT_ID)"
else
    echo "    OK — product UUID derived from the published $PREVIOUS_VERSION release and the public catalog ($PRODUCT_ID)"
fi
[ -n "$EXISTING_RELEASE_ID" ] \
  && echo "    OK — existing $VERSION release $EXISTING_RELEASE_ID is in status '$EXISTING_STATUS'" \
  || echo "    OK — no $VERSION release exists yet"

# --------------------------------------------------------------- 2. draft
STATUS=""
if [ -n "$EXISTING_RELEASE_ID" ]; then
    echo "==> [2/8] adopting the existing $VERSION release (no draft is created)"
    RELEASE_ID="$EXISTING_RELEASE_ID"
    STATUS="$EXISTING_STATUS"
    case "$STATUS" in
        published) echo "    OK — already published; no transition needed" ;;
        archived|yanked|withdrawn)
            stop "the $VERSION release is '$STATUS' and cannot be published from that state" ;;
        draft|uploaded|validated|ready_for_approval|approved)
            echo "    OK — resuming from status '$STATUS' (id: $RELEASE_ID)" ;;
        *) stop "the $VERSION release is in unknown status '$STATUS'" ;;
    esac
elif [ "$MODE" = "inspect" ]; then
    # --inspect promises "nothing was modified" in its own banner, so it must not
    # create a draft. The state is reported and the run stops here.
    echo "==> [2/8] inspection: no $VERSION release exists yet (a real run would create the draft here)"
    echo ""
    echo "=============================================================="
    echo " INSPECTION ONLY — nothing was modified"
    echo "   credential: $AUTH_MODE${CREDENTIAL_ID:+ ($CREDENTIAL_ID)}"
    echo "   releaseId:  <none — a real run would create the draft>"
    echo "   productId:  $PRODUCT_ID"
    echo "   sha256:     $EXPECTED_SHA"
    echo "   size:       $EXPECTED_SIZE"
    echo "   catalog:    latestVersion=$BASELINE_LATEST"
    echo " Re-run without --inspect to publish."
    echo "=============================================================="
    exit 0
else
    echo "==> [2/8] creating draft release $VERSION"
    DRAFT_BODY="$(python3 -c '
import json, sys
product, version, minimum, notes_path = sys.argv[1:5]
with open(notes_path, "r", encoding="utf-8") as handle:
    notes = handle.read().strip()
print(json.dumps({"productId": product, "version": version, "mandatory": False,
                  "minimumSupportedVersion": minimum, "releaseNotes": notes}))
' "$PRODUCT_ID" "$VERSION" "$MIN_SUPPORTED" "$RELEASE_NOTES_FILE")" \
      || stop "the release notes could not be read into a request body — nothing was modified"
    DRAFT="$(curl_auth -X POST "$BASE/admin/releases" \
      -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
      -d "$DRAFT_BODY")"
    echo "$DRAFT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('data',{}).get('release',{}).get('status')=='draft', json.dumps(d)[:400]" \
      || stop "draft creation failed or did not return a draft: $(echo "$DRAFT" | head -c 200)"
    RELEASE_ID="$(echo "$DRAFT" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['release']['id'])")"
    STATUS="draft"
    echo "    OK — release id: $RELEASE_ID (productId: $PRODUCT_ID)"
fi

# --------------------------------------------------------------- 3. artifact
ARTIFACT_ID=""
echo "==> [3/8] checking the release's artifacts (read-only GET /admin/releases/$RELEASE_ID)"
DETAIL="$(curl_auth -w $'\n%{http_code}' "$BASE/admin/releases/$RELEASE_ID")"
DETAIL_CODE="${DETAIL##*$'\n'}"
DETAIL_BODY="${DETAIL%$'\n'*}"
[ "$DETAIL_CODE" = "200" ] || stop "GET /admin/releases/$RELEASE_ID returned $DETAIL_CODE — nothing was modified"
ARTIFACT_STATE="$(echo "$DETAIL_BODY" | python3 -c '
import json, sys
version, sha, size, name = sys.argv[1:5]

def fail(msg):
    print("error\t%s" % msg.replace("\t", " "))
    raise SystemExit(0)

try:
    release = json.load(sys.stdin)["data"]["release"]
except Exception as exc:
    fail("the release detail could not be parsed: %s" % exc)
arts = release.get("artifacts") or []
mine = [a for a in arts if a.get("platform") == "macos" and a.get("architecture") == "arm64"]
if len(mine) > 1:
    fail("%d macos/arm64 artifacts are attached to %s" % (len(mine), version))
if len(arts) > len(mine):
    print("foreign\t%d artifact(s) that are not macos/arm64\t" % (len(arts) - len(mine)))
elif not mine:
    print("absent\tno artifact yet\t")
else:
    a = mine[0]
    if a.get("sha256") != sha:
        fail("artifact %s carries sha %s, not the candidate %s" % (a.get("id"), a.get("sha256"), sha))
    if str(a.get("fileSize")) != size:
        fail("artifact %s is %s bytes, expected %s" % (a.get("id"), a.get("fileSize"), size))
    if a.get("fileName") != name:
        fail("artifact %s is named %s, expected %s" % (a.get("id"), a.get("fileName"), name))
    print("match\t%s\t%s" % (a.get("id"), a.get("id")))
' "$VERSION" "$EXPECTED_SHA" "$EXPECTED_SIZE" "$FILENAME")" || ARTIFACT_STATE=""
[ -n "$ARTIFACT_STATE" ] || stop "the release's artifact list could not be read — nothing was modified"
IFS=$'\t' read -r ARTIFACT_KIND ARTIFACT_ARG ARTIFACT_ID <<< "$ARTIFACT_STATE"
case "$ARTIFACT_KIND" in
    error) stop "$ARTIFACT_ARG — nothing was modified; investigate before publishing" ;;
    match) ARTIFACT_ID="$ARTIFACT_ARG"
        echo "    OK — existing artifact $ARTIFACT_ID is this candidate (sha/size/name verified server-side); NOT re-uploading" ;;
    foreign)
        stop "the release already carries artifacts that are not this candidate's macos/arm64 artifact; refusing to add or replace one" ;;
    absent)
        if [ "$STATUS" = "published" ]; then
            stop "the published release $RELEASE_ID has no macos/arm64 artifact — investigate"
        fi
        echo "    uploading $FILENAME (the release has no artifact yet)"
        UPLOAD="$(curl_auth -X POST "$BASE/admin/releases/$RELEASE_ID/artifacts" \
          -H "apikey: $ANON_KEY" \
          -F "file=@$ZIP" \
          -F "format=app-bundle" \
          -F "platform=macos" \
          -F "architecture=arm64" \
          -F "fileName=$FILENAME" \
          -F "sha256=$EXPECTED_SHA")"
        SERVER_SHA="$(echo "$UPLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d.get('artifact',{}).get('sha256',''))" 2>/dev/null || true)"
        SERVER_SIZE="$(echo "$UPLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d.get('artifact',{}).get('fileSize',''))" 2>/dev/null || true)"
        ARTIFACT_ID="$(echo "$UPLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d.get('artifact',{}).get('id',''))" 2>/dev/null || true)"
        [ "$SERVER_SHA" = "$EXPECTED_SHA" ] || stop "server-computed SHA mismatch: got '$SERVER_SHA', expected $EXPECTED_SHA — DO NOT PUBLISH; inspect release $RELEASE_ID"
        [ "$SERVER_SIZE" = "$EXPECTED_SIZE" ] || stop "server-computed size mismatch: got '$SERVER_SIZE', expected $EXPECTED_SIZE — DO NOT PUBLISH; inspect release $RELEASE_ID"
        [ -n "$ARTIFACT_ID" ] || stop "the upload returned no artifact id"
        echo "    OK — artifactId: $ARTIFACT_ID, sha/size verified server-side" ;;
esac

# --------------------------------------------------------------- 4. validation
echo "==> [4/8] validation state (read-only GET /admin/releases/$RELEASE_ID/validation)"
VALIDATION="$(curl_auth "$BASE/admin/releases/$RELEASE_ID/validation")"
echo "$VALIDATION" | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print("    valid=%s ready=%s issues=%s" % (d.get("valid"), d.get("ready"), d.get("issues") or []))
for r in (d.get("requirements") or []):
    print("    requirement %s/%s present=%s valid=%s %s" % (
        r.get("platform"), r.get("architecture"), r.get("present"), r.get("valid"), r.get("issues") or []))
' || stop "the read-only validation report could not be read — nothing was modified"
VALIDATION_READY="$(echo "$VALIDATION" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("ready"))')"

if [ "$STATUS" = "draft" ] || [ "$STATUS" = "uploaded" ]; then
    echo "    POST /ready (draft|uploaded -> validated)"
    READY="$(curl_auth -X POST "$BASE/admin/releases/$RELEASE_ID/ready" -H "apikey: $ANON_KEY")"
    STATUS="$(echo "$READY" | read_status)"
    [ "$STATUS" = "validated" ] || stop "the validation transition did not return status 'validated' (got '$STATUS'): $(echo "$READY" | head -c 300)"
    echo "    OK — release is validated"
elif [ "$STATUS" = "validated" ]; then
    echo "    OK — release is already validated"
elif [ "$STATUS" = "ready_for_approval" ] || [ "$STATUS" = "approved" ] || [ "$STATUS" = "published" ]; then
    echo "    OK — release is already past validation ($STATUS)"
else
    stop "the release is in status '$STATUS', which is not a state this script can continue from"
fi

if [ "$MODE" = "inspect" ]; then
    echo ""
    echo "=============================================================="
    echo " INSPECTION ONLY — nothing was modified"
    echo "   credential: $AUTH_MODE${CREDENTIAL_ID:+ ($CREDENTIAL_ID)}"
    echo "   releaseId:  $RELEASE_ID"
    echo "   status:     $STATUS"
    echo "   artifactId: ${ARTIFACT_ID:-<none>}"
    echo "   sha256:     $EXPECTED_SHA"
    echo "   size:       $EXPECTED_SIZE"
    echo "   catalog:    latestVersion=$BASELINE_LATEST"
    echo "   validation: ready=$VALIDATION_READY"
    echo " Re-run without --inspect to continue publication."
    echo "=============================================================="
    exit 0
fi

# The server's own readiness computation gates every remaining transition —
# /submit, /approve and /publish each re-run it and answer 422 when it fails.
if [ "$STATUS" != "published" ] && [ "$VALIDATION_READY" != "True" ]; then
    stop "the server's readiness report is not ready for $VERSION — nothing was modified:
$(echo "$VALIDATION" | python3 -c 'import json,sys
d = json.load(sys.stdin)["data"]
for i in (d.get("issues") or []):
    print("  - " + str(i))
for r in (d.get("requirements") or []):
    if not r.get("valid"):
        print("  - %s/%s: %s" % (r.get("platform"), r.get("architecture"), ", ".join(r.get("issues") or [])))')"
fi

# --------------------------------------------------------------- 5. submit
if [ "$STATUS" = "validated" ]; then
    echo "==> [5/8] submitting for approval (validated -> ready_for_approval)"
    SUBMIT="$(curl_auth -X POST "$BASE/admin/releases/$RELEASE_ID/submit" -H "apikey: $ANON_KEY")"
    STATUS="$(echo "$SUBMIT" | read_status)"
    [ "$STATUS" = "ready_for_approval" ] || stop "the submit transition did not return 'ready_for_approval' (got '$STATUS'): $(echo "$SUBMIT" | head -c 300)"
    echo "    OK — release is ready for approval"
else
    echo "==> [5/8] already past 'validated' ($STATUS); skipping submit"
fi

# --------------------------------------------------------------- 6. approve
# APPROVAL IS THE HUMAN GATE. Automation reaches this point only because a human
# reviewed and approved the run at the release workflow's protected environment
# (or, for a local run, because a human started it with a credential). The
# approval is recorded server-side from the authenticated identity, so the audit
# trail names exactly which credential approved.
if [ "$STATUS" = "ready_for_approval" ]; then
    echo "==> [6/8] approving (ready_for_approval -> approved)"
    APPROVE="$(curl_auth -X POST "$BASE/admin/releases/$RELEASE_ID/approve" -H "apikey: $ANON_KEY")"
    STATUS="$(echo "$APPROVE" | read_status)"
    [ "$STATUS" = "approved" ] || stop "the approve transition did not return 'approved' (got '$STATUS'): $(echo "$APPROVE" | head -c 300)"
    echo "    OK — release is approved"
else
    echo "==> [6/8] already approved or published ($STATUS); skipping approve"
fi

# --------------------------------------------------------------- 7. publish
if [ "$STATUS" = "approved" ]; then
    [ "$VALIDATION_READY" = "True" ] || stop "the server's readiness report is not ready; nothing was published"
    PRE="$(curl -sS "$CATALOG&current=$CLIENT_VERSION")"
    PRE_LATEST="$(echo "$PRE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["latestVersion"])')" \
      || stop "the catalog could not be re-read immediately before publication"
    [ "$PRE_LATEST" = "$PREVIOUS_VERSION" ] \
      || stop "the catalog advertises '$PRE_LATEST' immediately before publication (expected $PREVIOUS_VERSION) — investigate before publishing"
    echo "==> [7/8] publishing ($VERSION) — the catalog is still $PREVIOUS_VERSION"
    PUBLISH="$(curl_auth -X POST "$BASE/admin/releases/$RELEASE_ID/publish" -H "apikey: $ANON_KEY")"
    STATUS="$(echo "$PUBLISH" | read_status)"
    [ "$STATUS" = "published" ] || stop "the publish transition did not return 'published' (got '$STATUS'): $(echo "$PUBLISH" | head -c 300)"
    echo "    OK — release is published"
elif [ "$STATUS" = "published" ]; then
    echo "==> [7/8] release is already published; skipping publish"
else
    stop "refusing to publish from status '$STATUS': the publish step requires 'approved'"
fi

# Only a release the SERVER reports as published may be verified: without this,
# a status this script failed to recognise could reach the public checks and be
# reported as a success it never was.
[ "$STATUS" = "published" ] || stop "refusing to verify: the server reports status '$STATUS', not 'published'"

# --------------------------------------------------------------- 8. verification
echo "==> [8/8] verifying through the public catalog and the download endpoint"
PUBLIC="$(curl -sS "$CATALOG&current=$PREVIOUS_VERSION")"
echo "$PUBLIC" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
assert d['latestVersion'] == '$VERSION', 'catalog latestVersion is ' + str(d['latestVersion'])
matching = [a for a in (d.get('artifacts') or [])
            if a.get('platform') == 'macos' and a.get('architecture') == 'arm64']
assert matching, 'no macos/arm64 artifact is exposed'
a = matching[0]
assert a.get('sha256') == '$EXPECTED_SHA', 'artifact sha mismatch: ' + str(a.get('sha256'))
assert str(a.get('fileSize')) == '$EXPECTED_SIZE', 'artifact size mismatch: ' + str(a.get('fileSize'))
assert a.get('fileName') == '$FILENAME', 'artifact name mismatch: ' + str(a.get('fileName'))
assert a.get('id') == '$ARTIFACT_ID', 'artifact id mismatch: ' + str(a.get('id'))
print('    OK — catalog serves %s %s bytes sha=%s (artifactId %s)' % (a['fileName'], a['fileSize'], a['sha256'][:12] + '…', a['id']))
print('    decision for a client on $PREVIOUS_VERSION: ' + str(d.get('decision')))
" || stop "post-publication verification failed — the catalog does not serve this artifact"

# The download smoke test: authorization, then the bytes. The signed URL is
# short-lived and is passed to curl through a stdin config, never argv.
AUTHZ="$(curl -sS "$BASE/downloads/authorize?artifactId=$ARTIFACT_ID")"
AUTHZ_OUT="$(echo "$AUTHZ" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('success') is True, d
a = d['data']
assert a.get('artifactId') == '$ARTIFACT_ID', 'authorized a different artifact: ' + str(a.get('artifactId'))
assert a.get('sha256') == '$EXPECTED_SHA', 'download sha mismatch: ' + str(a.get('sha256'))
assert str(a.get('fileSize')) == '$EXPECTED_SIZE', 'download size mismatch: ' + str(a.get('fileSize'))
assert a.get('fileName'), 'the authorization returned no file name'
assert a.get('signedUrl') and a.get('expiresAt'), 'no signed URL was minted'
print(a['signedUrl'])
print(a['fileName'])
")" || stop "the release IS published (releaseId $RELEASE_ID, artifactId $ARTIFACT_ID), but the download-authorization call did not authorize this artifact — investigate the download path; nothing else was modified"
SIGNED_URL="${AUTHZ_OUT%%$'\n'*}"
DOWNLOAD_NAME="${AUTHZ_OUT##*$'\n'}"
[ "$DOWNLOAD_NAME" = "$FILENAME" ] \
  || echo "    note: the download is offered as '$DOWNLOAD_NAME' (stored name: $FILENAME)"
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$GATE_DIR" "$DOWNLOAD_DIR"; _restore_terminal' EXIT
printf 'url = "%s"\n' "$SIGNED_URL" | curl -sS -L --fail -K - -o "$DOWNLOAD_DIR/$DOWNLOAD_NAME" \
  || stop "the release IS published (releaseId $RELEASE_ID), but the authorized download failed — investigate the download path"
DL_SHA="$(shasum -a 256 "$DOWNLOAD_DIR/$DOWNLOAD_NAME" | awk '{print $1}')"
DL_SIZE="$(stat -f '%z' "$DOWNLOAD_DIR/$DOWNLOAD_NAME")"
[ "$DL_SHA" = "$EXPECTED_SHA" ] || stop "the release IS published, but the downloaded file's SHA-256 is $DL_SHA, expected $EXPECTED_SHA — the served bytes are not the published candidate"
[ "$DL_SIZE" = "$EXPECTED_SIZE" ] || stop "the release IS published, but the downloaded file is $DL_SIZE bytes, expected $EXPECTED_SIZE"
echo "    OK — downloaded $DOWNLOAD_NAME through /downloads/authorize: $DL_SIZE bytes, sha256 verified"

echo ""
echo "=============================================================="
echo " PUBLISHED: music-prod-studio $VERSION"
echo "   releaseId:  $RELEASE_ID"
echo "   artifactId: $ARTIFACT_ID"
echo "   sha256:     $EXPECTED_SHA"
echo "   size:       $EXPECTED_SIZE"
echo "   credential: $AUTH_MODE${CREDENTIAL_ID:+ ($CREDENTIAL_ID)}"
echo " $PREVIOUS_VERSION was not touched and remains the published fallback."
echo "=============================================================="
