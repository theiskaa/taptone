#!/usr/bin/env bash
# Builds and signs .build/Taptone.app.
#
#     scripts/build-app.sh [debug|release] [options]
#
#     --identity NAME     sign with this identity (default: TAPTONE_SIGN_IDENTITY, else the first
#                         Apple Development certificate, else ad hoc)
#     --hardened          sign for distribution: hardened runtime, a secure timestamp, and
#                         App/Taptone.entitlements; needs a real identity (scripts/release.sh uses it)
#     --universal         build for arm64 and x86_64 in one binary
#     --info-plist FILE   bundle FILE instead of App/Info.plist (release dry runs use a bumped copy)
#
# Prints the app's path as its last line.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
usage() {
    printf 'Usage: %s [debug|release] [--identity NAME] [--hardened] [--universal] [--info-plist FILE]\n' "$0" >&2
    exit 2
}

configuration=debug
identity=${TAPTONE_SIGN_IDENTITY:-}
hardened=0
info_plist=App/Info.plist
arch_flags=()
while (( $# )); do
    case "$1" in
        debug|release) configuration=$1 ;;
        --identity) (( $# > 1 )) || usage; identity=$2; shift ;;
        --hardened) hardened=1 ;;
        --universal) arch_flags=(--arch arm64 --arch x86_64) ;;
        --info-plist) (( $# > 1 )) || usage; info_plist=$2; shift ;;
        *) usage ;;
    esac
    shift
done

if (( hardened )) && [[ -z "$identity" ]]; then
    printf 'build-app: --hardened needs --identity (or TAPTONE_SIGN_IDENTITY)\n' >&2
    exit 2
fi

build_flags=(-c "$configuration" ${arch_flags[@]+"${arch_flags[@]}"})
swift build "${build_flags[@]}" --product Taptone >&2
binary_dir=$(swift build "${build_flags[@]}" --show-bin-path)
app="$PWD/.build/Taptone.app"
/usr/bin/plutil -lint -s "$info_plist"
rm -rf -- "$app"
mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 -- "$binary_dir/Taptone" "$app/Contents/MacOS/Taptone"
install -m 644 -- "$info_plist" "$app/Contents/Info.plist"
install -m 644 -- App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

if (( hardened )); then
    # Distribution: notarization requires the hardened runtime and a secure timestamp.
    /usr/bin/plutil -lint -s App/Taptone.entitlements
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
        --entitlements App/Taptone.entitlements "$app"
else
    # Local builds sign with a stable identity when one exists. An ad hoc signature changes with every
    # build, and macOS ties the system audio permission to the signature, so each ad hoc rebuild
    # would lose that permission.
    if [[ -z "$identity" ]]; then
        identity=$(/usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/awk '/"Apple Development/ { print $2; exit }')
    fi
    if [[ -z "$identity" ]]; then
        printf 'note: no Apple Development certificate found, signing ad hoc.\n' >&2
        printf '      macOS will ask for system audio access again after each rebuild.\n' >&2
    fi
    /usr/bin/codesign --force --sign "${identity:--}" "$app"
fi
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
