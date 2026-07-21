class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/mstroshin/SimTool"
  url "https://github.com/mstroshin/SimTool/releases/download/v0.4.0/simtool-v0.4.0-macos-arm64.tar.gz"
  version "0.4.0"
  sha256 "9744646a5b19058242ae91884fd51f1c9fbbfaa2b850a5e1ec472730ed7c8859"

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
