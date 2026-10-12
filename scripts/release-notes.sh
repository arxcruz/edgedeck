#!/usr/bin/env bash
# Prints the CHANGELOG.md section for one version (the lines under "## <version>", up to the
# next "## "), for the release page. Prints nothing if there's no such section.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$1"
awk -v v="$version" '
    /^## / { if (found) exit; found = ($0 == "## " v || index($0, "## " v " ") == 1); next }
    found
' CHANGELOG.md | sed -e '/./,$!d'
