#!/usr/bin/env bash
# A script for the shell checks: two functions, a variable set at the top,
# and the same variable set again inside a loop, which is a statement and
# must not index as a second declaration of the file.
set -euo pipefail

MODE="fast"

pick_mode() {
    for arg in "$@"; do
        MODE="$arg"
    done
    echo "$MODE"
}

main() {
    pick_mode "$@"
}

main "$@"
