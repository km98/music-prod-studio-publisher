# music-prod-studio-publisher

Release **publication automation** for Music-Prod Studio, hosted in a public
repository so GitHub Actions can run it without making the application source
public.

This repository contains **no application source code and no Git history from the
application repository**. It holds the publisher tooling, its validation scripts,
their tests, and this runbook — nothing else.

## Contents

| path | what it is |
|---|---|
| `.github/workflows/release-publish.yml` | the publication workflow (`workflow_dispatch` only) |
| `.github/workflows/verify-publisher.yml` | read-only check that the deployment accepts the credential |
| `Scripts/publish-release.sh` | the publisher: the deployed admin lifecycle, every digest check, every STOP |
| `Scripts/verify-app-resources.sh` | the packaged-resource gate (the shipped 2.0.11 launch crash) |
| `Scripts/verify-app-icon-artwork.py` | pixel-level proof the icon is the genuine website artwork |
| `Scripts/fetch-published-candidate.sh` | fetches an already-published candidate through the public read-only routes |
| `Scripts/verify-publisher-credential.sh` | one read-only `GET /admin/releases`; never mutates anything |
| `Scripts/release-publisher-credential.sh` | generate / rotate / revoke the machine credential |
| `Scripts/tests/` | the offline suites (no network, no production contact) |
| `assets/music-prod-favicon.png` | the pinned public favicon the icon gate compares against |

`Scripts/publish-release.sh`, `verify-app-resources.sh`, `verify-app-icon-artwork.py`,
`release-publisher-credential.sh` and the `publish-release`/`verify-app-resources`
suites are mirrored **unchanged** from the application repository, so the
publication path that ran in production is the one that runs here. Only the
workflow and its candidate source differ; see "What changed, and why".

## One-time setup

1. **Environment.** Repository → Settings → Environments → `production`.
   Add **Required reviewers** (this is the human gate: the job, and the
   credential with it, is withheld until a reviewer approves). Available on a
   public repository without a paid plan.
2. **Repository variable.** `MPS_PUBLISH_AUTOMATION_READY = true`. The workflows
   refuse to run without it — it is your statement that the environment above is
   protected and configured.
3. **Environment secret.** `MPS_PUBLISHER_TOKEN`, set from the credential file
   so the value is never typed, never printed and never in a command argument:

   ```sh
   gh secret set MPS_PUBLISHER_TOKEN --env production \
       --repo km98/music-prod-studio-publisher \
     < ~/.music-prod-studio/publisher-credential-ci-2026-10
   ```

   No other secret is needed. In particular there is **no token for reading the
   application repository** — this repository never reads it.

The credential itself is created, rotated and revoked with
`Scripts/release-publisher-credential.sh`; the server stores only its SHA-256
digest, so a leak of the credential store is not replayable. Rotation is a
two-entry window (add the new entry, redeploy, move the secret, confirm, remove
the old entry) — the script prints the exact order.

## Verification before a publication

Run **Verify publisher credential** (read-only). It makes one request —
`GET /admin/releases` — and reports the status. Nothing is created, approved,
published or modified.

A `200` means the deployment accepts the credential. A `401` means it does not,
and the response cannot tell you which side is missing (see "When it stops").

## Publishing a release

1. Build, notarize and staple as usual in the application repository.

   ```sh
   Scripts/release-finalize.sh --all --state-root build/release-<version>-<build>
   ```

   Read the FINAL post-staple `finalZipSha256` / `finalZipBytes` from its
   `release-manifest.json`. Never take them from a document or a previous run.
2. Attach the notarized ZIP to a prerelease **in this repository**, so the runner
   can fetch it without any access to a private one:

   ```sh
   gh release create release-candidate-<version> \
       build/release-<version>-<build>/Music-Prod-Studio-<version>-<build>.zip \
       --repo km98/music-prod-studio-publisher --prerelease
   ```

   Do **not** attach the release record (`release-manifest.json`): it is produced
   by the private signing pipeline and contains the operator's local paths. The
   workflow proves those same properties from the artifact's own bytes instead
   (see "What changed, and why").
3. Run **Publish release** with `candidate_source = release-asset`, the version,
   build, previous version, `candidate_tag`, digest, size, notes, and
   `confirm` = the version.
4. **Approve** the run when GitHub asks (the `production` environment gate).
5. Read the run summary: the release id, the artifact id, the digest, and the
   verification lines. The log is attached to the run as evidence.

A re-run after a partial failure is safe: the script adopts the existing release
and artifact, never creates a second one, and never repeats a transition that has
already happened.

## Inspecting or attesting an already-published release

Set `candidate_source = published` and `dry_run = true`.

The candidate is then the artifact the **public production catalog already
serves** for that version, fetched through `GET /downloads/authorize` with no
credential at all. The run walks the read-only checks and stops at:

```
 INSPECTION ONLY — nothing was modified
```

Because the script runs in inspection mode, **no draft release is created**. This
is how an already-published release's bytes are proved to be the ones this
workflow would have published, without rebuilding, re-signing or re-uploading
anything. It refuses a version that is not published yet, and says so.

## What changed, and why

The application repository is private, and Actions could not start there
(account billing), while required reviewers on a private repository need a paid
plan. A public repository fixes both. Two consequences follow, and both are
deliberate:

**1. The candidate never comes from the private repository.** The workflow cannot
read the private repository's release assets, and it is not given a token that
could. A candidate is either the public catalog's artifact for a published
version (`candidate_source = published`), or a ZIP attached to a prerelease of
**this** repository (`release-asset`). Nothing private is mirrored here.

**2. The release record is replaced by proofs read from the artifact.** The
workflow previously cross-checked `release-manifest.json`, which records
`mode: production`, `stapled: yes`, `notarizationSubmitted: yes`,
`evidenceVerdict: PASS` and `finalGateResult: PASS`. That file carries the
signing operator's local filesystem paths, so it must not be published. Instead
the workflow proves the same properties **from the candidate's own bytes**:
bundle version and build, a valid `codesign --verify --deep --strict`, a
Developer ID Application authority, Hardened Runtime, a stapled notarization
ticket (`xcrun stapler validate`), and an `accepted` Gatekeeper verdict
(`spctl -a -vvv -t install`) — plus the packaged startup-critical resource gate
the publisher script runs against the shipped ZIP. These are stronger than the
record's claims, because an artifact cannot be wrong about itself.

Measured evidence for the 2.0.13 candidate (2026-10-16): the ZIP attached to the
private `release-candidate-2.0.13` prerelease and the publicly downloadable
published artifact are **byte-identical** — sha256
`b3ad490c8b88e207d9b67040bd68872778f995a6303147f9af3011bc1b78319c`, 5296526
bytes on both sides — which is why the inspection path can attest the published
release without copying anything into this repository.

## When it stops

| symptom | meaning | what to do |
|---|---|---|
| `the credential is NOT accepted` / `HTTP 401` | the deployment did not accept the publisher credential. The admin seam answers a refused credential with the **same** envelope the human path uses, so the status alone cannot say which side is missing. Candidates: (a) the deployed function has no publisher guard, so the header is ignored; (b) the deployment's `RELEASE_PUBLISHER_CREDENTIALS` list does not carry this id/digest | confirm which, on the backend, **before** changing anything. Do not regenerate the credential and do not change the stored digest to make the check pass |
| `HTTP 403` | the credential is valid but the route is outside its scope | nothing was modified; the publication routes are `/admin/releases…` |
| `the live catalog serves 'X', not the requested 'Y'` | `candidate_source = published` was used for a version that is not the published one | use `release-asset` for a new version, or the correct version for an attestation |
| `refusing to fetch bytes the catalog does not vouch for` | the requested digest does not match what the live catalog serves | re-read the post-staple digest from the release record; never edit the digest to match the bytes |
| `the packaged app reports version 'X'` | the candidate ZIP is not the release being published | attach the right build |
| `no stapled notarization ticket` | the artifact was not stapled | re-run the release pipeline; do not publish it |
| `Gatekeeper does NOT accept` | the artifact would be blocked on a user's Mac | treat as an incident |
| `the permission to ... ` / `REFUSED: required reviewers` | the `production` environment is not configured | finish "One-time setup" |
| `the repository variable MPS_PUBLISH_AUTOMATION_READY is not 'true'` | the readiness statement is missing | set it only once the environment is genuinely protected |

## Security properties, and the honest limitations

**Properties**

* `workflow_dispatch` only — no push, no pull request, no schedule, so a secret
  can never reach an unreviewed event. Inputs are validated before any request is
  built, and `confirm` must repeat the version.
* `permissions: contents: read` and `persist-credentials: false`; third-party
  actions are pinned to immutable commit SHAs.
* `concurrency: release-publication` with `cancel-in-progress: false` — one
  publication run at a time.
* the credential exists only as a GitHub environment secret and in a `0600` file
  outside any repository. It is passed to `curl` through a `-K -` stdin config,
  so it never appears in a process argument, and a dedicated step fails the run
  if it appears in the log. `set -x` is banned in the scripts and the suites
  assert it.
* the server stores and compares SHA-256 digests only, in constant time, and
  scopes the credential to the release routes.
* human approval is structural: the dispatch, the protected environment's
  required reviewers, and the version confirmation.

**Limitations (not claimed as solved)**

* **The backend half is not deployed.** Measured 2026-10-16: the publisher guard
  exists only as uncommitted local files in the site project, the project is not
  linked to a Supabase project, no access token is present, and the deployed
  function answers the credential with `401`. Until the guard is deployed and
  `RELEASE_PUBLISHER_CREDENTIALS` / `RELEASE_PUBLISHER_ACTOR_ID` are set on the
  deployment, the credential cannot be accepted and no publication can run. This
  is a backend action, not a change to make here.
* **The credential is a bearer token, not a federated identity.** GitHub OIDC
  would remove the long-lived secret, but it requires the Edge Function to verify
  GitHub's OIDC JWTs. The two-entry rotation window is the mitigation meanwhile.
* **Anyone who can approve the `production` environment can publish.** That is
  intentional — it is the human gate — and it is why the reviewer list must be
  kept to people who are meant to publish.
* **A `write` credential can approve a release** (`/approve` is in its scope).
  For separation of duties, remove `approve` from the credential's route list
  server-side and let a human approve.
* **`candidate_source = published` cannot attest a release that is not yet
  published** — by construction, it reads the live catalog. It is the attestation
  path, not the publication path.

## Running the suites

```sh
Scripts/run-publisher-tests.sh
```

Offline: no network, no production contact, no release artifact needed. The
`publish-release` suite's lifecycle replay needs a local notarized candidate and
skips with an explicit reason when there is none, rather than passing silently.
