cask "keg" do
  version "0.13.0"
  sha256 "cc84541b4047e192b5613c395225fb7be584354ca133f6f59557237f7484fa40"

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
