#!/usr/bin/env bash
#
# Hermetic tests for Scripts/verify-app-resources.sh — the packaged-resource
# gate that stands between an unlaunchable app and a release.
#
# WHAT IS REAL HERE AND WHAT IS SYNTHETIC
#   This repository holds only the publisher tooling, so it cannot stage the
#   application's own artwork, hero image or brand fonts. The gate's contract for
#   those files is "present and non-empty in the location the app loads them
#   from", so the fixtures below create placeholder files of the right names and
#   the assertions are exactly the ones the gate makes. The ICON checks are not
#   approximated in any way: they run against assets/music-prod-favicon.png, the
#   genuine public artwork downloaded from https://music-prod.com/favicon.png and
#   pinned by digest (see assets/README.md).
#
# Every case builds a PRIVATE synthetic .app in a temp directory, mutates that
# copy, and runs the gate against it. Nothing is written into the repository, no
# release artifact is touched, no network is used, and the published artifacts
# are never modified.
#
# The cases encode the two defects that actually reached users, so neither can
# reach one again unnoticed:
#
#   * the 2.0.11 LAUNCH CRASH  — the app decodes its wordmark logo, hero artwork
#     and brand fonts from the SwiftPM resource bundle during launch; a bundle
#     that is absent, or incomplete in the location the app loads it from, kills
#     the process with EXC_BREAKPOINT/SIGTRAP before a window exists;
#   * the PURPLE PLACEHOLDER ICON — AppIcon.icns was a flat rgb(74,68,190) canvas
#     with three low-resolution representations and no artwork, which presence,
#     digest and signature checks are all blind to.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/Scripts/verify-app-resources.sh"
FIXTURE="$HERE/fixtures/make-icon-fixture.py"
BRAND="$ROOT/assets/music-prod-favicon.png"
BUNDLE_NAME="MusicProdStudio_MusicProdStudio.bundle"

FONTS=(
  Inter-Regular.ttf Inter-Medium.ttf Inter-SemiBold.ttf
  SchibstedGrotesk-Regular.ttf SchibstedGrotesk-Medium.ttf
  SchibstedGrotesk-SemiBold.ttf SchibstedGrotesk-Bold.ttf
)

for required in "$GATE" "$FIXTURE" "$BRAND"; do
  if [ ! -f "$required" ]; then
    echo "FATAL: required file not found: $required" >&2
    exit 1
  fi
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-app-resources.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------ synthetic bundle resources
# The gate only requires these to exist and be non-empty where the app loads
# them from; their content is never inspected. Sizes are representative so a
# truncated copy is as visible here as it would be in the real bundle.
RESOURCES="$TMP/resources"
mkdir -p "$RESOURCES/Fonts"
python3 - "$RESOURCES" <<'PY'
import os, sys
root = sys.argv[1]
sizes = {
    "MusicProdLogo.png": 4096,
    "VyreProductHero.png": 8192,
}
for name, size in sizes.items():
    with open(os.path.join(root, name), "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + bytes(size))
for name in ("Inter-Regular.ttf", "Inter-Medium.ttf", "Inter-SemiBold.ttf",
             "SchibstedGrotesk-Regular.ttf", "SchibstedGrotesk-Medium.ttf",
             "SchibstedGrotesk-SemiBold.ttf", "SchibstedGrotesk-Bold.ttf"):
    with open(os.path.join(root, "Fonts", name), "wb") as handle:
        handle.write(b"\x00\x01\x00\x00" + bytes(2048))
PY

for required in "$RESOURCES/MusicProdLogo.png" "$RESOURCES/VyreProductHero.png" \
                "$RESOURCES/Fonts/Inter-Regular.ttf"; do
  [ -f "$required" ] || { echo "FATAL: fixture resource missing: $required" >&2; exit 1; }
done

PASS=0
FAIL=0
OUT=""
CODE=0

# run <app> [extra args...] — capture output and the gate's own exit status
#
# MPS_ICON_REFERENCE is exported for every invocation: this repository has no
# application tree, so the reference is always supplied from assets/ explicitly
# (which is exactly how the publication workflow drives the gate). The case at
# the end proves the gate refuses — rather than silently skipping the icon
# checks — when no reference is supplied at all.
run() {
  set +e
  OUT="$(MPS_ICON_REFERENCE="$BRAND" "$GATE" "$@" 2>&1)"
  CODE=$?
  set -e
}

check() { # check <description> <expected code> [substring that must appear]
  local description="$1" expected="$2" needle="${3:-}"
  if [ "$CODE" != "$expected" ]; then
    echo "  FAIL  $description (exit $CODE, expected $expected)"
    echo "$OUT" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$OUT" | grep -qF -- "$needle"; then
    echo "  FAIL  $description (missing: $needle)"
    echo "$OUT" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
    return
  fi
  echo "  ok    $description"
  PASS=$((PASS + 1))
}

# --------------------------------------------------------------- fixtures
icon() { # icon <mode> <out.icns>
  python3 "$FIXTURE" --mode "$1" --reference "$BRAND" --out "$2" >/dev/null
}

# stage_resources <destination> [layout]
#   swiftpm (default): the bundle carries an Info.plist and its files sit in
#                      Contents/Resources — what `.process("Resources")` yields
#   legacy:            a bare directory holding the files directly — the layout
#                      the published 2.0.11 bundle had
stage_resources() {
  local destination="$1" layout="${2:-swiftpm}"
  mkdir -p "$destination"
  if [ "$layout" = "legacy" ]; then
    cp "$RESOURCES/MusicProdLogo.png" "$RESOURCES/VyreProductHero.png" "$destination/"
    cp "$RESOURCES/Fonts/"*.ttf "$destination/"
    return
  fi
  mkdir -p "$destination/Contents/Resources"
  cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.musicprod.studio.MusicProdStudio.resources</string>
</dict>
</plist>
PLIST
  cp "$RESOURCES/MusicProdLogo.png" "$RESOURCES/VyreProductHero.png" "$destination/Contents/Resources/"
  cp "$RESOURCES/Fonts/"*.ttf "$destination/Contents/Resources/"
}

make_app() { # make_app <dir> <icns-mode> [layout]
  local dir="$1" mode="$2" layout="${3:-swiftpm}"
  local app="$dir/Music-Prod Studio.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.music-prod.studio</string>
    <key>CFBundleExecutable</key><string>MusicProdStudio</string>
    <key>CFBundleShortVersionString</key><string>2.0.13</string>
    <key>CFBundleVersion</key><string>15</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST
  printf 'APPL????' > "$app/Contents/PkgInfo"
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/MusicProdStudio"
  chmod +x "$app/Contents/MacOS/MusicProdStudio"
  stage_resources "$app/Contents/Resources/$BUNDLE_NAME" "$layout"
  icon "$mode" "$app/Contents/Resources/AppIcon.icns"
  echo "$app"
}

# Path of a staged resource inside a fixture app (swiftpm layout).
staged() { # staged <app> <file>
  echo "$1/Contents/Resources/$BUNDLE_NAME/Contents/Resources/$2"
}

echo "verify-app-resources gate — hermetic suite"
echo ""

# ------------------------------------------------- 1. the gate accepts a
# complete, correctly laid out bundle whose icon is the real artwork.
app="$(make_app "$TMP/complete" genuine)"
run "$app"
check "complete packaged app is accepted" 0 "RESULT: PASS"

# The gate is read-only: the bundle must be byte-identical afterwards.
before="$(find "$app" -type f -exec shasum -a 256 {} \; | sort)"
run "$app"
after="$(find "$app" -type f -exec shasum -a 256 {} \; | sort)"
if [ "$before" = "$after" ]; then
  echo "  ok    gate leaves the bundle unmodified"
  PASS=$((PASS + 1))
else
  echo "  FAIL  gate modified the bundle"
  FAIL=$((FAIL + 1))
fi

# The legacy flat layout the published 2.0.11 bundle used is still resolvable by
# the app, so a complete bundle in that layout must pass too.
app="$(make_app "$TMP/legacy-layout" genuine legacy)"
run "$app"
check "legacy flat bundle layout still passes when complete" 0 "RESULT: PASS"

# ------------------------------------------- 2. the 2.0.11 crash condition:
# the resource bundle the app loads at launch is absent from the packaged app.
app="$(make_app "$TMP/no-bundle" genuine)"
rm -rf "$app/Contents/Resources/$BUNDLE_NAME"
run "$app"
check "missing resource bundle is refused" 1 "resource bundle"
check "missing resource bundle names the consequence" 1 "at launch"

# ------------------------------------------------- 3. an INCOMPLETE bundle.
# The published 2.0.11 bundle contained only MusicProdLogo.png: the hero artwork
# and all seven brand fonts were absent, so the app shipped without them.
app="$(make_app "$TMP/incomplete" genuine)"
rm "$(staged "$app" VyreProductHero.png)"
rm "$(staged "$app" SchibstedGrotesk-Bold.ttf)"
run "$app"
check "incomplete resource bundle is refused" 1 "VyreProductHero.png"
check "every missing font is named" 1 "SchibstedGrotesk-Bold.ttf"

# An EMPTY file is not a resource.
app="$(make_app "$TMP/empty-resource" genuine)"
: > "$(staged "$app" MusicProdLogo.png)"
run "$app"
check "an empty required resource is refused" 1 "MusicProdLogo.png"

# ----------------------------------------------- 4. the purple placeholder.
app="$(make_app "$TMP/purple" flat-purple)"
run "$app"
check "flat purple placeholder icon is refused" 1 "purple-dominant"
check "flat placeholder is not mistaken for artwork" 1 "flat fill"
check "placeholder icon never matches the favicon" 1 "does not match the music-prod.com favicon"

# ------------------------------------------------------- 5. a padded icon.
app="$(make_app "$TMP/padded" padded)"
run "$app"
check "icon with an added white margin is refused" 1 "padding/white margin"

# ------------------------------------------ 6. an icon missing the Dock rep.
app="$(make_app "$TMP/missing-rep" missing-1024)"
run "$app"
check "icon missing its 1024 representation is refused" 1 "missing 1024x1024 representation"

# ------------------------------------------- 7. a plausible but foreign mark.
app="$(make_app "$TMP/foreign" foreign)"
run "$app"
check "a different mark is refused even at the right size" 1 "is not the genuine favicon artwork"

# --------------------------------------- 8. bundle structure / Info.plist.
app="$(make_app "$TMP/no-icon" genuine)"
rm "$app/Contents/Resources/AppIcon.icns"
run "$app"
check "missing AppIcon.icns is refused" 1 "AppIcon.icns is missing"

app="$(make_app "$TMP/no-exec" genuine)"
chmod -x "$app/Contents/MacOS/MusicProdStudio"
run "$app"
check "a non-executable main binary is refused" 1 "not executable"

app="$(make_app "$TMP/no-identity" genuine)"
plutil -remove CFBundleIdentifier "$app/Contents/Info.plist" >/dev/null 2>&1
run "$app"
check "a missing CFBundleIdentifier is refused" 1 "CFBundleIdentifier"

# ------------------------------------- 9. the archive that actually ships.
app="$(make_app "$TMP/zipped" genuine)"
(cd "$(dirname "$app")" && zip -qry "$TMP/artifact.zip" "$(basename "$app")")
run "$app" --zip "$TMP/artifact.zip"
check "a complete archive passes the shipped-bytes check" 0 "--- archive: artifact.zip ---"
check "a complete archive reports the shipped icon" 0 "in archive"

app="$(make_app "$TMP/zipped-broken" genuine)"
rm "$(staged "$app" Inter-Medium.ttf)"
(cd "$(dirname "$app")" && zip -qry "$TMP/artifact-broken.zip" "$(basename "$app")")
run "$app" --zip "$TMP/artifact-broken.zip"
check "an archive missing a bundled font is refused" 1 "Inter-Medium.ttf is missing from the shipped ZIP"

# ------------------------------------------------------------- 10. usage.
run /nonexistent/app
check "a missing bundle is a usage error" 2 "app bundle not found"

# ------------------------------------------- 11. the reference, and its absence.
# With no MPS_ICON_REFERENCE the gate must REFUSE (exit 2) instead of quietly
# accepting an icon it never compared, which is the whole reason the pinned asset
# exists. Its default path points into the application tree, which this repository
# deliberately does not have.
app="$(make_app "$TMP/no-reference" genuine)"
set +e
OUT="$(env -u MPS_ICON_REFERENCE "$GATE" "$app" 2>&1)"
CODE=$?
set -e
check "with no icon reference the gate refuses" 2 "icon reference artwork not found"

echo ""
echo "verify-app-resources gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
