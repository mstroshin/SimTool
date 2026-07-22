class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/mstroshin/SimTool"
  url "https://github.com/mstroshin/SimTool/releases/download/v0.8.0/simtool-v0.8.0-macos-arm64.tar.gz"
  version "0.8.0"
  sha256 "87210d528c8d98aa84efb56aa019f89ac767e1e660483b7c825c2309202913fa"

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
