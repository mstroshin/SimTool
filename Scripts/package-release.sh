#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/release-config.sh"

usage() {
  echo "Usage: $0 v<major>.<minor>.<patch>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
simtool_validate_version "$VERSION"

for tool in swift xcrun git shasum tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool for packaging: $tool" >&2
    exit 1
  fi
done

cd "$REPO_ROOT"

ARCH="$(simtool_architecture)"
RELEASE_DIR="$(simtool_release_dir "$VERSION")"
STAGE_DIR="${RELEASE_DIR}/stage"
UNPACK_DIR="${RELEASE_DIR}/smoke-test"
ARCHIVE_PATH="$(simtool_archive_path "$VERSION" "$ARCH")"
CHECKSUM_PATH="$(simtool_checksum_path "$VERSION" "$ARCH")"
NOTES_PATH="$(simtool_release_notes_path "$VERSION")"

rm -rf "$RELEASE_DIR"
mkdir -p "$STAGE_DIR/bin" "$UNPACK_DIR"

swift build -c release --product simtool

cp ".build/release/simtool" "$STAGE_DIR/bin/simtool"
chmod 755 "$STAGE_DIR/bin/simtool"
if [[ -f README.md ]]; then
  cp README.md "$STAGE_DIR/README.md"
fi
for license in LICENSE LICENSE.md LICENSE.txt; do
  if [[ -f "$license" ]]; then
    cp "$license" "$STAGE_DIR/$license"
    break
  fi
done

COPYFILE_DISABLE=1 tar -czf "$ARCHIVE_PATH" -C "$STAGE_DIR" .
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

tar -xzf "$ARCHIVE_PATH" -C "$UNPACK_DIR"
"$UNPACK_DIR/bin/simtool" --help >/dev/null

cat > "$NOTES_PATH" <<EOF
# SimTool ${VERSION}

Install with Homebrew after the tap formula is published:

\`\`\`sh
brew tap ${SIMTOOL_TAP_OWNER}/${SIMTOOL_TAP_REPO#homebrew-}
brew install ${SIMTOOL_FORMULA_NAME}
simtool doctor
\`\`\`

Tested on macOS ${SIMTOOL_MIN_MACOS}+ with ${SIMTOOL_TESTED_XCODE}.

Runtime prerequisites:
- Xcode or Command Line Tools with simulator support.
- Installed iOS simulator runtimes for simulator commands.
- AXe is optional and required for accessibility automation commands.

Archive: $(basename "$ARCHIVE_PATH")
SHA-256: $(cut -d ' ' -f 1 "$CHECKSUM_PATH")
EOF

echo "Archive: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
echo "Release notes: $NOTES_PATH"
echo "SHA-256: $(cut -d ' ' -f 1 "$CHECKSUM_PATH")"
