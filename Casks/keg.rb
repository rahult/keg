cask "keg" do
  version "0.8.2"
  sha256 :no_check # DMG is notarized and stapled; Sparkle verifies EdDSA on updates

  url "https://github.com/rahult/keg/releases/download/v#{version}/Keg-#{version}.dmg",
      verified: "github.com/rahult/keg/"
  name "Keg"
  desc "Native Docker Desktop-class experience for Apple's container runtime"
  homepage "https://keg.rahultrikha.com/"

  livecheck do
    url "https://keg.rahultrikha.com/appcast.xml"
    strategy :sparkle
  end

  depends_on macos: ">= :26"
  depends_on arch: :arm64

  app "Keg.app"
  binary "#{appdir}/Keg.app/Contents/SharedSupport/bin/keg"

  zap trash: [
    "~/.keg",
    "~/Library/Application Support/com.apple.container",
    "~/Library/Preferences/dev.rahult.keg.plist",
  ]
end
