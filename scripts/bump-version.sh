#!/usr/bin/env bash
# Bumps the version in one place and tags the release.
#
# Usage:
#   ./scripts/bump-version.sh 1.1.0                # bump versionCode/build +1, tag v1.1.0
#   ./scripts/bump-version.sh 1.1.0 --code 7       # set Android versionCode and mac build to 7
#   ./scripts/bump-version.sh 1.1.0 --no-tag       # update files, don't tag
#
# Updates:
#   android/app/build.gradle.kts  versionCode / versionName
#   mac/project.yml               MARKETING_VERSION / CURRENT_PROJECT_VERSION
#   CHANGELOG.md                  moves [Unreleased] into the new version
#
# Creates an annotated tag `v<version>` unless --no-tag is given.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_GRADLE="$ROOT/android/app/build.gradle.kts"
MAC_PROJECT="$ROOT/mac/project.yml"
CHANGELOG="$ROOT/CHANGELOG.md"

version=""
code=""
do_tag=1

for arg in "$@"; do
    case "$arg" in
        --code) ;;
        --no-tag) do_tag=0 ;;
        --code=*) code="${arg#--code=}" ;;
        --*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) if [[ -z "$version" ]]; then version="$arg"; else echo "unexpected arg: $arg" >&2; exit 2; fi ;;
    esac
done

if [[ -z "$version" ]]; then
    echo "usage: $0 <semver> [--code N] [--no-tag]" >&2
    exit 2
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must be semantic (e.g. 1.1.0), got: $version" >&2
    exit 2
fi

# --- Android ---------------------------------------------------------------
code_or_next="$code"
if [[ -z "$code_or_next" ]]; then
    cur_code=$(grep -oE 'versionCode = [0-9]+' "$ANDROID_GRADLE" | grep -oE '[0-9]+')
    code_or_next=$((cur_code + 1))
fi

sed -i '' "s/versionCode = [0-9]*/versionCode = $code_or_next/" "$ANDROID_GRADLE"
sed -i '' "s/versionName = \"[^\"]*\"/versionName = \"$version\"/" "$ANDROID_GRADLE"
echo "android: versionName=$version versionCode=$code_or_next"

# --- macOS -----------------------------------------------------------------
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$version\"/" "$MAC_PROJECT"
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$code_or_next\"/" "$MAC_PROJECT"
echo "mac: MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$code_or_next"

# --- CHANGELOG --------------------------------------------------------------
today=$(date +%Y-%m-%d)
if grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
    perl -0pi -e "s/## \[Unreleased\]/## [$version] - $today/" "$CHANGELOG"
    echo "changelog: moved [Unreleased] -> [$version]"
else
    echo "changelog: no [Unreleased] section found; leaving as-is"
fi

# --- Tag -------------------------------------------------------------------
if (( do_tag )); then
    tag="v$version"
    if git -C "$ROOT" rev-parse "$tag" >/dev/null 2>&1; then
        echo "tag $tag already exists; skipping" >&2
    else
        git -C "$ROOT" add android/app/build.gradle.kts mac/project.yml CHANGELOG.md
        git -C "$ROOT" commit -m "Release $version"
        git -C "$ROOT" tag -a "$tag" -m "Release $version"
        echo "tagged $tag (run: git push --follow-tags to publish)"
    fi
else
    echo "not tagging (--no-tag)"
fi

echo "done."
