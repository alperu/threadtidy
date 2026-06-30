#!/usr/bin/env bash
# Build ThreadTidy.app from SwiftPM.
#
#   1. Bumps build number (unless --no-bump or --print).
#   2. Builds ThreadTidy executable (Release) via SwiftPM.
#   3. Generates AppIcon.icns from script/make-icon.swift if missing or
#      explicitly requested via --regen-icon.
#   4. Assembles a foundation .app bundle:
#        Contents/Info.plist
#        Contents/MacOS/ThreadTidy      (executable)
#        Contents/Frameworks/libpdfium.dylib
#        Contents/Resources/AppIcon.icns
#   5. Patches the binary's @rpath so the bundled dylib loads.
#
# Layout:
#   build/
#     ThreadTidy.app   → symlink to the latest build
#     ThreadTidy.zip   → symlink to the latest dist/notarized zip
#     builds/
#       v0.1.0-5/ThreadTidy.app
#       v0.1.0-6/ThreadTidy.app
#       v0.1.0-7-notarized/ThreadTidy.app
#       v0.1.0-7-notarized/ThreadTidy.zip
#       …
#
# Every invocation lands in its own versioned folder so old builds
# stay around for runtime comparison. Drag any of them to the desktop
# and run them side-by-side.
#
# Usage:
#   ./script/build-app.sh                  # build with bumped build number
#   ./script/build-app.sh --no-bump        # use existing number
#   ./script/build-app.sh --regen-icon     # rebuild AppIcon.icns
#   ./script/build-app.sh --print          # print current build number
#   ./script/build-app.sh --dist           # also produce ThreadTidy.zip
#                                          # (strips quarantine + uses ditto)
#   ./script/build-app.sh --notarize       # sign with Developer ID, notarize,
#                                          # staple, and produce signed zip
#                                          # (implies --dist; requires SIGN_IDENTITY
#                                          # and NOTARY_PROFILE env vars or the
#                                          # defaults below)

set -euo pipefail

# Signing config. SIGN_IDENTITY has no default — it must be supplied via
# env var (or CI secret) when signing, so no developer identity is baked
# into the repo. NOTARY_PROFILE defaults to the conventional name created
# by `xcrun notarytool store-credentials` (see --notarize block).
: "${SIGN_IDENTITY:=}"
: "${NOTARY_PROFILE:=ThreadTidy-notary}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT/src/ThreadTidy"
RESOURCES_DIR="$PKG_DIR/Resources"
INFO_PLIST_SRC="$RESOURCES_DIR/Info.plist"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
PDFIUM_DYLIB="$ROOT/src/libs/pdfium-mac/lib/libpdfium.dylib"
VERSION_DIR="$ROOT/build/version"
VERSION_FILE="$VERSION_DIR/BUILD_NUMBER"
BUILDS_DIR="$ROOT/build/builds"
LATEST_LINK="$ROOT/build/ThreadTidy.app"
LATEST_ZIP_LINK="$ROOT/build/ThreadTidy.zip"

mkdir -p "$VERSION_DIR" "$ROOT/build" "$BUILDS_DIR"
[[ -f "$VERSION_FILE" ]] || echo "1" > "$VERSION_FILE"
current="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$current" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER not integer: '$current'" >&2; exit 1; }

REGEN_ICON=0
DIST=0
NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --print)        echo "$current"; exit 0 ;;
        --no-bump)      NO_BUMP=1 ;;
        --regen-icon)   REGEN_ICON=1 ;;
        --dist)         DIST=1 ;;
        --notarize)     NOTARIZE=1; DIST=1 ;;
    esac
done
if [[ "${NO_BUMP:-0}" == "1" ]]; then
    new="$current"
else
    new="$((current + 1))"
    echo "$new" > "$VERSION_FILE"
fi
echo "Build number: $current → $new"

# 1) Stamp version into Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $new" "$INFO_PLIST_SRC" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $new" "$INFO_PLIST_SRC"

# Each build lands in its own versioned directory so prior builds stay
# around for runtime comparison. Tag = vSHORT-BUILD (+notarized when
# applicable) to make the folder name self-describing at a glance.
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_SRC" 2>/dev/null || echo "0.0.0")"
TAG_SUFFIX=""
[[ "$NOTARIZE" == "1" ]] && TAG_SUFFIX="-notarized"
VERSION_TAG="v${SHORT_VERSION}-${new}${TAG_SUFFIX}"
BUILD_DIR="$BUILDS_DIR/$VERSION_TAG"
APP_OUT="$BUILD_DIR/ThreadTidy.app"
mkdir -p "$BUILD_DIR"

# 2) Generate icon if missing or requested.
if [[ ! -f "$ICON_ICNS" ]] || [[ "$REGEN_ICON" == "1" ]]; then
    echo "==> Generating AppIcon.icns"
    swift "$ROOT/script/make-icon.swift" "$ICON_ICNS"
fi

# 3) Build the binary.
echo "==> Building ThreadTidy (Release)"
( cd "$PKG_DIR" && swift build -c release --product ThreadTidy )
BIN_SRC="$PKG_DIR/.build/release/ThreadTidy"
[[ -x "$BIN_SRC" ]] || { echo "error: built binary missing at $BIN_SRC" >&2; exit 1; }

# 3b) Compile mlx.metallib from mlx-swift's vendored Metal kernels.
# SwiftPM doesn't build these — without the metallib next to the
# binary, MLX inference crashes the moment its Metal device boots.
echo "==> Building mlx.metallib"
"$ROOT/script/build-metallib.sh"
METALLIB_SRC="$ROOT/build/metallib/mlx.metallib"
[[ -f "$METALLIB_SRC" ]] || { echo "error: mlx.metallib missing at $METALLIB_SRC" >&2; exit 1; }

# 4) Assemble the .app bundle.
echo "==> Assembling $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS"
mkdir -p "$APP_OUT/Contents/Resources"
mkdir -p "$APP_OUT/Contents/Frameworks"

cp "$INFO_PLIST_SRC" "$APP_OUT/Contents/Info.plist"
cp "$BIN_SRC"        "$APP_OUT/Contents/MacOS/ThreadTidy"
chmod +x "$APP_OUT/Contents/MacOS/ThreadTidy"
cp "$ICON_ICNS"      "$APP_OUT/Contents/Resources/AppIcon.icns"

# Drop mlx.metallib next to the binary. MLX's device.cpp searches
# `<binary_dir>/mlx.metallib` first, so this is the simplest landing
# spot and avoids any Bundle-resource shenanigans.
cp "$METALLIB_SRC" "$APP_OUT/Contents/MacOS/mlx.metallib"

if [[ -f "$PDFIUM_DYLIB" ]]; then
    cp "$PDFIUM_DYLIB" "$APP_OUT/Contents/Frameworks/libpdfium.dylib"
    # Ensure the bundled dylib's install_name is rpath-friendly so the
    # @executable_path/../Frameworks lookup succeeds.
    install_name_tool -id "@rpath/libpdfium.dylib" \
        "$APP_OUT/Contents/Frameworks/libpdfium.dylib" 2>/dev/null || true
    # Add @executable_path/../Frameworks to the binary's runpath search
    # list. PDFiumExtractor.swift dlopens "libpdfium.dylib" by name as
    # one of its candidates, which DYLD will resolve via this rpath.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_OUT/Contents/MacOS/ThreadTidy" 2>/dev/null || true
else
    echo "warning: PDFium dylib not found at $PDFIUM_DYLIB" >&2
fi

# 4b) Copy SwiftPM resource bundles next to the binary. SwiftPM's
# `Bundle.module` lookup expects each resource bundle to sit beside the
# main executable (i.e. inside Contents/MacOS), not under Resources.
# swift-transformers ships tokenizer config files this way; MLX could
# in future add more (e.g. mlx-swift_Cmlx.bundle with a metallib).
# Glob over everything present in the SwiftPM build dir.
SPM_BUILD_DIR="$PKG_DIR/.build/release"
shopt -s nullglob
for bundle in "$SPM_BUILD_DIR"/*.bundle; do
    name="$(basename "$bundle")"
    base="${name%.bundle}"
    dest="$APP_OUT/Contents/MacOS/$name"
    echo "==> Copying SwiftPM bundle: $name"
    rm -rf "$dest"
    cp -R "$bundle" "$dest"
    # SwiftPM emits resource-only bundles as flat directories with no
    # Info.plist. codesign refuses such "bundles" ("bundle format
    # unrecognized"), so we either need to add an Info.plist or
    # restructure. Add a minimal Info.plist so codesign treats it as a
    # plain resource bundle. Bundle.module's loader is content with a
    # flat layout — adding Info.plist alongside the resources is
    # harmless.
    if [[ ! -f "$dest/Info.plist" && ! -f "$dest/Contents/Info.plist" ]]; then
        cat > "$dest/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>net.basservices.ThreadTidy.$base</string>
    <key>CFBundleName</key>
    <string>$base</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
    fi
done
shopt -u nullglob

# 5) Sign. Two modes:
#    a) --notarize: Developer ID Application + hardened runtime + secure
#       timestamp. Signs inner dylibs FIRST (Apple's required order),
#       then the outer .app. Hardened runtime is mandatory for
#       notarization; library validation passes because the bundled
#       PDFium dylib gets re-signed with the same Developer ID.
#    b) default: ad-hoc sign so the local Mac can launch it (no
#       Gatekeeper acceptance off-machine).
if [[ "$NOTARIZE" == "1" ]]; then
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "error: SIGN_IDENTITY env var is required for --notarize (e.g. export SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\")" >&2
        exit 1
    fi
    echo "==> Signing with: $SIGN_IDENTITY"
    # Sign every inner dylib, framework, and bundle FIRST (Apple's
    # required bottom-up order), then the outer .app last. The find
    # loop catches future MLX or transformers resource bundles
    # without further script edits.
    while IFS= read -r -d '' artifact; do
        echo "    signing: ${artifact#$APP_OUT/}"
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$artifact"
    done < <(find "$APP_OUT/Contents" \
        \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' \
           -o -name '*.metallib' \) \
        -print0)
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_OUT"
    # Sanity-check the signature; bail loudly if anything's off so we
    # don't waste a notary submission.
    codesign --verify --strict --verbose=2 "$APP_OUT"
else
    codesign --force --deep --sign - "$APP_OUT" >/dev/null 2>&1 || true
fi

echo "Built: $APP_OUT"
echo "Run with: open $APP_OUT"

# 6) Optional distributable zip. macOS attaches a com.apple.quarantine
# attribute to anything downloaded from a browser/email/AirDrop/etc.,
# so we strip extended attrs and package with `ditto -c -k --keepParent`
# (Apple's recommended bundler — preserves resource forks/symlinks).
#
# When --notarize was passed, we ALSO submit the zip to Apple's notary
# service, wait for the ticket, staple it onto the .app, then re-zip.
# Stapled apps launch cleanly on any Mac with no quarantine workaround.
if [[ "$DIST" == "1" ]]; then
    ZIP_OUT="$BUILD_DIR/ThreadTidy.zip"
    rm -f "$ZIP_OUT"

    if [[ "$NOTARIZE" == "1" ]]; then
        # Submission zip — this one's discardable, just for upload.
        SUB_ZIP="$BUILD_DIR/ThreadTidy-submit.zip"
        rm -f "$SUB_ZIP"
        ( cd "$(dirname "$APP_OUT")" && /usr/bin/ditto -c -k --keepParent \
            "$(basename "$APP_OUT")" "$SUB_ZIP" )
        echo "==> Submitting to Apple notary service (1–5 min, --wait blocks)"
        xcrun notarytool submit "$SUB_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
        rm -f "$SUB_ZIP"
        echo "==> Stapling ticket onto .app"
        xcrun stapler staple "$APP_OUT"
        # Verify Gatekeeper accepts the stapled app offline.
        spctl -a -t exec -vv "$APP_OUT" || true
    else
        # Unsigned/ad-hoc path: strip quarantine so we ship clean,
        # though recipients will still need to right-click → Open.
        xattr -cr "$APP_OUT"
    fi

    echo "==> Packaging → $ZIP_OUT"
    ( cd "$(dirname "$APP_OUT")" && /usr/bin/ditto -c -k --keepParent \
        "$(basename "$APP_OUT")" "$ZIP_OUT" )
    size_kb=$(($(stat -f%z "$ZIP_OUT") / 1024))
    echo "Packaged: $ZIP_OUT ($size_kb KB)"

    if [[ "$NOTARIZE" == "1" ]]; then
        cat <<'EOF'

Notarized + stapled. Recipients can double-click the app from the
unzipped folder with no warnings, even on a fresh Mac with no
developer tools.
EOF
    else
        cat <<'EOF'

Send the zip to a recipient. On first launch they will likely see
"can't be opened because Apple cannot check it for malicious software"
because the app isn't notarized. To bypass:

  Option 1 (easiest):
    Right-click the .app → Open → confirm "Open" in the dialog.

  Option 2 (Terminal one-liner):
    xattr -dr com.apple.quarantine /path/to/ThreadTidy.app

For a permanent fix, run with --notarize once your Apple Developer
ID and notary credentials are set up.
EOF
    fi
fi

# Repoint "latest" symlinks so the conventional `build/ThreadTidy.app`
# path always opens whatever was just built. Each prior build still
# lives at its versioned path under `build/builds/`, so you can drag
# any of them onto the desktop and run them side-by-side.
#
# `ln -sfn` cleanly replaces an existing symlink, but if the path is
# a real directory (left over from earlier non-versioned builds) we
# need to remove it first — `ln` won't overwrite a directory.
if [[ -e "$LATEST_LINK" && ! -L "$LATEST_LINK" ]]; then rm -rf "$LATEST_LINK"; fi
if [[ -e "$LATEST_ZIP_LINK" && ! -L "$LATEST_ZIP_LINK" ]]; then rm -f "$LATEST_ZIP_LINK"; fi
ln -sfn "builds/$VERSION_TAG/ThreadTidy.app" "$LATEST_LINK"
if [[ -f "$BUILD_DIR/ThreadTidy.zip" ]]; then
    ln -sfn "builds/$VERSION_TAG/ThreadTidy.zip" "$LATEST_ZIP_LINK"
fi

# Show the user what's available without paginating.
echo
echo "Latest → $LATEST_LINK → builds/$VERSION_TAG/"
echo
echo "Recent builds in $BUILDS_DIR:"
ls -1t "$BUILDS_DIR" 2>/dev/null | head -n 8 | while read -r tag; do
    [[ -z "$tag" ]] && continue
    marker="  "
    [[ "$tag" == "$VERSION_TAG" ]] && marker="* "
    echo "${marker}${tag}"
done
