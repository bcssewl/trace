#!/usr/bin/env bash
# scripts/ship.sh
#
# Cut a Trace release in one command. Pushes main, then creates and pushes a
# version tag — which triggers the GitHub Actions "release-unsigned" workflow to
# build the DMG and publish it as a GitHub Release.
#
# Usage:
#   scripts/ship.sh v0.1.2
#   scripts/ship.sh 0.1.2                     # leading "v" optional
#   scripts/ship.sh v0.2.0 "Adds X, fixes Y"  # optional annotated-tag message
#
# Guard-rails: refuses to run off main, with uncommitted changes, on a bad
# version format, or if the tag already exists.

set -euo pipefail

VERSION="${1:-}"
MESSAGE="${2:-}"

if [[ -z "$VERSION" ]]; then
    echo "usage: scripts/ship.sh vX.Y.Z [\"release message\"]" >&2
    exit 1
fi

# Accept "0.1.2" or "v0.1.2"; normalise to a leading "v".
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must look like v1.2.3 (got '$VERSION')" >&2
    exit 1
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "ERROR: releases are cut from main; you're on '$BRANCH'" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: you have uncommitted changes — commit or stash them first." >&2
    git status --short >&2
    exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "ERROR: tag $VERSION already exists." >&2
    exit 1
fi

echo "==> pushing main"
git push origin main

echo "==> tagging $VERSION"
if [[ -n "$MESSAGE" ]]; then
    git tag -a "$VERSION" -m "$MESSAGE"
else
    git tag "$VERSION"
fi
git push origin "$VERSION"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo 'bcssewl/trace')"
echo
echo "==> shipped $VERSION"
echo "    building now: https://github.com/$REPO/actions/workflows/release-unsigned.yml"
echo "    release will land at: https://github.com/$REPO/releases/tag/$VERSION"
