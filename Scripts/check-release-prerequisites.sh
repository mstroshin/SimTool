#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release-config.sh"

missing=()
for tool in swift xcrun gh git shasum tar brew; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "Missing release prerequisites: ${missing[*]}" >&2
  echo "Install Xcode or Command Line Tools for swift/xcrun, GitHub CLI for gh, and Homebrew for brew." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is installed but not authenticated. Run: gh auth login" >&2
  exit 1
fi

if ! gh repo view "${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO}" >/dev/null 2>&1; then
  echo "GitHub repo ${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO} is not reachable." >&2
  echo "Create it with:" >&2
  echo "  gh repo create ${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO} --public --source=. --remote=origin --push" >&2
  echo "Or override SIMTOOL_GITHUB_OWNER and SIMTOOL_GITHUB_REPO." >&2
  exit 1
fi

echo "Release prerequisites OK for ${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO}."
