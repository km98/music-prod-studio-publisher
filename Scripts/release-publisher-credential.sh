#!/bin/bash
# release-publisher-credential.sh — create, rotate and revoke the MACHINE
# credential that publishes Music-Prod Studio releases.
#
# WHAT IT PRODUCES
#   1. a token file (0600) holding the secret, e.g. `mpspub_ci-2026-10_<43 chars>`
#      → this is the value that goes into the GitHub Actions environment secret
#        MPS_PUBLISHER_TOKEN
#   2. the SERVER-side entry for that token, which contains ONLY its SHA-256:
#        RELEASE_PUBLISHER_CREDENTIALS=<id>:<sha256>:write
#      → this goes into the backend's secret configuration (Lovable Cloud /
#        Edge Function secrets), never into a file in the repository
#
# THE SECRET IS NEVER PRINTED. It is written to the file and nothing else, so it
# cannot land in a terminal scrollback, a CI log, or a chat transcript. Everything
# this script prints on stdout is safe to share: credential ids, SHA-256 digests
# and instructions.
#
# The server stores the digest, never the secret, and it compares digests in
# constant time (see supabase/functions/_shared/releasePublisherAuth.ts). A
# credential is revoked by removing its entry from the list, and rotated by
# having two entries at once for the length of one deployment.
#
# USAGE
#   Scripts/release-publisher-credential.sh generate --id <id> [--out <file>]
#       [--scope write|read] [--actor <uuid>]
#   Scripts/release-publisher-credential.sh rotate --id <new-id> [--out <file>]
#       [--previous <old-id>] [--scope write|read]
#   Scripts/release-publisher-credential.sh revoke --id <id> [--entry <list>]
#   Scripts/release-publisher-credential.sh hash --file <token-file>
#   Scripts/release-publisher-credential.sh actor
#
# Exit codes: 0 = ok · 1 = refused (with a named reason) · 2 = usage error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDENTIAL_ID_RE='^[a-z0-9][a-z0-9-]{0,31}$'
SCOPE_RE='^(write|read)$'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

refuse() { echo "REFUSED: $1" >&2; exit 1; }
usage_error() { echo "$1" >&2; sed -n '/^# USAGE$/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }

COMMAND="${1:-}"
[ -n "$COMMAND" ] || usage_error "no command given"
shift || true

ID=""; OUT=""; SCOPE="write"; ACTOR=""; FILE=""; ENTRY=""; PREVIOUS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --id)       ID="${2:-}"; shift 2 ;;
        --out)      OUT="${2:-}"; shift 2 ;;
        --scope)    SCOPE="${2:-}"; shift 2 ;;
        --actor)    ACTOR="${2:-}"; shift 2 ;;
        --file)     FILE="${2:-}"; shift 2 ;;
        --entry)    ENTRY="${2:-}"; shift 2 ;;
        --previous) PREVIOUS="${2:-}"; shift 2 ;;
        -h|--help)  usage_error "help" ;;
        *)          usage_error "unknown argument '$1'" ;;
    esac
done

# A secret must never be written into the repository, because the repository is
# what gets committed, shared and backed up.
default_out() { printf '%s' "$HOME/.music-prod-studio/publisher-credential-$1"; }

check_out_path() { # check_out_path <path>
    local path="$1"
    local abs_dir abs
    abs_dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || refuse "the directory for '$path' does not exist (create it first; the credential file is never created inside a missing path)"
    abs="$abs_dir/$(basename "$path")"
    case "$abs" in
        "$REPO_ROOT"/*) refuse "'$abs' is inside the repository ($REPO_ROOT). A credential must never live in a tracked tree — pass --out with a path outside it, e.g. ~/.music-prod-studio/publisher-credential-<id>" ;;
    esac
    printf '%s' "$abs"
}

new_secret() {
    # 32 bytes from the CSPRNG, base64url (43 characters). 256 bits of entropy is
    # not guessable and fits the token alphabet the server validates.
    python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))'
}

new_uuid() {
    python3 -c 'import uuid; print(uuid.uuid4())'
}

case "$COMMAND" in
    generate|rotate)
        [ -n "$ID" ] || usage_error "$COMMAND requires --id <id>"
        printf '%s' "$ID" | grep -qE "$CREDENTIAL_ID_RE" \
            || refuse "--id '$ID' must be 1-32 characters of [a-z0-9-], starting with a letter or digit"
        printf '%s' "$SCOPE" | grep -qE "$SCOPE_RE" || refuse "--scope must be 'write' or 'read'"
        if [ "$COMMAND" = "rotate" ] && [ -z "$PREVIOUS" ]; then
            PREVIOUS="<the id you are replacing>"
        fi
        # Every input is judged BEFORE anything is written, so a refused run
        # leaves no half-created credential behind.
        if [ -n "$ACTOR" ]; then
            printf '%s' "$ACTOR" | grep -qiE "$UUID_RE" \
                || refuse "--actor '$ACTOR' is not a UUID (it is recorded as the release actor, so it must be one)"
            ACTOR_VALUE="$ACTOR"
        else
            ACTOR_VALUE="$(new_uuid)"
        fi
        OUT="${OUT:-$(default_out "$ID")}"
        ABS_OUT="$(check_out_path "$OUT")"
        [ -e "$ABS_OUT" ] && refuse "'$ABS_OUT' already exists — refusing to overwrite a credential that may still be in use (remove it deliberately, or choose another --id)"

        SECRET="$(new_secret)"
        TOKEN="mpspub_${ID}_${SECRET}"
        umask 077
        mkdir -p "$(dirname "$ABS_OUT")"
        printf '%s\n' "$TOKEN" > "$ABS_OUT"
        chmod 600 "$ABS_OUT"
        # The server hashes the TOKEN, not the file: the file ends with a
        # newline that is not part of the secret.
        SECRET_HASH="$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')"

        echo "publisher credential '$ID' created (scope: $SCOPE)"
        echo ""
        echo "  1. GitHub Actions environment secret (run this from a checkout; the value is read from the file, never typed):"
        echo "       gh secret set MPS_PUBLISHER_TOKEN --env production < '$ABS_OUT'"
        echo ""
        echo "  2. Backend secret configuration (Lovable Cloud → Edge Function secrets), adding this ENTRY to the list:"
        echo "       RELEASE_PUBLISHER_CREDENTIALS   ${ID}:${SECRET_HASH}:${SCOPE}"
        echo "     and, once per project:"
        echo "       RELEASE_PUBLISHER_ACTOR_ID     ${ACTOR_VALUE}"
        echo ""
        echo "  3. Redeploy the music-prod-studio-api function so the entry takes effect."
        echo ""
        echo "  The token itself is in $ABS_OUT (mode 600) and is NOT printed here."
        if [ "$COMMAND" = "rotate" ]; then
            cat <<ROTATE

  ROTATION IS A TWO-ENTRY WINDOW — do it in this order:
    a. ADD the new entry beside the old one, so the deployed list reads
         RELEASE_PUBLISHER_CREDENTIALS   <old-id>:<old-hash>:write,${ID}:${SECRET_HASH}:${SCOPE}
       and redeploy. Both credentials now work.
    b. Move the caller to the new token (the gh command above).
    c. Confirm a publication (or a --inspect run) succeeds with the new token.
    d. REMOVE the old entry ('${PREVIOUS}') and redeploy. The old token is now dead.
ROTATE
        fi
        ;;
    revoke)
        [ -n "$ID" ] || usage_error "revoke requires --id <id>"
        [ -n "$ENTRY" ] || refuse "revoke needs the current list so the entry can be removed exactly: --entry '<id>:<hash>:<scope>,<id2>:<hash2>:<scope2>'"
        python3 - "$ID" "$ENTRY" <<'PY' || exit 1
import sys
target, entries = sys.argv[1], sys.argv[2]
kept, removed = [], []
for entry in [e.strip() for e in entries.split(',') if e.strip()]:
    (removed if entry.split(':', 1)[0] == target else kept).append(entry)
if not removed:
    print("REFUSED: '%s' is not in the supplied list; nothing to revoke" % target, file=sys.stderr)
    raise SystemExit(1)
print("removed %d entry/entries for '%s'" % (len(removed), target))
print("")
print("  set the backend secret to exactly this, then redeploy:")
print("    RELEASE_PUBLISHER_CREDENTIALS   %s" % (",".join(kept) if kept else "(empty — no machine credential is authorized)"))
PY
        echo ""
        echo "  Then delete the token file and remove the GitHub secret:"
        echo "       gh secret delete MPS_PUBLISHER_TOKEN --env production"
        ;;
    hash)
        [ -n "$FILE" ] || usage_error "hash requires --file <token-file>"
        [ -f "$FILE" ] || refuse "no such file: $FILE"
        TOKEN="$(cat "$FILE")"
        TOKEN="${TOKEN%$'\n'}"
        printf '%s' "$TOKEN" | grep -qE '^mpspub_[a-z0-9][a-z0-9-]{0,31}_[A-Za-z0-9_-]{43,}$' \
            || refuse "'$FILE' does not contain a publisher token (expected mpspub_<id>_<secret>)"
        TOKEN_ID="$(printf '%s' "$TOKEN" | sed -E 's/^mpspub_([a-z0-9][a-z0-9-]{0,31})_.*$/\1/')"
        TOKEN_HASH="$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')"
        echo "id:     $TOKEN_ID"
        echo "sha256: $TOKEN_HASH"
        echo "entry:  ${TOKEN_ID}:${TOKEN_HASH}:write   (…or :read for the read-only scope)"
        ;;
    actor)
        echo "$(new_uuid)"
        ;;
    *)
        usage_error "unknown command '$COMMAND'"
        ;;
esac
