# A copy of the cask in bath/homebrew-tap (Casks/hark.rb). The tap has the
# live one. app/scripts/release.sh prints the sha256 for each release.
cask "hark" do
  version "2.0.0"
  sha256 "aa9d6cb26f8507959dd4926df807bb1a42478f6428c87bc9a552ec2319b1bba9"

  url "https://github.com/bath/hark-stt/releases/download/v#{version}/Hark-#{version}.dmg"
  name "Hark"
  desc "Better, private, on-device dictation"
  homepage "https://hark.works/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Hark.app"

  uninstall quit: "works.hark.Hark"

  zap trash: [
    "~/Library/Application Support/Hark",
    "~/Library/Preferences/works.hark.Hark.plist",
  ]
end
