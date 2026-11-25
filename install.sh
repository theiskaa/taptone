#!/bin/sh
# Install or update Taptone on macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/theiskaa/taptone/main/install.sh | sh
#
# Downloads the latest release, checks its checksum, its Developer ID
# signature and its notarization, then puts Taptone.app in /Applications
# (or ~/Applications when /Applications isn't writable) and opens it. Running
# it again updates Taptone in place; its settings and permission are kept.
#
# Releases are GitHub releases of theiskaa/taptone, each tagged v<version>
# and holding SHA256SUMS and the Taptone-<version>-macos.zip it names.
#
# Environment:
#   TAPTONE_VERSION              release to install (default: latest)
#   TAPTONE_DOWNLOAD_BASE        another folder holding the zip and SHA256SUMS,
#                                over https:// or file://
#   TAPTONE_INSTALL_DIR          install into this folder instead
#   TAPTONE_ALLOW_UNNOTARIZED=1  accept a signed but not notarized build
#   TAPTONE_NO_OPEN=1            don't open Taptone afterwards
set -eu

IDENTIFIER="com.theiskaa.taptone"
TEAM="A474HM679A"
REQUIREMENT="anchor apple generic and identifier \"$IDENTIFIER\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$TEAM\""
RELEASES="https://github.com/theiskaa/taptone/releases"

say() { printf '%s\n' "$*"; }
fail() {
	printf 'taptone install: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Darwin ] || fail "Taptone runs on macOS only."
[ "$(id -u)" -ne 0 ] || fail "run this as yourself, not with sudo"
os=$(sw_vers -productVersion)
major=${os%%.*}
minor=$(printf '%s\n' "$os" | cut -d. -f2)
[ "$major" -gt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -ge 2 ]; } ||
	fail "Taptone needs macOS 14.2 or later; this Mac has $os."

# Where it goes: wherever Taptone already is, else /Applications when that's writable, else ~/Applications.
if [ -n "${TAPTONE_INSTALL_DIR:-}" ]; then
	target=$TAPTONE_INSTALL_DIR
elif [ -d "$HOME/Applications/Taptone.app" ] && [ ! -d /Applications/Taptone.app ]; then
	target="$HOME/Applications"
elif [ -w /Applications ]; then
	target=/Applications
else
	target="$HOME/Applications"
fi
dest="$target/Taptone.app"

# Only Taptone itself may be replaced; another app named Taptone is left alone.
if [ -e "$dest" ] || [ -L "$dest" ]; then
	[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null)" = "$IDENTIFIER" ] ||
		fail "another app named Taptone is in $target. Move or rename it, then run this again."
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/taptone-install.XXXXXX")
previous=""
# On any exit, a swap stopped half way puts the previous app back.
cleanup() {
	if [ -n "$previous" ] && [ -d "$previous" ]; then
		if [ ! -e "$dest" ]; then
			mv "$previous" "$dest" || say "Your previous Taptone.app is at $previous"
		else
			rm -rf "$previous"
		fi
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${TAPTONE_DOWNLOAD_BASE:-}" ]; then
	base=${TAPTONE_DOWNLOAD_BASE%/}
elif [ -n "${TAPTONE_VERSION:-}" ]; then
	base="$RELEASES/download/v${TAPTONE_VERSION#v}"
else
	base="$RELEASES/latest/download"
fi
case $base in
https://*) protocols='=https' ;;
file://*) protocols='=file' ;;
*) fail "releases come over https or from a file:// folder, not $base" ;;
esac
fetch() { # url output
	curl -fsSL --proto "$protocols" --proto-redir =https --connect-timeout 30 --max-time 600 -o "$2" "$1"
}

if ! fetch "$base/SHA256SUMS" "$work/SHA256SUMS" 2>/dev/null; then
	[ -n "${TAPTONE_DOWNLOAD_BASE:-}${TAPTONE_VERSION:-}" ] || fail "Taptone has no release yet, or GitHub can't be reached. See $RELEASES."
	fail "there is no release at $base"
fi
name=$(awk '$2 ~ /^Taptone-[0-9]+\.[0-9]+\.[0-9]+-macos\.zip$/ { print $2; exit }' "$work/SHA256SUMS")
[ -n "$name" ] || fail "SHA256SUMS at $base names no Taptone zip"
version=${name#Taptone-}
version=${version%-macos.zip}

say "Downloading Taptone $version"
fetch "$base/$name" "$work/$name" || fail "couldn't download $base/$name"
(cd "$work" && awk -v name="$name" '$2 == name' SHA256SUMS | shasum -a 256 -c -s) ||
	fail "$name doesn't match its checksum, so it wasn't installed"

mkdir "$work/app"
ditto -x -k "$work/$name" "$work/app" || fail "couldn't unzip $name"
staged="$work/app/Taptone.app"
[ -d "$staged" ] || fail "$name holds no Taptone.app"
codesign --verify --strict --deep -R="$REQUIREMENT" "$staged" 2>/dev/null ||
	fail "Taptone.app isn't signed by its developer, so it wasn't installed"
if [ "${TAPTONE_ALLOW_UNNOTARIZED:-}" != 1 ]; then
	spctl --assess --type execute "$staged" 2>/dev/null ||
		fail "macOS doesn't accept this build (it isn't notarized), so it wasn't installed"
fi

# Quit the copy being replaced, if it's running, so its audio session ends cleanly first.
running=""
for pid in $(pgrep -x Taptone 2>/dev/null); do
	case $(ps -o comm= -p "$pid" 2>/dev/null) in "$dest"/*) running=$pid ;; esac
done
if [ -n "$running" ]; then
	say "Quitting Taptone"
	osascript -e "tell application id \"$IDENTIFIER\" to quit" >/dev/null 2>&1 || true
	tries=0
	while kill -0 "$running" 2>/dev/null && [ "$tries" -lt 50 ]; do
		sleep 0.1
		tries=$((tries + 1))
	done
	kill "$running" 2>/dev/null || true
fi

mkdir -p "$target"
# Stage beside the destination, so the swap is a rename on one volume.
incoming="$target/.Taptone.app.incoming.$$"
rm -rf "$incoming"
ditto "$staged" "$incoming" || fail "couldn't write to $target"
if [ -e "$dest" ]; then
	previous="$target/.Taptone.app.previous.$$"
	mv "$dest" "$previous"
fi
mv "$incoming" "$dest" || {
	rm -rf "$incoming"
	fail "couldn't put Taptone.app in $target"
}
say "Installed Taptone $version in $target"

if [ "${TAPTONE_NO_OPEN:-}" != 1 ]; then
	open "$dest" || say "Open Taptone from $target to start it."
fi
