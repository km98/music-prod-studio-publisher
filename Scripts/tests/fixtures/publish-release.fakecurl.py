#!/usr/bin/env python3
"""Stateful fake curl for the offline suite of Scripts/publish-release.sh.

Replays the DEPLOYED admin lifecycle — draft -> uploaded -> validated ->
ready_for_approval -> approved -> published — together with the read-only
endpoints the script inspects before it mutates anything
(GET /admin/releases, GET /admin/releases/:id, GET /admin/releases/:id/validation)
and the public download path (GET /downloads/authorize, then the signed URL).

NOTHING IS INFERRED FROM ORDERING: each reply is a function of the URL the script
asked for, so a test can assert exactly which calls happened.

Beyond the API replay this fixture instruments the CREDENTIAL, which is what the
generic script exists for:

  * `auth=publisher` / `auth=admin` / `auth=none` on every log line, read from the
    `curl -K -` config stream — a test can therefore prove WHICH credential was
    used for each call, including that the automation never fell back to a human
    access token.
  * `argv_has_credential=yes|no` — whether any argv element looks like a
    credential (`mpspub_…` or a three-segment JWT). The script promises the
    credential never reaches a process argument; this measures it.

SCENARIO selects the story:
  (unset)          fresh publication: create -> upload -> validate -> submit ->
                   approve -> publish -> verify -> download
  resume           the release already exists in `validated` with the candidate
                   artifact attached (the partial-run state)
  alreadypublished a published release exists: verification only
  artifactmismatch the existing release carries a DIFFERENT artifact
  foreignversion   the existing row for this version is not the recorded draft
  wrongproduct     the previous version's row does not belong to this product
  notready         the server's readiness report says ready=false
  uploadmismatch   the upload reports different bytes than the local ZIP
  mismatch         the published catalog advertises a different artifact
  downloadcorrupt  the authorized download returns the wrong bytes

Environment:
  FAKECURL_COUNTER  file holding the call count (asserts "no call before a credential")
  FAKECURL_LOG      optional file: one "METHOD url auth=… argv_has_credential=…" line per call
  FAKECURL_ARTIFACT path to the real local ZIP, copied for the download
  FAKE_VERSION / FAKE_PREVIOUS / FAKE_SHA / FAKE_SIZE / FAKE_NAME / FAKE_PRODUCT_ID /
  FAKE_PREV_RELEASE_ID / FAKE_RELEASE_ID / FAKE_ARTIFACT_ID

  FAKE_RELEASE_NOTES  the PREVIOUS release's own notes: what the admin row for
                      FAKE_PREVIOUS carries and what the catalog reports while it
                      still serves that version.
  FAKE_CURRENT_NOTES  this run's notes / the current version's row: what the
                      catalog reports once it serves FAKE_VERSION.
"""
import os
import re
import sys

VERSION = os.environ.get("FAKE_VERSION", "2.0.13")
PREVIOUS = os.environ.get("FAKE_PREVIOUS", "2.0.12")
SHA = os.environ.get("FAKE_SHA", "")
SIZE = int(os.environ.get("FAKE_SIZE", "0"))
NAME = os.environ.get("FAKE_NAME", "")
PRODUCT_ID = os.environ.get("FAKE_PRODUCT_ID", "089e6865-3c63-4e90-941d-4677ae3707f0")
PREV_RELEASE_ID = os.environ.get("FAKE_PREV_RELEASE_ID", "b599de94-e679-4df3-870c-9cc77c3cf4fa")
RELEASE_ID = os.environ.get("FAKE_RELEASE_ID", "47c773cd-289e-4350-92a8-4a21dda44aed")
ARTIFACT_ID = os.environ.get("FAKE_ARTIFACT_ID", "317c5766-7d87-46c5-8c18-4673ed1d02d4")
# The notes the public catalog and the previous release's admin row must agree on.
NOTES = os.environ.get("FAKE_RELEASE_NOTES", "previous release notes")
# The notes THIS run intends to publish (its --release-notes-file). The row for
# the current version carries them when the scenario resumes a release this
# script's own earlier run created; `foreignversion` deliberately carries the
# other product's notes instead, so adopting it must be refused.
CURRENT_NOTES = os.environ.get("FAKE_CURRENT_NOTES", "") or NOTES

SCENARIO = os.environ.get("SCENARIO", "")

args = sys.argv[1:]
# Read the `curl -K -` config stream. Never block on a terminal: under the test
# harness stdin is /dev/null or the closed pipe carrying the config, and the
# isatty guard only keeps a hand-run probe from waiting forever.
config = ""
if not sys.stdin.isatty():
    try:
        config = sys.stdin.read()
    except Exception:
        config = ""

COUNTER = os.environ.get("FAKECURL_COUNTER")
if COUNTER:
    n = int(open(COUNTER).read()) if os.path.exists(COUNTER) else 0
    open(COUNTER, "w").write(str(n + 1))

# Which credential travelled, and whether it ever reached argv.
AUTH = "none"
if re.search(r'^\s*header\s*=\s*"X-Release-Publisher-Token:', config, re.M):
    AUTH = "publisher"
elif re.search(r'^\s*header\s*=\s*"Authorization:\s*Bearer', config, re.M):
    AUTH = "admin"
HEADER_LINES = "\n".join(re.findall(r'^\s*header\s*=\s*"(.*)"$', config, re.M))
# The header carries the credential by design; argv must never.
CREDENTIAL_IN_HEADER = bool(re.search(r'(mpspub_[a-z0-9]|^Authorization: Bearer )', HEADER_LINES, re.M))
ARGV_HAS_CREDENTIAL = any(
    re.match(r'^mpspub_[a-z0-9]', a) or re.match(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', a)
    for a in args
)

# The requested URL: an argument for a normal call, or the `url = "..."` line of a
# config stream (the script passes the short-lived signed URL that way so it never
# lands in argv).
url = ""
for a in args:
    if a.startswith("http://") or a.startswith("https://"):
        url = a
if not url:
    m = re.search(r'^\s*url\s*=\s*"([^"]+)"', config, re.M)
    if m:
        url = m.group(1)

method = "POST" if "-X" in args and "POST" in args else "GET"
LOG = os.environ.get("FAKECURL_LOG")
if LOG:
    with open(LOG, "a") as handle:
        handle.write("%s %s auth=%s argv_has_credential=%s header_has_credential=%s\n" % (
            method, url, AUTH, "yes" if ARGV_HAS_CREDENTIAL else "no",
            "yes" if CREDENTIAL_IN_HEADER else "no"))


def emit(obj, code=None):
    import json
    sys.stdout.write(json.dumps(obj))
    if code is not None and "-w" in args:
        sys.stdout.write("\n" + code)


def release(status, release_id=RELEASE_ID, version=VERSION, notes=NOTES, artifacts=None):
    body = {"id": release_id, "productId": PRODUCT_ID, "version": version, "status": status,
            "mandatory": False, "minimumSupportedVersion": "2.0.0", "releaseNotes": notes,
            "artifacts": artifacts or []}
    return {"success": True, "data": {"release": body}}


def artifact(**over):
    a = {"id": ARTIFACT_ID, "format": "app-bundle", "platform": "macos", "architecture": "arm64",
         "fileName": NAME, "fileSize": SIZE, "sha256": SHA}
    a.update(over)
    return a


PREVIOUS_ARTIFACT = {"id": PREV_RELEASE_ID, "format": "app-bundle", "platform": "macos",
                     "architecture": "arm64", "fileName": "Music-Prod-Studio-%s.zip" % PREVIOUS,
                     "fileSize": 1234567, "sha256": "1" * 64}


def updates(latest, artifacts):
    # The catalog reports the notes of the release it is SERVING: the previous
    # release while this is a first publication, and THIS version once the
    # catalog already serves it (a verification pass). Serving the previous
    # release's notes in that second case would hide the whole class of
    # mismatches the script's [1/8] check exists to catch.
    served_notes = CURRENT_NOTES if latest == VERSION else NOTES
    return {"success": True, "data": {
        "product": "music-prod-studio", "currentVersion": "", "latestVersion": latest,
        "latestReleaseId": PREV_RELEASE_ID, "updateAvailable": True, "decision": "optionalUpdate",
        "mustUpdate": False, "mandatory": False, "minimumSupportedVersion": "2.0.0",
        "releaseNotes": served_notes, "artifacts": artifacts}}


# --- the download (signed URL on the config stream, bytes written by -o) -----
if "/object/sign/" in url or "/storage/v1/object/" in url:
    target = ""
    for i, a in enumerate(args):
        if a == "-o" and i + 1 < len(args):
            target = args[i + 1]
        elif a.startswith("-o") and len(a) > 2:
            target = a[2:]
    if target:
        payload = b"corrupted payload, not the candidate\n" if SCENARIO == "downloadcorrupt" else None
        if payload is None:
            with open(os.environ["FAKECURL_ARTIFACT"], "rb") as src:
                payload = src.read()
        with open(target, "wb") as dst:
            dst.write(payload)
    sys.exit(0)

if "/downloads/authorize" in url:
    emit({"success": True, "data": {
        "artifactId": ARTIFACT_ID, "fileName": NAME, "fileSize": SIZE, "sha256": SHA,
        "signedUrl": "https://project.supabase.co/storage/v1/object/sign/releases/x.zip?token=fake",
        "expiresAt": "2026-10-14T12:00:00.000Z"}})
    sys.exit(0)

# --- /updates: the pre-publication catalog serves PREVIOUS, the post serves VERSION
if "/updates" in url:
    if SCENARIO == "alreadypublished":
        emit(updates(VERSION, [artifact()]))
    elif "current=%s" % PREVIOUS in url:
        served = artifact(sha256="deadbeef" * 8) if SCENARIO == "mismatch" else artifact()
        emit(updates(VERSION, [served]))
    else:
        emit(updates(PREVIOUS, [PREVIOUS_ARTIFACT]))
    sys.exit(0)

# --- artifact upload --------------------------------------------------------
if re.search(r"/admin/releases/[^/]+/artifacts$", url):
    if SCENARIO == "uploadmismatch":
        emit({"success": True, "data": {"artifact": artifact(sha256="deadbeef" * 8)}}, "201")
    else:
        emit({"success": True, "data": {"artifact": artifact()}}, "201")
    sys.exit(0)

# --- read-only validation report -------------------------------------------
if url.endswith("/validation"):
    ready = SCENARIO != "notready"
    emit({"success": True, "data": {
        "valid": True, "issues": [], "ready": ready,
        "requirements": [{"label": "macos", "platform": "macos", "architecture": "arm64",
                          "format": None, "present": True, "artifactId": ARTIFACT_ID,
                          "valid": ready, "issues": [] if ready else ["missing from storage"]}]}})
    sys.exit(0)

# --- explicit transitions ---------------------------------------------------
for action, status in (("/ready", "validated"), ("/validate", "validated"),
                       ("/submit", "ready_for_approval"), ("/approve", "approved"),
                       ("/publish", "published"), ("/commit", "published")):
    if url.endswith(action):
        emit(release(status))
        sys.exit(0)

# --- GET /admin/releases/:id (detail with artifacts) ------------------------
if re.search(r"/admin/releases/[^/]+$", url):
    if SCENARIO in ("resume", "notready", "alreadypublished"):
        arts = [artifact()]
    elif SCENARIO == "artifactmismatch":
        arts = [artifact(sha256="deadbeef" * 8)]
    else:
        arts = []
    if SCENARIO == "alreadypublished":
        status = "published"
    elif SCENARIO in ("resume", "notready", "artifactmismatch"):
        status = "validated"
    else:
        status = "draft"
    emit(release(status, artifacts=arts), "200")
    sys.exit(0)

# --- GET/POST /admin/releases -----------------------------------------------
if url.endswith("/admin/releases"):
    if method == "POST":
        emit(release("draft"), "201")
        sys.exit(0)
    rows = [{"id": PREV_RELEASE_ID, "productId": PRODUCT_ID, "version": PREVIOUS,
             "status": "published", "releaseNotes": NOTES, "mandatory": False,
             "minimumSupportedVersion": "2.0.0"}]
    if SCENARIO in ("resume", "notready", "artifactmismatch"):
        rows.append({"id": RELEASE_ID, "productId": PRODUCT_ID, "version": VERSION,
                     "status": "validated", "releaseNotes": CURRENT_NOTES,
                     "minimumSupportedVersion": "2.0.0"})
    elif SCENARIO == "alreadypublished":
        rows.append({"id": RELEASE_ID, "productId": PRODUCT_ID, "version": VERSION,
                     "status": "published", "releaseNotes": CURRENT_NOTES,
                     "minimumSupportedVersion": "2.0.0"})
    elif SCENARIO == "foreignversion":
        rows.append({"id": "cccccccc-dddd-eeee-ffff-000000000000", "productId": PRODUCT_ID,
                     "version": VERSION, "status": "draft", "releaseNotes": NOTES})
    if SCENARIO == "wrongproduct":
        # The previous version's admin row must belong to this product: same
        # version and status, different release notes.
        rows[0] = dict(rows[0], releaseNotes="some other product's release notes")
    emit({"success": True, "data": {"releases": rows}}, "200")
    sys.exit(0)

emit({"success": False, "error": "no route in the fake curl for " + url,
      "errorCode": "invalidRequest"}, "404")
sys.exit(0)
