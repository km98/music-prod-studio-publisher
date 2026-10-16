#!/bin/bash
#
# verify-app-resources.sh — fail-closed proof that a packaged Music-Prod Studio
# .app carries every STARTUP-CRITICAL bundled resource, in the exact location the
# app loads it from, and that its app icon is the genuine website artwork.
#
# WHY THIS GATE EXISTS
#   Published 2.0.11 (build 12) crashed the instant it launched:
#     EXC_BREAKPOINT (SIGTRAP) on the main thread
#     static NSBundle.module -> MusicProdWordmark.logoImage.getter
#   The SwiftPM resource bundle it needed was not where the binary looked for it,
#   and the generated accessor reports a miss with fatalError. Neither the code
#   signature, the notarization ticket nor the ZIP digest can see that: the
#   artifact was valid in every way except that it could not run. The same
#   release also shipped a FLAT PURPLE PLACEHOLDER icon.
#
#   A resource bundle or icon that is missing, incomplete or wrong must fail the
#   BUILD. It must never fail the launch on a user's Mac.
#
# WHAT IS CHECKED (all fail-closed; the exit status is the verdict)
#   * bundle structure: Info.plist (identity/version/executable/icon keys),
#     Contents/MacOS/<CFBundleExecutable> executable, Contents/PkgInfo
#   * the SwiftPM resource bundle in Contents/Resources, the directory the app
#     resolves at runtime (Bundle.main.resourceURL)
#   * every required bundled asset, present and non-empty, resolved through
#     CFBundle semantics (a bundle with an Info.plist keeps its resources in
#     Contents/Resources; a bare directory is its own resource root):
#       MusicProdLogo.png          (sidebar wordmark — the 2.0.11 crash site)
#       VyreProductHero.png        (library hero artwork)
#       the 7 brand TTFs           (registered during launch)
#   * Contents/Resources/AppIcon.icns with every representation macOS reads
#   * ICON ARTWORK: every representation is compared pixel-by-pixel with the
#     pinned music-prod.com favicon (rejects a flat/placeholder/padded icon and
#     any mark that is not the deployed website artwork)
#
# Usage:
#   verify-app-resources.sh "<Music-Prod Studio.app>" [--zip <artifact.zip>]
#
# --zip additionally proves the SHIPPED archive contains the same resource set,
# so the gate covers the bytes that actually go out, not just the staging copy.
#
# Read-only. Safe to run against a published artifact. No network, no writes.
# Exit codes: 0 = every check passed, 1 = refused, 2 = usage/IO error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- manifest
#
# The single source of truth for what a launchable app must contain. Mirrors
# Sources/UI/MPTheme.swift (MusicProdBundledResources / MusicProdFontResources)
# and Sources/Resources/ (what SwiftPM stages into the resource bundle).
RESOURCE_BUNDLE_NAME="MusicProdStudio_MusicProdStudio.bundle"
REQUIRED_BUNDLE_FILES=(
    "MusicProdLogo.png"
    "VyreProductHero.png"
    "Inter-Regular.ttf"
    "Inter-Medium.ttf"
    "Inter-SemiBold.ttf"
    "SchibstedGrotesk-Regular.ttf"
    "SchibstedGrotesk-Medium.ttf"
    "SchibstedGrotesk-SemiBold.ttf"
    "SchibstedGrotesk-Bold.ttf"
)
# The icon must be the deployed website artwork; pinned by SHA-256 in build-app.sh.
ICON_REFERENCE="${MPS_ICON_REFERENCE:-$REPO_ROOT/Sources/Resources/Brand/music-prod-favicon.png}"

usage() {
    echo "usage: $(basename "$0") <app-bundle> [--zip <artifact.zip>]" >&2
    exit 2
}

APP=""
ZIP=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --zip) ZIP="${2:-}"; [ -n "$ZIP" ] || usage; shift 2 ;;
        -h|--help) usage ;;
        *) if [ -z "$APP" ]; then APP="$1"; else usage; fi; shift ;;
    esac
done
[ -n "$APP" ] || usage

if [ ! -d "$APP" ]; then
    echo "error: app bundle not found: $APP" >&2
    exit 2
fi
if [ -n "$ZIP" ] && [ ! -f "$ZIP" ]; then
    echo "error: artifact not found: $ZIP" >&2
    exit 2
fi
if [ ! -f "$ICON_REFERENCE" ]; then
    echo "error: icon reference artwork not found: $ICON_REFERENCE" >&2
    exit 2
fi

FAILURES=0
refuse() {
    printf '  %-26s %s\n' "REFUSED — $1" "$2"
    FAILURES=$((FAILURES + 1))
}
ok() {
    printf '  %-26s %s\n' "$1" "OK — $2"
}

echo "============================================================"
echo " MUSIC-PROD STUDIO — PACKAGED RESOURCE GATE (read-only)"
echo "============================================================"
echo " app       : $APP"
[ -n "$ZIP" ] && echo " artifact  : $ZIP"
echo " icon ref  : $ICON_REFERENCE"
echo ""

# ------------------------------------------------- 1. bundle structure
PLIST="$APP/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    ok "Info.plist" "present"
else
    refuse "Info.plist" "$PLIST is missing"
fi

BUNDLE_ID=""; EXEC_NAME=""; SHORT_VERSION=""; BUILD_VERSION=""; ICON_FILE=""
if [ -f "$PLIST" ]; then
    BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST" 2>/dev/null || true)"
    EXEC_NAME="$(plutil -extract CFBundleExecutable raw -o - "$PLIST" 2>/dev/null || true)"
    SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null || true)"
    BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "$PLIST" 2>/dev/null || true)"
    ICON_FILE="$(plutil -extract CFBundleIconFile raw -o - "$PLIST" 2>/dev/null || true)"
    for pair in "CFBundleIdentifier:$BUNDLE_ID" "CFBundleExecutable:$EXEC_NAME" \
                "CFBundleShortVersionString:$SHORT_VERSION" "CFBundleVersion:$BUILD_VERSION" \
                "CFBundleIconFile:$ICON_FILE"; do
        key="${pair%%:*}"; value="${pair#*:}"
        if [ -n "$value" ]; then
            ok "$key" "$value"
        else
            refuse "$key" "missing from Info.plist"
        fi
    done
fi

EXECUTABLE_PATH="$APP/Contents/MacOS/${EXEC_NAME:-MusicProdStudio}"
if [ -x "$EXECUTABLE_PATH" ]; then
    ok "executable" "Contents/MacOS/$(basename "$EXECUTABLE_PATH") (executable)"
else
    refuse "executable" "not found or not executable: $EXECUTABLE_PATH"
fi

if [ -f "$APP/Contents/PkgInfo" ]; then
    ok "PkgInfo" "$(cat "$APP/Contents/PkgInfo")"
else
    refuse "PkgInfo" "Contents/PkgInfo is missing"
fi

# ------------------------------------------- 2. the resource bundle itself
BUNDLE_DIR="$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME"
BUNDLE_EXISTS=0
if [ -d "$BUNDLE_DIR" ]; then
    BUNDLE_EXISTS=1
    ok "resource bundle" "Contents/Resources/$RESOURCE_BUNDLE_NAME"
else
    refuse "resource bundle" \
        "Contents/Resources/$RESOURCE_BUNDLE_NAME is missing — the app decodes its logo, hero artwork and fonts from it at launch"
fi

# CFBundle resource roots, in the order the app's own lookup resolves them.
# A real SwiftPM resource bundle carries an Info.plist and keeps its staged files
# in Contents/Resources (`.process("Resources")` flattens the source tree, so a
# `Fonts/` subdirectory may or may not survive); a bare directory is its own
# resource root, which is how the published 2.0.11 bundle was laid out.
resource_roots() {
    if [ -f "$BUNDLE_DIR/Contents/Info.plist" ]; then
        printf '%s\n' "$BUNDLE_DIR/Contents/Resources"
    fi
    printf '%s\n' "$BUNDLE_DIR"
}

# ------------------------------------------------- 3. required resources
for relative in "${REQUIRED_BUNDLE_FILES[@]}"; do
    found=""
    while IFS= read -r root; do
        for candidate in "$root/$relative" "$root/Fonts/$relative"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                found="$candidate"
                break
            fi
        done
        [ -n "$found" ] && break
    done < <(resource_roots)
    if [ -n "$found" ]; then
        ok "resource" "$relative ($(wc -c < "$found" | tr -d ' ') bytes)"
    else
        if [ "$BUNDLE_EXISTS" = "1" ]; then
            refuse "resource" "$relative is missing or empty in the packaged bundle"
        else
            refuse "resource" "$relative cannot be checked (no resource bundle)"
        fi
    fi
done

# ----------------------------------------------- 4. the app icon, in pixels
ICNS_PATH="$APP/Contents/Resources/${ICON_FILE:-AppIcon}.icns"
if [ ! -s "$ICNS_PATH" ]; then
    refuse "AppIcon.icns" "$ICNS_PATH is missing or empty"
else
    ok "AppIcon.icns" "$(wc -c < "$ICNS_PATH" | tr -d ' ') bytes"
    if ICON_OUTPUT="$(python3 "$SCRIPT_DIR/verify-app-icon-artwork.py" "$ICNS_PATH" "$ICON_REFERENCE" 2>&1)"; then
        echo "$ICON_OUTPUT" | sed 's/^/    /'
        ok "icon artwork" "matches the pinned music-prod.com favicon at every size"
    else
        echo "$ICON_OUTPUT" | sed 's/^/    /'
        refuse "icon artwork" "AppIcon.icns is not the genuine favicon artwork (see above)"
    fi
fi

# ------------------------------------- 5. the shipped archive, if provided
if [ -n "$ZIP" ]; then
    echo ""
    echo "  --- archive: $(basename "$ZIP") ---"
    ARCHIVE_LISTING="$(unzip -Z1 "$ZIP" 2>/dev/null || true)"
    if [ -z "$ARCHIVE_LISTING" ]; then
        refuse "archive" "could not read the ZIP listing"
    else
        for relative in "${REQUIRED_BUNDLE_FILES[@]}"; do
            matched=0
            for layout in "$relative" "Fonts/$relative"; do
                if printf '%s\n' "$ARCHIVE_LISTING" \
                    | grep -qE "($RESOURCE_BUNDLE_NAME/(Contents/Resources/)?$layout)\$"; then
                    matched=1
                    break
                fi
            done
            if [ "$matched" = "1" ]; then
                ok "in archive" "$relative"
            else
                refuse "in archive" "$relative is missing from the shipped ZIP"
            fi
        done
        if printf '%s\n' "$ARCHIVE_LISTING" | grep -qE "Contents/Resources/${ICON_FILE:-AppIcon}\.icns\$"; then
            ok "in archive" "${ICON_FILE:-AppIcon}.icns"
        else
            refuse "in archive" "${ICON_FILE:-AppIcon}.icns is missing from the shipped ZIP"
        fi
    fi
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "RESULT: REFUSED — $FAILURES packaged-resource check(s) failed"
    exit 1
fi
echo "RESULT: PASS — every startup-critical resource is present in the packaged app"
exit 0
