#!/usr/bin/env bash
# Removes Taptone.
#
#     scripts/uninstall.sh          # quit and remove the app
#     scripts/uninstall.sh --purge  # also forget its settings and system audio permission
set -euo pipefail

purge=0
for argument in "$@"; do
    case "$argument" in
        --purge) purge=1 ;;
        *) printf 'Usage: %s [--purge]\n' "$0" >&2; exit 2 ;;
    esac
done

if /usr/bin/pgrep -qx Taptone; then
    /usr/bin/osascript -e 'tell application id "com.theiskaa.taptone" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do /usr/bin/pgrep -qx Taptone || break; sleep 0.1; done
    /usr/bin/pkill -x Taptone 2>/dev/null || true
fi

removed=0
for folder in "${TAPTONE_INSTALL_DIR:-}" /Applications "$HOME/Applications"; do
    [[ -n "$folder" && -d "$folder/Taptone.app" ]] || continue
    rm -rf -- "$folder/Taptone.app"
    printf 'Removed %s\n' "$folder/Taptone.app"
    removed=1
done
(( removed )) || printf 'Taptone.app was not found.\n'

if (( purge )); then
    /usr/bin/defaults delete com.theiskaa.taptone >/dev/null 2>&1 || true
    /usr/bin/tccutil reset All com.theiskaa.taptone >/dev/null 2>&1 || true
    printf 'Forgot Taptone’s settings and permissions.\n'
fi
