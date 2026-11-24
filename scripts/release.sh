#!/bin/sh
# Release Taptone as a GitHub release and a Homebrew cask.
#
#   scripts/release.sh 0.2.0
#   scripts/release.sh --dry-run 0.2.0
#
# Runs the tests, sets CFBundleShortVersionString to the version and bumps
# CFBundleVersion in App/Info.plist (committing "chore: release <version>"),
# builds a universal Taptone.app, signs it with Developer ID and the hardened
# runtime, notarizes and staples it, zips it as dist/Taptone-<version>-macos.zip
# with dist/SHA256SUMS, checks the archive the way a download is checked, then
# tags v<version>, pushes main and the tag, publishes the GitHub release with
# the version's CHANGELOG.md section as notes, and points the cask in the tap
# at it. Releases are cut from a clean main that matches origin/main. Tests run
# before the version commit; when a run fails after it, run it again: it reuses
# that commit.
#
# --dry-run does the local part with a bumped copy of Info.plist: tests,
# build, Developer ID signing, zip, SHA256SUMS, archive checks and the cask,
# rendered into dist/. It reports what the preflight would stop on, and
# commits, notarizes, tags, pushes and publishes nothing.
#
# Environment:
#   SIGN_IDENTITY   Developer ID Application identity
#                   (default: Developer ID Application: Ismayil Shahverdiyev (A474HM679A))
#   NOTARY_PROFILE  notarytool keychain profile (default: taptone-notary)
#   TAP             the Homebrew tap the cask lives in (default: theiskaa/homebrew-tap)
set -eu

identity=${SIGN_IDENTITY:-"Developer ID Application: Ismayil Shahverdiyev (A474HM679A)"}
profile=${NOTARY_PROFILE:-taptone-notary}
tap=${TAP:-theiskaa/homebrew-tap}
repo="theiskaa/taptone"
releases="https://github.com/$repo/releases"

step() { printf '\n> %s\n' "$*"; }
fail() {
	printf 'release: %s\n' "$*" >&2
	exit 1
}

dry_run=0
case ${1:-} in --dry-run)
	dry_run=1
	shift
	;;
esac
version=${1:-}
[ $# -eq 1 ] || fail "usage: scripts/release.sh [--dry-run] X.Y.Z"
expr "$version" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null ||
	fail "the version must be plain numbers such as 0.2.0, not $version"
tag="v$version"
name="Taptone-$version-macos.zip"
team=$(printf '%s\n' "$identity" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
cd "$(dirname "$0")/.."

# A failed check stops a release; a dry run notes it and carries on.
blocked=0
stop() {
	[ "$dry_run" -eq 1 ] || fail "$*"
	printf 'would stop: %s\n' "$*" >&2
	blocked=$((blocked + 1))
}

work=$(mktemp -d "${TMPDIR:-/tmp}/taptone-release.XXXXXX")
# On an unexpected exit after the version commit, say how to pick up again.
committed=0
on_exit() {
	status=$?
	rm -rf "$work"
	if [ "$status" -ne 0 ] && [ "$committed" -eq 1 ]; then
		printf 'release: stopped after the version commit; fix the cause and run scripts/release.sh %s again\n' "$version" >&2
	fi
}
trap on_exit EXIT

plist=App/Info.plist
buddy=/usr/libexec/PlistBuddy
current=$("$buddy" -c 'Print CFBundleShortVersionString' "$plist")
build=$("$buddy" -c 'Print CFBundleVersion' "$plist")
expr "$build" : '[0-9][0-9]*$' >/dev/null || fail "CFBundleVersion must be a whole number, not $build"
# A rerun after a failure resumes from its own version commit.
resuming=0
if [ "$(git log -1 --format=%s)" = "chore: release $version" ] && [ "$current" = "$version" ]; then
	resuming=1
	committed=1
fi

step "Preflight"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || stop "release from main"
[ -z "$(git status --porcelain)" ] || stop "commit or stash your changes first"
if git fetch -q origin main; then
	upstream=$(git rev-parse origin/main)
	if [ "$resuming" -eq 1 ]; then
		[ "$(git rev-parse HEAD^)" = "$upstream" ] || stop "the version commit does not sit on origin/main"
	else
		[ "$(git rev-parse HEAD)" = "$upstream" ] || stop "main differs from origin/main; run git pull --rebase (or push) first"
	fi
else
	stop "could not fetch origin main"
fi
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || stop "$tag already exists here"
! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 || stop "$tag already exists on origin"
if gh auth status >/dev/null 2>&1; then
	[ "$(gh repo view "$repo" --json visibility --jq .visibility 2>/dev/null)" = PUBLIC ] ||
		stop "$repo is not public, so Homebrew and browsers cannot download its releases"
	case $(gh repo view "$tap" --json viewerPermission --jq .viewerPermission 2>/dev/null) in
	ADMIN | MAINTAIN | WRITE) ;;
	*) stop "you cannot push to $tap, whose cask this release updates" ;;
	esac
else
	stop "gh is not signed in; run gh auth login"
fi
grep -q "^## \[$version\]" CHANGELOG.md 2>/dev/null ||
	stop "CHANGELOG.md has no \"## [$version]\" section for the release notes"
security find-identity -v -p codesigning | grep -qF "\"$identity\"" ||
	stop "the keychain has no signing identity named $identity"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
	stop "no notarytool profile named $profile; create it once with
  xcrun notarytool store-credentials $profile --apple-id <your Apple ID> --team-id ${team:-<team ID>}
and enter an app-specific password from account.apple.com when asked"

# Test before the version commit, so a failing test never leaves a commit to undo.
step "Checks"
swift test

if [ "$resuming" -eq 1 ]; then
	step "Resuming from the version commit ($version, build $build)"
	info=$plist
else
	build=$((build + 1))
	if [ "$dry_run" -eq 1 ]; then
		step "Setting the version to $version (build $build) in a copy of $plist"
		info="$work/Info.plist"
		cp "$plist" "$info"
	else
		step "Setting the version to $version (build $build)"
		info=$plist
	fi
	"$buddy" -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $build" "$info"
	if [ "$dry_run" -eq 0 ]; then
		# Date the version's heading when it still says Unreleased.
		sed -i '' "s/^## \[$version\] - Unreleased\$/## [$version] - $(date +%Y-%m-%d)/" CHANGELOG.md
		git commit -q -m "chore: release $version" App/Info.plist CHANGELOG.md
		committed=1
	fi
fi

step "Building and signing with $identity"
# sh has no pipefail, so check the build's status before reading the path it prints last.
build_log=.build/release-build.log
mkdir -p .build
scripts/build-app.sh release --universal --hardened --identity "$identity" --info-plist "$info" >"$build_log" 2>&1 ||
	fail "the build failed; see $build_log"
app=$(tail -n 1 "$build_log")
[ -d "$app" ] || fail "the build printed no app path; see $build_log"
details=$(codesign -dvv "$app" 2>&1)
printf '%s\n' "$details" | grep -qF "Authority=$identity" || fail "the app is not signed by $identity"
printf '%s\n' "$details" | grep -q '^CodeDirectory.*(runtime)' || fail "the app is signed without the hardened runtime"
printf '%s\n' "$details" | grep -q '^Timestamp=' || fail "the signature has no secure timestamp"
archs=" $(lipo -archs "$app/Contents/MacOS/Taptone") "
case $archs in *" arm64 "*) ;; *) fail "the app has no arm64 slice" ;; esac
case $archs in *" x86_64 "*) ;; *) fail "the app has no x86_64 slice" ;; esac

dist=dist
zip="$dist/$name"
mkdir -p "$dist"
rm -f "$zip" "$dist/SHA256SUMS" "$dist/notes.md" "$dist/taptone.rb"
ditto -c -k --keepParent "$app" "$zip"

if [ "$dry_run" -eq 1 ]; then
	step "Notarizing: skipped in a dry run"
	echo "would run: xcrun notarytool submit $zip --keychain-profile $profile --wait"
	echo "           xcrun stapler staple $app, then zip it again"
else
	step "Notarizing (this takes a few minutes)"
	xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json >"$work/notary.json" || true
	status=$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || echo unknown)
	if [ "$status" != Accepted ]; then
		id=$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)
		[ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
		fail "notarization ended with status $status"
	fi
	xcrun stapler staple "$app"
	xcrun stapler validate "$app"
	rm -f "$zip"
	ditto -c -k --keepParent "$app" "$zip"
fi
(cd "$dist" && shasum -a 256 "$name" >SHA256SUMS)

# The checks a download gets, on the archive people download.
step "Checking the archive"
(cd "$dist" && shasum -a 256 -c -s SHA256SUMS) || fail "SHA256SUMS does not match $zip"
awk -v name="$name" '$2 == name { print $1 }' "$dist/SHA256SUMS" | grep -qx '[0-9a-f]\{64\}' ||
	fail "SHA256SUMS has no checksum for $name"
mkdir "$work/unzipped"
ditto -x -k "$zip" "$work/unzipped"
unzipped="$work/unzipped/Taptone.app"
codesign --verify --strict --deep "$unzipped" || fail "the app's signature is invalid"
codesign -d --entitlements - --xml "$unzipped" 2>/dev/null | plutil -convert json -o "$work/signed.json" -
plutil -convert json -o "$work/wanted.json" App/Taptone.entitlements
cmp -s "$work/signed.json" "$work/wanted.json" || fail "the app's entitlements differ from App/Taptone.entitlements"
built=$("$buddy" -c 'Print CFBundleShortVersionString' "$unzipped/Contents/Info.plist")
[ "$built" = "$version" ] || fail "the app says $built, not $version"
[ "$("$buddy" -c 'Print CFBundleVersion' "$unzipped/Contents/Info.plist")" = "$build" ] ||
	fail "the app's CFBundleVersion is not $build"
if [ "$dry_run" -eq 1 ]; then
	echo "Gatekeeper, for information (unnotarized, so it is expected to reject):"
	spctl --assess --type execute -vv "$unzipped" 2>&1 | sed 's/^/  /' || true
else
	xcrun stapler validate -q "$unzipped" || fail "the downloaded app has no stapled ticket"
	spctl --assess --type execute "$unzipped" || fail "Gatekeeper rejects the app"
fi
echo "$name: signed by $identity, hardened, version $built ($build)"

step "Writing the release notes"
previous=$(git describe --tags --abbrev=0 2>/dev/null || true)
# shellcheck disable=SC2016 # the backticks are Markdown
{
	printf '## Install\n\n```sh\nbrew install --cask %s/taptone\n```\n\n' "$(printf '%s\n' "$tap" | sed 's|/homebrew-|/|')"
	printf 'Or download %s below, unzip it, and move Taptone to Applications.\n\n' "$name"
	printf 'Requires macOS 14.2 or later and a Mac with a Force Touch trackpad.\n\n## Changes\n\n'
	# The version's section of CHANGELOG.md, when it has one.
	if grep -q "^## \[$version\]" CHANGELOG.md 2>/dev/null; then
		awk -v head="## [$version]" 'index($0, head) == 1 { on = 1; next } on && /^## \[/ { exit } on' CHANGELOG.md |
			sed -e '/./,$!d'
	elif [ -n "$previous" ]; then
		git log --no-merges --pretty='- %s' "$previous..HEAD"
	else
		echo "The first release."
	fi
} >"$dist/notes.md"
echo "$dist/notes.md"

if [ "$dry_run" -eq 1 ]; then
	step "Rendering the cask"
	TAP=$tap scripts/update-cask.sh --dry-run "$version"
	step "Dry run done"
	echo "Built, signed and checked $zip."
	echo "Nothing was committed, notarized, tagged, pushed or published."
	[ "$blocked" -eq 0 ] || echo "A real release would stop at $blocked preflight check(s) above."
	exit 0
fi

step "Publishing $tag"
git tag -a "$tag" -m "Taptone $version"
# Push main and the tag together, or neither, so a failed push can simply be run again.
git push -q --atomic origin main "$tag" || {
	git tag -d "$tag" >/dev/null
	fail "the push failed, and the local tag $tag was removed; fix the cause and run scripts/release.sh $version again"
}
gh release create "$tag" "$zip" "$dist/SHA256SUMS" --repo "$repo" --verify-tag \
	--title "Taptone $version" --notes-file "$dist/notes.md" ||
	fail "$tag is pushed, but its GitHub release wasn't created; retry with: gh release create $tag $zip $dist/SHA256SUMS --repo $repo --verify-tag --title \"Taptone $version\" --notes-file $dist/notes.md, then scripts/update-cask.sh $version"

step "Updating the Homebrew cask"
TAP=$tap scripts/update-cask.sh "$version" ||
	fail "$tag is published, but the cask was not updated; retry with scripts/update-cask.sh $version"

step "Checking the download"
if curl -fsSL "$releases/download/$tag/SHA256SUMS" | grep -qF "$name"; then
	echo "$releases/download/$tag serves $name"
else
	echo "warning: $releases/download/$tag does not serve $name yet"
fi
echo "Released: $releases/tag/$tag"
