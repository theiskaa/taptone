#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
configuration=${1:-debug}
case "$configuration" in
    debug|release) ;;
    *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;;
esac

swift build -c "$configuration" --product Taptone
binary_dir=$(swift build -c "$configuration" --show-bin-path)
app="$PWD/.build/Taptone.app"
/usr/bin/plutil -lint App/Info.plist
mkdir -p -- "$app/Contents/MacOS"
install -m 755 -- "$binary_dir/Taptone" "$app/Contents/MacOS/Taptone"
install -m 644 -- App/Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign "${TAPTONE_SIGN_IDENTITY:--}" "$app"
/usr/bin/codesign --verify --strict "$app"
printf '\n%s\n' "$app"
