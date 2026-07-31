#!/usr/bin/env bash
#
# Prints the CHANGELOG.md body for one version, without its heading — the text
# used as the GitHub Release notes.
#
#   scripts/changelog-section.sh 2.1.6
#
set -euo pipefail

version="${1:?usage: scripts/changelog-section.sh <version>   e.g. 2.1.6}"
changelog="${2:-CHANGELOG.md}"

# Headings look like "## [2.1.6] — 2026-07-31 (current)".  The date separator has
# been both an em dash and a hyphen over the years, so only the version part is
# matched.
section=$(
  awk -v version="$version" '
    $0 ~ "^## \\[" version "\\]" { inside = 1; next }
    inside && /^## \[/           { exit }
    inside                       { print }
  ' "$changelog" |
    sed '/^---$/d' |
    sed '/./,$!d' |
    tac | sed '/./,$!d' | tac
)

if [ -z "$section" ]; then
  echo "no CHANGELOG section found for version $version" >&2
  exit 1
fi

printf '%s\n' "$section"
