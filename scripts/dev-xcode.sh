#!/usr/bin/env bash
# scripts/dev-xcode.sh — generate the TraceDev.xcodeproj and open it.
#
# The Xcode project is intentionally NOT committed; it is regenerated from
# dev/project.yml so a single source of truth lives in YAML and developer
# checkouts always get a fresh project that tracks any added Sources/.
#
# Usage:
#   ./scripts/dev-xcode.sh            # generate + open in Xcode
#   ./scripts/dev-xcode.sh --no-open  # generate only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${REPO_ROOT}/dev"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen is not installed." >&2
  echo "  brew install xcodegen" >&2
  exit 1
fi

cd "${DEV_DIR}"
xcodegen generate
echo "Generated dev/TraceDev.xcodeproj"

if [[ "${1:-}" == "--no-open" ]]; then
  exit 0
fi

open "${DEV_DIR}/TraceDev.xcodeproj"
