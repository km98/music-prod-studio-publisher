#!/bin/bash
# verify-publisher-credential.sh — read-only proof that the configured release
# publisher credential is ACCEPTED by the deployed music-prod-studio-api.
#
# WHAT IT DOES
#   Exactly one request: `GET /admin/releases` with the publisher credential in
#   its own header. Nothing is created, uploaded, approved, published, promoted
#   or modified — there is no mutating call in this file.
#
# WHY A 401 IS THE WHOLE SIGNAL, AND WHY THAT MATTERS
#   The credential is checked by the function's admin seam (publisherGuard.ts)
#   BEFORE the router reaches any handler, and that seam answers a refused
#   credential with the SAME envelope the human admin path uses:
#     HTTP 401  {"errorCode":"unauthenticated",
#                "error":"authentication is required for this endpoint"}
#   That is deliberate ("callers cannot tell which seam refused them"), so this
#   script reports the STATUS and the server's own words — it never guesses a
#   cause. A 401 means "the credential was not accepted"; distinguishing "the
#   deployed function has no publisher guard" from "the deployed credential list
#   does not carry this entry" needs backend access, not a cleverer request.
#
# CREDENTIAL HANDLING
#   MPS_PUBLISHER_TOKEN        the credential (what CI uses)
#   MPS_PUBLISHER_TOKEN_FILE   the same value in a 0600 file (local runs)
#   The value is passed to curl as a `-K -` config on STDIN, so it is never a
#   process argument and `ps` can never capture it. It is never echoed, never
#   traced (`set -x` is deliberately absent), never written to disk, and never
#   placed in an argument to this script's own helpers.
#
#   Only the credential's ID (a label like `ci-2026-10`) is printed. The response
#   body is SUMMARISED by a parser — never dumped — so nothing a release row
#   carries can reach a CI log either.
#
# Exit codes: 0 = the credential was accepted (HTTP 200)
#             1 = refused or the request failed (with a sanitized reason)
#             2 = usage/configuration error (no usable credential supplied)

set -uo pipefail
# NOTE: deliberately NOT `set -x` anywhere — tracing would leak the credential.

BASE="${MPS_API_BASE:-https://wfpeajmdojcjqyrsnxbk.supabase.co/functions/v1/music-prod-studio-api}"
ROUTE="${MPS_ADMIN_ROUTE:-/admin/releases}"
PUBLISHER_RE='^mpspub_[a-z0-9][a-z0-9-]{0,31}_[A-Za-z0-9_-]{43,}$'

refuse() { echo "REFUSED: $1" >&2; exit 2; }

TOKEN=""
SOURCE=""
if [ -n "${MPS_PUBLISHER_TOKEN:-}" ]; then
    TOKEN="$MPS_PUBLISHER_TOKEN"
    SOURCE="MPS_PUBLISHER_TOKEN"
elif [ -n "${MPS_PUBLISHER_TOKEN_FILE:-}" ]; then
    [ -f "$MPS_PUBLISHER_TOKEN_FILE" ] \
        || refuse "MPS_PUBLISHER_TOKEN_FILE does not exist: $MPS_PUBLISHER_TOKEN_FILE"
    # A file readable by group or others is a leaked secret, not a convenience.
    PERMS="$(stat -f '%Lp' "$MPS_PUBLISHER_TOKEN_FILE")"
    case "$PERMS" in
        600|400|700|500) ;;
        *) refuse "the publisher credential file must not be group- or world-readable (mode $PERMS); run: chmod 600 '$MPS_PUBLISHER_TOKEN_FILE'" ;;
    esac
    TOKEN="$(cat "$MPS_PUBLISHER_TOKEN_FILE")"
    TOKEN="${TOKEN%$'\n'}"
    SOURCE="MPS_PUBLISHER_TOKEN_FILE"
else
    refuse "no credential was supplied — set MPS_PUBLISHER_TOKEN (CI) or MPS_PUBLISHER_TOKEN_FILE (local). Nothing was sent."
fi

[ -n "$TOKEN" ] || refuse "the supplied credential is empty. Nothing was sent."
# The shape is checked BEFORE the request: a value that cannot be a publisher
# credential is a configuration error here, not something to send and interpret.
printf '%s' "$TOKEN" | grep -qE "$PUBLISHER_RE" \
    || refuse "the supplied value is not a release publisher credential (expected mpspub_<id>_<secret>). Nothing was sent."

# The ID is a label, not a secret — it is the only part of the value ever printed.
CREDENTIAL_ID="$(printf '%s' "$TOKEN" | sed -E 's/^mpspub_([a-z0-9][a-z0-9-]{0,31})_.*$/\1/')"

echo "==> read-only credential check: GET $BASE$ROUTE"
echo "    credential   : $CREDENTIAL_ID (from $SOURCE; the secret itself is never printed)"
echo "    scope        : enforced server-side — this call only reads"

# The credential travels on stdin as a curl config, so it never reaches argv.
RESP="$(printf 'header = "X-Release-Publisher-Token: %s"\n' "$TOKEN" \
        | curl -sS -K - -w $'\n%{http_code}' "$BASE$ROUTE")" || {
    unset TOKEN
    echo "FAILED: the request to $BASE$ROUTE did not complete (network, DNS or TLS)." >&2
    echo "        Nothing was modified." >&2
    exit 1
}
unset TOKEN

CODE="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"

SUMMARY="$(printf '%s' "$BODY" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("error\t-\tthe response was not JSON")
    raise SystemExit(0)
if not isinstance(d, dict):
    print("error\t-\tthe response was not an object")
    raise SystemExit(0)
rows = None
data = d.get("data")
if isinstance(data, dict):
    rows = data.get("releases")
if d.get("success") is not True:
    err = str(d.get("error") or "(no message)").replace("\t", " ")
    code = str(d.get("errorCode") or "-").replace("\t", " ")
    print("failure\t%s\t%s" % (code, err))
elif isinstance(rows, list):
    published = [r for r in rows if isinstance(r, dict) and r.get("status") == "published"]
    versions = [str(r.get("version") or "?") for r in (published or rows)[:5]]
    print("ok\t%d\t%d\t%s" % (len(rows), len(published), ", ".join(versions) or "(none)"))
else:
    print("ok-empty\t0\t0\t(response carried no release list)")
' 2>/dev/null)" || SUMMARY=""

IFS=$'\t' read -r KIND FIELD_A FIELD_B FIELD_C <<< "${SUMMARY:-error	-	the response could not be read}"

case "$CODE:$KIND" in
    200:ok|200:ok-empty)
        echo "    HTTP $CODE — the credential was ACCEPTED"
        echo "    releases visible: ${FIELD_A:-?} (published: ${FIELD_B:-?})"
        echo "    versions         : ${FIELD_C:-?}"
        echo ""
        echo "RESULT: PASS — the deployed API accepted publisher credential '$CREDENTIAL_ID'. Nothing was modified."
        exit 0
        ;;
    401:*)
        echo "    HTTP 401 — the credential was NOT accepted" >&2
        echo "    server said: $FIELD_B (errorCode: $FIELD_A)" >&2
        echo "" >&2
        echo "    The deployed admin seam answers a refused publisher credential with the" >&2
        echo "    same envelope the human admin path uses, so this status does not say WHICH" >&2
        echo "    cause applies. The candidates are:" >&2
        echo "      * the deployed function does not contain the publisher guard, so the" >&2
        echo "        header is ignored and the human path refuses; or" >&2
        echo "      * the deployment's RELEASE_PUBLISHER_CREDENTIALS list does not carry this" >&2
        echo "        credential's id and digest." >&2
        echo "" >&2
        echo "    Nothing was modified. Do NOT regenerate the credential or change the stored" >&2
        echo "    digest to make this pass: identify the mismatch on the backend first." >&2
        exit 1
        ;;
    403:*)
        echo "    HTTP 403 — the credential is valid but is not scoped to this route" >&2
        echo "    server said: $FIELD_B (errorCode: $FIELD_A)" >&2
        echo "    Nothing was modified." >&2
        exit 1
        ;;
    *)
        echo "    HTTP $CODE — the credential check did not succeed" >&2
        echo "    server said: ${FIELD_B:-$FIELD_C} (errorCode: ${FIELD_A:--})" >&2
        echo "    Nothing was modified." >&2
        exit 1
        ;;
esac
