#!/bin/bash
set -euo pipefail

bump_type="${1:-}"
case "$bump_type" in
    patch|minor|major) ;;
    *)
        echo "Usage: $0 <patch|minor|major>" >&2
        exit 1
        ;;
esac

latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n 1)"
current_version="${latest_tag#v}"
if test -z "$current_version"; then
    current_version="0.0.0"
fi

IFS=. read -r major minor patch <<< "$current_version"
case "$bump_type" in
    patch)
        patch=$((patch + 1))
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
esac

printf '%s.%s.%s\n' "$major" "$minor" "$patch"
