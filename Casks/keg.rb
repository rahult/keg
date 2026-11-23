cask "keg" do
  version "0.11.0"
  sha256 "eb735eeeb0208c57c0b2dd946a6bc28e69e1eb578c66339794a635c405c8ca0f"

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
