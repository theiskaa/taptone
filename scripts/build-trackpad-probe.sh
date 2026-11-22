#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
package=experiments/trackpad-probe
product=TaptoneTrackpadProbe
/usr/bin/plutil -lint "$package/Info.plist"
swift build --package-path "$package" -c release --product "$product"
binary_dir=$(swift build --package-path "$package" -c release --show-bin-path)
output="$PWD/.build/trackpad-probe"
mkdir -p -- "$output"
install -m 755 -- "$binary_dir/$product" "$output/$product"
/usr/bin/codesign --force --sign "${TAPTONE_SIGN_IDENTITY:--}" "$output/$product"
/usr/bin/codesign --verify --strict "$output/$product"
printf '\n%s\n' "$output/$product"
