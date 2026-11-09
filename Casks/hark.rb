# A copy of the cask in bath/homebrew-tap (Casks/hark.rb). The tap has the
# live one. app/scripts/release.sh prints the sha256 for each release.
cask "hark" do
  version "2.0.3"
  sha256 "3b63f89b3ec995e29657772fb0526d747c538d8641ad424e8ca554db955f44ea"

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
