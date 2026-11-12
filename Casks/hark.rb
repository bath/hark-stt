# A copy of the cask in bath/homebrew-tap (Casks/hark.rb). The tap has the
# live one. app/scripts/release.sh prints the sha256 for each release.
cask "hark" do
  version "2.1.0"
  sha256 "d490756a5a609647ea98e4216684c4046a7a6a4a0b98830256f921700dc63562"

  url "https://github.com/bath/hark-stt/releases/download/v#{version}/Hark-#{version}.dmg"
  name "Hark"
  desc "Better, private, on-device dictation"
  homepage "https://hark.works/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Hark.app updates itself with Sparkle.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Hark.app"

  uninstall quit: "works.hark.Hark"

  zap trash: [
    "~/Library/Application Support/Hark",
    "~/Library/Preferences/works.hark.Hark.plist",
  ]
end
