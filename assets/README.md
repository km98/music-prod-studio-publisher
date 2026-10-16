# assets/

This directory holds exactly one file, and it is here for one reason: the
packaged-resource gate has to compare the icon inside a candidate `.app` with the
**genuine** artwork, and a gate with no reference cannot fail closed.

| file | sha256 | size | origin |
|---|---|---|---|
| `music-prod-favicon.png` | `2bcce3c806ca8434cb4e8c283c88df849078bd2d3775fa23ed3744daf89305b9` | 2192 bytes | `https://music-prod.com/favicon.png` (64×64, the icon declared by `<link rel="icon">` on the deployed site) |

## Why it is safe to publish

* It is the **public website's own artwork**, served anonymously by the deployed
  site. It is not application source code, not a font, not a licensed asset, and
  not derived from the private repository's history.
* It contains nothing but 64×64 pixels of a public logo.
* The application build pins the same file by the same digest
  (`Scripts/build-app.sh`, `EXPECTED_FAVICON_SHA256`), so a divergence between
  this pin and the application's is a build-time error rather than a silent drift.

## How it is used

The publication workflow verifies this file against the digest above **before**
anything else runs, and passes it to the packaged-resource gate through
`MPS_ICON_REFERENCE`. A modified or replaced favicon therefore refuses the run
instead of quietly accepting a different icon.

`Scripts/tests/verify-app-resources.test.sh` uses it as the reference for the
icon cases (genuine, flat-purple placeholder, padded, missing 1024, foreign mark),
so the check that caught the shipped purple placeholder icon still runs offline,
with no network access.

## Updating it

Only replace this file if the deployed site's artwork genuinely changed:

```sh
curl -fsSL https://music-prod.com/favicon.png -o assets/music-prod-favicon.png
shasum -a 256 assets/music-prod-favicon.png      # update the pin in the workflow
```

The workflow's pin **and** `assets/README.md` must change together, deliberately,
in a reviewed commit — never to make a failing run pass.
