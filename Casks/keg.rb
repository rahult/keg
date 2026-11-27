cask "keg" do
  version "0.15.0"
  sha256 "9bf442435c6c5a7b080bf4a591b4b196c13ba8e1cbfe6bebe99c0fcd4192d4bd"

  url "https://github.com/rahult/keg/releases/download/v#{version}/Keg-#{version}.dmg",
      verified: "github.com/rahult/keg/"
  name "Keg"
  desc "Containers, Compose and Docker's API on a Mac, and deploys to your own servers"
  homepage "https://keg.rahultrikha.com/"

  livecheck do
    url "https://keg.rahultrikha.com/appcast.xml"
    strategy :sparkle
  end

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Keg.app"
  binary "#{appdir}/Keg.app/Contents/SharedSupport/bin/keg"

  zap trash: [
    "~/.keg",
    "~/Library/Preferences/dev.rahult.keg.plist",
  ]
end
