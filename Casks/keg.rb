cask "keg" do
  version "0.14.0"
  sha256 "a92b67e53d0a98cbe2b54252390ef7a863cf5453980cad353ce88e4129d502b6"

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
