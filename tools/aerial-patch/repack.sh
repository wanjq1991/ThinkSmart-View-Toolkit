#!/usr/bin/env bash
# Re-align and re-sign an APK after its manifest has been patched.
#
# Changing any byte inside the archive invalidates both the v1 (JAR) and v2/v3
# (APK Signing Block) signatures, so the package must be signed again before
# Android will install it. Signature change also means the package can no
# longer be upgraded in place -- uninstall first, which resets its data.
#
# Usage:
#   ./repack.sh in.apk out.apk
#
# Environment:
#   BUILD_TOOLS   path to an Android build-tools directory (auto-detected)
#   KEYSTORE      signing keystore (default: ~/.android/debug.keystore)
#   KS_ALIAS      key alias         (default: androiddebugkey)
#   KS_PASS       store/key password(default: android)

set -euo pipefail

IN="${1:?usage: ./repack.sh in.apk out.apk}"
OUT="${2:?usage: ./repack.sh in.apk out.apk}"

KEYSTORE="${KEYSTORE:-$HOME/.android/debug.keystore}"
KS_ALIAS="${KS_ALIAS:-androiddebugkey}"
KS_PASS="${KS_PASS:-android}"

find_build_tools() {
    if [ -n "${BUILD_TOOLS:-}" ]; then echo "$BUILD_TOOLS"; return; fi
    local root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [ -n "$root" ] && [ -d "$root/build-tools" ]; then
        # highest version wins
        ls -1 "$root/build-tools" | sort -V | tail -1 | sed "s|^|$root/build-tools/|"
        return
    fi
    return 1
}

BT="$(find_build_tools)" || {
    echo "error: set BUILD_TOOLS or ANDROID_HOME" >&2
    exit 1
}
ZIPALIGN="$BT/zipalign"
APKSIGNER="$BT/apksigner"
[ -x "$ZIPALIGN" ] || ZIPALIGN="$ZIPALIGN.exe"
[ -x "$APKSIGNER" ] || APKSIGNER="$APKSIGNER.bat"
[ -x "$ZIPALIGN" ] || { echo "error: zipalign not found in $BT" >&2; exit 1; }

if [ ! -f "$KEYSTORE" ]; then
    echo "no keystore at $KEYSTORE, creating a debug one"
    mkdir -p "$(dirname "$KEYSTORE")"
    keytool -genkeypair -v \
        -keystore "$KEYSTORE" -storepass "$KS_PASS" -keypass "$KS_PASS" \
        -alias "$KS_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US"
fi

TMP="${TMPDIR:-/tmp}/apk-repack-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

# -p aligns uncompressed .so files to 4 KiB pages, required on 16 KiB-page
# kernels and harmless everywhere else.
"$ZIPALIGN" -p -f 4 "$IN" "$TMP/aligned.apk"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" --ks-key-alias "$KS_ALIAS" \
    --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
    --out "$OUT" "$TMP/aligned.apk"

"$APKSIGNER" verify --print-certs "$OUT" | head -5
echo
echo "signed -> $OUT"
echo "install with: adb install -r -d \"$OUT\""
echo "if it was installed before, uninstall first (signature changed):"
echo "  adb uninstall \$(aapt dump badging \"$OUT\" | sed -n \"s/package: name='\\([^']*\\)'.*/\\1/p\")"
