#!/usr/bin/env bash
# Builds Taptone in release and installs it, replacing a running copy.
#
#     scripts/install.sh            # over an existing copy, else into /Applications (or ~/Applications)
#     scripts/install.sh --no-open  # don't launch it afterwards
#
# TAPTONE_INSTALL_DIR picks another folder; TAPTONE_SIGN_IDENTITY picks the signing certificate.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
open_after=1
for argument in "$@"; do
    case "$argument" in
        --no-open) open_after=0 ;;
        *) printf 'Usage: %s [--no-open]\n' "$0" >&2; exit 2 ;;
    esac
done

if [[ -n "${TAPTONE_INSTALL_DIR:-}" ]]; then
    destination=$TAPTONE_INSTALL_DIR
elif [[ -d "$HOME/Applications/Taptone.app" && ! -d /Applications/Taptone.app ]]; then
    destination=$HOME/Applications
elif [[ -w /Applications ]]; then
    destination=/Applications
else
    destination=$HOME/Applications
fi

built=$(scripts/build-app.sh release | tail -n 1)
target="$destination/Taptone.app"

# Quit a running copy so its capture session ends cleanly before the bundle is replaced.
if /usr/bin/pgrep -qx Taptone; then
    /usr/bin/osascript -e 'tell application id "com.theiskaa.taptone" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do /usr/bin/pgrep -qx Taptone || break; sleep 0.1; done
    /usr/bin/pkill -x Taptone 2>/dev/null || true
fi

mkdir -p -- "$destination"
rm -rf -- "$target"
/usr/bin/ditto "$built" "$target"
printf 'Installed %s\n' "$target"

if (( open_after )); then
    /usr/bin/open "$target"
fi
