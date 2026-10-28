# Copy of https://github.com/bath/homebrew-tap/blob/main/Formula/hark.rb.
# Edit the tap after each release: new url and sha256.
class Hark < Formula
  desc "Private, on-device dictation for macOS: press F5, talk, and the text is pasted"
  homepage "https://hark.works"
  url "https://github.com/bath/hark-stt/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "04df5ce29c6c50bee8edc7d1314bb049ede7dbf0deae7b80bd296aa7586bd8dd"
  license "MIT"

  depends_on arch: :arm64
  depends_on :macos
  depends_on "whisper.cpp"

  def install
    # `hark setup` runs this install.sh, which takes its files from next to itself.
    libexec.install "install.sh", "hark.lua", "bin", "recorder", "sounds", "karabiner"
    bin.write_exec_script libexec/"bin/hark"
  end

  def caveats
    <<~EOS
      Homebrew cannot write to your home folder. To install Hark for your user,
      or to apply an upgrade, run:
        hark setup
      Add --no-karabiner to dictate with ⌥Space only. Then check with `hark doctor`.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/hark version").strip
  end
end
