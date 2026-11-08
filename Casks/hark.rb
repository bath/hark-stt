# A copy of the cask in bath/homebrew-tap (Casks/hark.rb). The tap has the
# live one. app/scripts/release.sh prints the sha256 for each release.
cask "hark" do
  version "2.0.2"
  sha256 "5ee66ffb34b1468f5ce5ab6038447ffb8ecc6aa370a44507a62609ce9a57379d"

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
