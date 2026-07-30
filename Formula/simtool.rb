class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/mstroshin/SimTool"
  url "https://github.com/mstroshin/SimTool/releases/download/v0.10.0/simtool-v0.10.0-macos-arm64.tar.gz"
  version "0.10.0"
  sha256 "38637a333a35243ff6a265eca8f05a3a8ded6e3774d631e803219d8bc248e881"

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
