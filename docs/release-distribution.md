# Release Distribution

This document describes how to publish SimTool for macOS through GitHub Releases and a Homebrew tap.

## Canonical Repositories

Defaults used by release scripts:

- Main repository: `mstroshin/SimTool`
- Homebrew tap: `mstroshin/homebrew-simtool`
- User tap command: `brew tap mstroshin/simtool`

Override these defaults with environment variables when needed:

```sh
export SIMTOOL_GITHUB_OWNER=mstroshin
export SIMTOOL_GITHUB_REPO=SimTool
export SIMTOOL_TAP_OWNER=mstroshin
export SIMTOOL_TAP_REPO=homebrew-simtool
```

## Runtime Prerequisites

Users need:

- macOS 14 or newer.
- Xcode or Command Line Tools with simulator support.
- Installed iOS simulator runtimes for simulator commands.
- `xcode-select` pointing at the selected developer directory.
- AXe only for accessibility automation commands.

Homebrew does not install simulator runtimes or AXe automatically. Use `simtool doctor` after installation to inspect local dependencies.

## First-Time GitHub Setup

If the main GitHub repository does not exist yet:

```sh
gh auth login
gh repo create mstroshin/SimTool --public --source=. --remote=origin --push
```

If the Homebrew tap does not exist yet:

```sh
gh repo create mstroshin/homebrew-simtool --public
gh repo clone mstroshin/homebrew-simtool ../homebrew-simtool
```

If the tap already exists:

```sh
gh repo clone mstroshin/homebrew-simtool ../homebrew-simtool
```

## Release Flow

Choose a SemVer tag such as `v0.1.0`.

1. Check prerequisites:

```sh
Scripts/check-release-prerequisites.sh
```

2. Package and smoke-test the binary:

```sh
Scripts/package-release.sh v0.1.0
```

This creates files under `.build/release-distribution/v0.1.0/`:

- `simtool-v0.1.0-macos-<arch>.tar.gz`
- `simtool-v0.1.0-macos-<arch>.tar.gz.sha256`
- `release-notes.md`

3. Publish the GitHub Release:

```sh
Scripts/publish-release.sh v0.1.0
```

Use `--dry-run` to inspect actions without publishing. Use `--update-existing` only when intentionally replacing release assets.

4. Generate and publish the Homebrew formula:

```sh
Scripts/update-homebrew-formula.sh v0.1.0 --tap-path ../homebrew-simtool --commit --push
```

The generated formula downloads the exact GitHub Release archive and verifies its SHA-256 checksum.

## User Installation

```sh
brew tap mstroshin/simtool
brew trust mstroshin/simtool   # recent Homebrew requires trusting a third-party tap before install
brew install simtool
simtool doctor
```

Upgrade:

```sh
brew update
brew upgrade simtool
```

Uninstall:

```sh
brew uninstall simtool
```

Source fallback:

```sh
swift build --package-path Tool
swift run --package-path Tool simtool doctor
```

## Validation

Before publishing a real release, run:

```sh
openspec validate --changes --strict
openspec validate --specs --strict
swift test
swift test --package-path Tool
swift build --package-path Tool -c release --product simtool
Scripts/package-release.sh v0.0.0
```

If a tap clone is available, validate the generated formula:

```sh
Scripts/update-homebrew-formula.sh v0.0.0 --tap-path ../homebrew-simtool
brew install --formula ../homebrew-simtool/Formula/simtool.rb
brew test simtool
```

Use a real published version for public formula validation because Homebrew formula URLs must point at reachable release assets.

## Rollback

If a release is invalid:

1. Delete or mark the GitHub Release as superseded:

```sh
gh release delete v0.1.0 --repo mstroshin/SimTool --cleanup-tag
```

2. Revert the Homebrew tap formula commit:

```sh
git -C ../homebrew-simtool revert HEAD
git -C ../homebrew-simtool push
```

3. Publish a fixed version with a new tag.
