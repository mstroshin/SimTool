#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/release-config.sh"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/publish-release.sh v<major>.<minor>.<patch> [--update-existing] [--dry-run]

Environment overrides:
  SIMTOOL_GITHUB_OWNER  GitHub owner, default mstroshin
  SIMTOOL_GITHUB_REPO   GitHub repository, default SimTool
  SIMTOOL_ARCH          Artifact architecture override
EOF
}

UPDATE_EXISTING=0
DRY_RUN=0
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-existing)
      UPDATE_EXISTING=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    v*)
      VERSION="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  usage
  exit 1
fi

simtool_validate_version "$VERSION"

for tool in gh git shasum tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool for publishing: $tool" >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is installed but not authenticated. Run: gh auth login" >&2
  exit 1
fi

REPO="${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO}"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  echo "GitHub repo $REPO is not reachable." >&2
  echo "Create it with:" >&2
  echo "  gh repo create $REPO --public --source=. --remote=origin --push" >&2
  exit 1
fi

cd "$REPO_ROOT"
ARCH="$(simtool_architecture)"
ARCHIVE_PATH="$(simtool_archive_path "$VERSION" "$ARCH")"
CHECKSUM_PATH="$(simtool_checksum_path "$VERSION" "$ARCH")"
NOTES_PATH="$(simtool_release_notes_path "$VERSION")"

for path in "$ARCHIVE_PATH" "$CHECKSUM_PATH" "$NOTES_PATH"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing release artifact: $path" >&2
    echo "Run: Scripts/package-release.sh $VERSION" >&2
    exit 1
  fi
done

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Git tag $VERSION already exists locally."
else
  if (( DRY_RUN )); then
    echo "Would create git tag $VERSION"
  else
    git tag -a "$VERSION" -m "SimTool $VERSION"
  fi
fi

if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  if (( UPDATE_EXISTING == 0 )); then
    echo "GitHub Release $VERSION already exists for $REPO. Re-run with --update-existing to upload assets with --clobber." >&2
    exit 1
  fi
  if (( DRY_RUN )); then
    echo "Would upload $ARCHIVE_PATH and $CHECKSUM_PATH to existing release $VERSION"
  else
    gh release upload "$VERSION" "$ARCHIVE_PATH" "$CHECKSUM_PATH" --repo "$REPO" --clobber
  fi
else
  if (( DRY_RUN )); then
    echo "Would create GitHub Release $VERSION for $REPO"
    echo "Would upload $ARCHIVE_PATH and $CHECKSUM_PATH"
  else
    git push "git@github.com:${REPO}.git" "$VERSION"
    gh release create "$VERSION" "$ARCHIVE_PATH" "$CHECKSUM_PATH" \
      --repo "$REPO" \
      --title "SimTool $VERSION" \
      --notes-file "$NOTES_PATH"
  fi
fi

echo "Release URL: https://github.com/${REPO}/releases/tag/${VERSION}"
