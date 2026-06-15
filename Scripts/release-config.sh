#!/usr/bin/env bash

SIMTOOL_GITHUB_OWNER="${SIMTOOL_GITHUB_OWNER:-mstroshin}"
SIMTOOL_GITHUB_REPO="${SIMTOOL_GITHUB_REPO:-SimTool}"
SIMTOOL_TAP_OWNER="${SIMTOOL_TAP_OWNER:-$SIMTOOL_GITHUB_OWNER}"
SIMTOOL_TAP_REPO="${SIMTOOL_TAP_REPO:-homebrew-simtool}"
SIMTOOL_FORMULA_NAME="${SIMTOOL_FORMULA_NAME:-simtool}"
SIMTOOL_MIN_MACOS="${SIMTOOL_MIN_MACOS:-14.0}"
SIMTOOL_TESTED_XCODE="${SIMTOOL_TESTED_XCODE:-Xcode 26.5}"
SIMTOOL_ARTIFACT_BASENAME="${SIMTOOL_ARTIFACT_BASENAME:-simtool}"
SIMTOOL_RELEASE_ROOT="${SIMTOOL_RELEASE_ROOT:-.build/release-distribution}"

simtool_validate_version() {
  local version="$1"
  if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must match v<major>.<minor>.<patch>, got: $version" >&2
    return 1
  fi
}

simtool_architecture() {
  if [[ -n "${SIMTOOL_ARCH:-}" ]]; then
    echo "$SIMTOOL_ARCH"
  else
    uname -m
  fi
}

simtool_archive_name() {
  local version="$1"
  local arch="$2"
  echo "${SIMTOOL_ARTIFACT_BASENAME}-${version}-macos-${arch}.tar.gz"
}

simtool_release_dir() {
  local version="$1"
  echo "${SIMTOOL_RELEASE_ROOT}/${version}"
}

simtool_archive_path() {
  local version="$1"
  local arch="$2"
  echo "$(simtool_release_dir "$version")/$(simtool_archive_name "$version" "$arch")"
}

simtool_checksum_path() {
  local version="$1"
  local arch="$2"
  echo "$(simtool_archive_path "$version" "$arch").sha256"
}

simtool_release_notes_path() {
  local version="$1"
  echo "$(simtool_release_dir "$version")/release-notes.md"
}

simtool_release_url() {
  local version="$1"
  local arch="$2"
  echo "https://github.com/${SIMTOOL_GITHUB_OWNER}/${SIMTOOL_GITHUB_REPO}/releases/download/${version}/$(simtool_archive_name "$version" "$arch")"
}
