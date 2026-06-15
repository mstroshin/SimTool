#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/release-config.sh"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/update-homebrew-formula.sh v<major>.<minor>.<patch> [--tap-path PATH] [--commit] [--push]

Writes Formula/simtool.rb using the packaged archive URL and checksum. When
--tap-path is supplied, also copies the formula into PATH/Formula/simtool.rb.
EOF
}

VERSION=""
TAP_PATH=""
COMMIT=0
PUSH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-path)
      TAP_PATH="${2:-}"
      if [[ -z "$TAP_PATH" ]]; then
        echo "--tap-path requires a path" >&2
        exit 1
      fi
      shift 2
      ;;
    --commit)
      COMMIT=1
      shift
      ;;
    --push)
      PUSH=1
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

for tool in shasum git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool for formula update: $tool" >&2
    exit 1
  fi
done

cd "$REPO_ROOT"
ARCH="$(simtool_architecture)"
ARCHIVE_PATH="$(simtool_archive_path "$VERSION" "$ARCH")"
CHECKSUM_PATH="$(simtool_checksum_path "$VERSION" "$ARCH")"
if [[ ! -f "$ARCHIVE_PATH" || ! -f "$CHECKSUM_PATH" ]]; then
  echo "Missing archive or checksum. Run: Scripts/package-release.sh $VERSION" >&2
  exit 1
fi

SHA256="$(cut -d ' ' -f 1 "$CHECKSUM_PATH")"
URL="$(simtool_release_url "$VERSION" "$ARCH")"
FORMULA_VERSION="${VERSION#v}"
FORMULA_DIR="$REPO_ROOT/Formula"
FORMULA_PATH="$FORMULA_DIR/simtool.rb"
mkdir -p "$FORMULA_DIR"

cat > "$FORMULA_PATH" <<EOF
class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO}"
  url "${URL}"
  version "${FORMULA_VERSION}"
  sha256 "${SHA256}"

  def install
    bin.install "bin/simtool"
    prefix.install "README.md" if File.exist?("README.md")
  end

  def caveats
    <<~EOS
      SimTool requires local Apple simulator tooling.
      Install Xcode or Command Line Tools, select it with xcode-select, and install simulator runtimes.
      AXe is optional and required only for accessibility automation commands.
      Run: simtool doctor
    EOS
  end

  test do
    assert_match "Stream and automate Apple Simulators", shell_output("#{bin}/simtool --help")
  end
end
EOF

echo "Updated $FORMULA_PATH"

if [[ -n "$TAP_PATH" ]]; then
  mkdir -p "$TAP_PATH/Formula"
  cp "$FORMULA_PATH" "$TAP_PATH/Formula/simtool.rb"
  echo "Copied formula to $TAP_PATH/Formula/simtool.rb"

  if (( COMMIT )); then
    git -C "$TAP_PATH" add Formula/simtool.rb
    git -C "$TAP_PATH" commit -m "Update simtool to ${VERSION}"
  fi
  if (( PUSH )); then
    git -C "$TAP_PATH" push
  fi
fi
