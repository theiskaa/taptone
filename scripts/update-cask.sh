#!/bin/sh
# Point the taptone cask in the Homebrew tap at a published release.
#
#   scripts/update-cask.sh 0.2.0
#   scripts/update-cask.sh --dry-run 0.2.0
#
# Reads the checksum of Taptone-<version>-macos.zip from the release's
# SHA256SUMS on GitHub, sets the cask's version and sha256, and pushes the
# change to the tap. The first release adds Casks/taptone.rb from
# packaging/taptone.rb; later ones change only its version and sha256, so
# carry other template edits to the tap by hand. scripts/release.sh runs this
# after publishing; run it by hand to retry when that step failed. Nothing
# changes when the cask already names the release.
#
# --dry-run takes the checksum from dist/SHA256SUMS and writes the cask to
# dist/taptone.rb instead, touching neither GitHub nor the tap.
#
# Environment:
#   TAP   the tap to update (default: theiskaa/homebrew-tap)
set -eu

tap=${TAP:-theiskaa/homebrew-tap}
repo="theiskaa/taptone"

fail() {
	printf 'update-cask: %s\n' "$*" >&2
	exit 1
}

dry_run=0
case ${1:-} in --dry-run)
	dry_run=1
	shift
	;;
esac
version=${1:-}
[ $# -eq 1 ] || fail "usage: scripts/update-cask.sh [--dry-run] X.Y.Z"
expr "$version" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null ||
	fail "the version must be plain numbers such as 0.2.0, not $version"
name="Taptone-$version-macos.zip"
cd "$(dirname "$0")/.."
template="$PWD/packaging/taptone.rb"

work=$(mktemp -d "${TMPDIR:-/tmp}/taptone-cask.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Sets the cask's version and sha256, and checks that both took.
render() {
	sed -i '' -e "s/^  version \".*\"$/  version \"$version\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$sum\"/" "$1"
	if ! grep -q "^  version \"$version\"$" "$1" || ! grep -q "^  sha256 \"$sum\"$" "$1"; then
		fail "could not set the cask to $version"
	fi
	ruby -c "$1" >/dev/null || fail "the cask is not valid Ruby"
}

if [ "$dry_run" -eq 1 ]; then
	[ -f dist/SHA256SUMS ] || fail "there is no dist/SHA256SUMS; run scripts/release.sh --dry-run $version"
	cp dist/SHA256SUMS "$work/SHA256SUMS"
else
	gh release download "v$version" --repo "$repo" --pattern SHA256SUMS --dir "$work" ||
		fail "there is no published release v$version with a SHA256SUMS"
fi
sum=$(awk -v name="$name" '$2 == name { print $1 }' "$work/SHA256SUMS")
expr "$sum" : '[0-9a-f]\{64\}$' >/dev/null || fail "SHA256SUMS has no checksum for $name"

if [ "$dry_run" -eq 1 ]; then
	cp "$template" dist/taptone.rb
	render dist/taptone.rb
	echo "dist/taptone.rb: the cask $tap would get for $version"
	exit 0
fi

gh repo clone "$tap" "$work/tap" -- -q
cask="$work/tap/Casks/taptone.rb"
if [ -f "$cask" ]; then
	message="feat(cask): update taptone to $version"
else
	mkdir -p "$work/tap/Casks"
	cp "$template" "$cask"
	message="feat(cask): add taptone $version"
fi
render "$cask"
git -C "$work/tap" add Casks/taptone.rb
if git -C "$work/tap" diff --cached --quiet; then
	echo "The cask already names $version"
	exit 0
fi
git -C "$work/tap" commit -q -m "$message"
git -C "$work/tap" push -q origin HEAD
echo "brew install --cask $(printf '%s\n' "$tap" | sed 's|/homebrew-|/|')/taptone now installs $version"
