class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/mstroshin/SimTool"
  url "https://github.com/mstroshin/SimTool/releases/download/v0.10.1/simtool-v0.10.1-macos-arm64.tar.gz"
  version "0.10.1"
  sha256 "1693d381dc30b8686e8f8ba4274f7f2e8601c00f42cd7f1515083f2da17a092f"

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
